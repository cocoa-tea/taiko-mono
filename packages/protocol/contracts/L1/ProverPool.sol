// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.20;

import { AddressResolver } from "../common/AddressResolver.sol";
import { EssentialContract } from "../common/EssentialContract.sol";
import { IProverPool } from "./IProverPool.sol";
import { LibMath } from "../libs/LibMath.sol";
import { TaikoToken } from "./TaikoToken.sol";
import { Proxied } from "../common/Proxied.sol";

/// @title ProverPool
/// @notice See the documentation in {IProverPool}.
contract ProverPool is EssentialContract, IProverPool {
    using LibMath for uint256;

    /// @dev These values are used to compute the prover's rank (along with the
    /// protocol feePerGas).
    struct Prover {
        uint64 stakedAmount;
        uint32 rewardPerGas;
        uint32 currentCapacity;
    }

    /// @dev Make sure we only use one slot.
    struct Staker {
        uint64 exitRequestedAt;
        uint64 exitAmount;
        uint32 maxCapacity;
        uint32 proverId; // 0 to indicate the staker is not a top prover
    }

    // Given that we only have 32 slots for the top provers, if the protocol
    // can support 1 block per second with an average proof time of 1 hour,
    // then we need a min capacity of 3600, which means each prover shall
    // provide a capacity of at least 3600/32=112.
    uint32 public constant MIN_CAPACITY = 32;
    uint64 public constant EXIT_PERIOD = 1 weeks;
    uint64 public constant SLASH_POINTS = 25; // basis points or 0.25%
    uint64 public constant SLASH_MULTIPLIER = 4;
    uint64 public constant MIN_STAKE_PER_CAPACITY = 10_000;
    uint256 public constant MAX_NUM_PROVERS = 32;
    uint256 public constant MIN_CHANGE_DELAY = 1 hours;

    // Reserve more slots than necessary
    Prover[1024] public provers; // provers[0] is never used
    mapping(uint256 id => address prover) public proverIdToAddress;
    // Save the weights only when: stake / unstaked / slashed
    mapping(address staker => Staker) public stakers;

    uint256[47] private __gap;

    event Withdrawn(address indexed addr, uint64 amount);
    event Exited(address indexed addr, uint64 amount);
    event Slashed(uint64 indexed blockId, address indexed addr, uint64 amount);
    event Staked(
        address indexed addr,
        uint64 amount,
        uint32 rewardPerGas,
        uint32 currentCapacity
    );

    error CHANGE_TOO_FREQUENT();
    error INVALID_PARAMS();
    error NO_MATURE_EXIT();
    error PROVER_NOT_GOOD_ENOUGH();
    error UNAUTHORIZED();

    modifier onlyFromProtocol() {
        if (resolve("taiko", false) != msg.sender) {
            revert UNAUTHORIZED();
        }
        _;
    }

    /// @notice Initializes the ProverPool contract.
    /// @param _addressManager Address of the contract that manages proxy.
    function init(address _addressManager) external initializer {
        EssentialContract._init(_addressManager);
    }

    /// @notice Protocol specifies the current feePerGas and assigns a prover to
    /// a block.
    /// @param blockId The block id.
    /// @param feePerGas The current fee per gas.
    /// @return prover The address of the assigned prover.
    /// @return rewardPerGas The reward per gas for the assigned prover.
    function assignProver(
        uint64 blockId,
        uint32 feePerGas
    )
        external
        onlyFromProtocol
        returns (address prover, uint32 rewardPerGas)
    {
        unchecked {
            (
                uint256[MAX_NUM_PROVERS] memory weights,
                uint32[MAX_NUM_PROVERS] memory erpg
            ) = getProverWeights(feePerGas);

            bytes32 rand =
                keccak256(abi.encode(blockhash(block.number - 1), blockId));
            uint256 proverId = _selectProver(rand, weights);

            if (proverId == 0) {
                return (address(0), 0);
            } else {
                provers[proverId].currentCapacity -= 1;
                return (proverIdToAddress[proverId], erpg[proverId - 1]);
            }
        }
    }

    /// @notice Increases the capacity of the prover by releasing a prover.
    /// @param addr The address of the prover to release.
    function releaseProver(address addr) external onlyFromProtocol {
        (Staker memory staker, Prover memory prover) = getStaker(addr);

        if (staker.proverId != 0 && prover.currentCapacity < staker.maxCapacity)
        {
            unchecked {
                provers[staker.proverId].currentCapacity += 1;
            }
        }
    }

    /// @notice Slashes a prover.
    /// @param addr The address of the prover to slash.
    /// @param blockId The block id of the block which was not proved in time.
    /// @param proofReward The reward that was set for the block's proof.
    function slashProver(
        uint64 blockId,
        address addr,
        uint64 proofReward
    )
        external
        onlyFromProtocol
    {
        (Staker memory staker, Prover memory prover) = getStaker(addr);
        unchecked {
            // if the exit is mature, we do not count it in the total slash-able
            // amount
            uint256 slashableAmount = staker.exitRequestedAt > 0
                && block.timestamp <= staker.exitRequestedAt + EXIT_PERIOD
                ? prover.stakedAmount + staker.exitAmount
                : prover.stakedAmount;

            if (slashableAmount == 0) return;

            uint64 amountToSlash = uint64(
                (slashableAmount * SLASH_POINTS / 10_000 / staker.maxCapacity)
                    .max(SLASH_MULTIPLIER * proofReward).min(slashableAmount)
            );

            if (amountToSlash <= staker.exitAmount) {
                stakers[addr].exitAmount -= amountToSlash;
            } else {
                stakers[addr].exitAmount = 0;

                uint64 _additional = amountToSlash - staker.exitAmount;

                if (prover.stakedAmount > _additional) {
                    provers[staker.proverId].stakedAmount -= _additional;
                } else {
                    provers[staker.proverId].stakedAmount = 0;
                }
            }
            emit Slashed(blockId, addr, amountToSlash);
        }
    }

    /// @notice Stakes tokens for a prover in the pool.
    /// @param amount The amount of Taiko tokens to stake.
    /// @param rewardPerGas The expected reward per gas for the prover.
    /// @param maxCapacity The maximum number of blocks that a prover can
    /// handle.
    function stake(
        uint64 amount,
        uint32 rewardPerGas,
        uint32 maxCapacity
    )
        external
        nonReentrant
    {
        // Withdraw first
        _withdraw(msg.sender);
        // Force this prover to fully exit
        _exit(msg.sender, true);
        // Then stake again
        if (amount != 0) {
            _stake(msg.sender, amount, rewardPerGas, maxCapacity);
        } else if (rewardPerGas != 0 || maxCapacity != 0) {
            revert INVALID_PARAMS();
        }
    }

    /// @notice Requests an exit for the staker. This will withdraw the staked
    /// tokens and exit the prover from the pool.
    function exit() external nonReentrant {
        _withdraw(msg.sender);
        _exit(msg.sender, true);
    }

    /// @notice Withdraws staked tokens back from a matured exit.
    function withdraw() external nonReentrant {
        if (!_withdraw(msg.sender)) revert NO_MATURE_EXIT();
    }

    /// @notice Retrieves the information of a staker and their corresponding
    /// prover using their address.
    /// @param addr The address of the staker.
    /// @return staker The staker's information.
    /// @return prover The prover's information.
    function getStaker(address addr)
        public
        view
        returns (Staker memory staker, Prover memory prover)
    {
        staker = stakers[addr];
        if (staker.proverId != 0) {
            unchecked {
                prover = provers[staker.proverId];
            }
        }
    }

    /// @notice Calculates and returns the current total capacity of the pool.
    /// @return capacity The total capacity of the pool.
    function getCapacity() public view returns (uint256 capacity) {
        unchecked {
            for (uint256 i = 1; i <= MAX_NUM_PROVERS; ++i) {
                capacity += provers[i].currentCapacity;
            }
        }
    }

    /// @notice Retrieves the current active provers and their corresponding
    /// stakers.
    /// @return _provers The active provers.
    /// @return _stakers The stakers of the active provers.
    function getProvers()
        public
        view
        returns (Prover[] memory _provers, address[] memory _stakers)
    {
        _provers = new Prover[](MAX_NUM_PROVERS);
        _stakers = new address[](MAX_NUM_PROVERS);
        for (uint256 i; i < MAX_NUM_PROVERS; ++i) {
            _provers[i] = provers[i + 1];
            _stakers[i] = proverIdToAddress[i + 1];
        }
    }

    /// @notice Retrieves the current active provers and their weights.
    /// @param feePerGas The protocol's current fee per gas.
    /// @return weights The weights of the current provers in the pool.
    /// @return erpg The effective reward per gas of the current provers in the
    /// pool. This is smoothed out to be in range of the current fee per gas.
    function getProverWeights(uint32 feePerGas)
        public
        view
        returns (
            uint256[MAX_NUM_PROVERS] memory weights,
            uint32[MAX_NUM_PROVERS] memory erpg
        )
    {
        Prover memory _prover;
        unchecked {
            for (uint32 i; i < MAX_NUM_PROVERS; ++i) {
                _prover = provers[i + 1];
                if (_prover.currentCapacity != 0) {
                    // Keep the effective rewardPerGas in [75-125%] of feePerGas
                    if (_prover.rewardPerGas > feePerGas * 125 / 100) {
                        erpg[i] = feePerGas * 125 / 100;
                    } else if (_prover.rewardPerGas < feePerGas * 75 / 100) {
                        erpg[i] = feePerGas * 75 / 100;
                    } else {
                        erpg[i] = _prover.rewardPerGas;
                    }
                    // Calculates the prover's weight based on the staked amount
                    // and effective rewardPerGas
                    weights[i] = _calcWeight(_prover.stakedAmount, erpg[i]);
                }
            }
        }
    }

    /// @dev See the documentation for the callers of this internal function.
    function _stake(
        address addr,
        uint64 amount,
        uint32 rewardPerGas,
        uint32 maxCapacity
    )
        private
    {
        // Check parameters
        if (
            maxCapacity < MIN_CAPACITY
                || amount / maxCapacity < MIN_STAKE_PER_CAPACITY
                || rewardPerGas == 0
        ) revert INVALID_PARAMS();

        // Reuse tokens that are exiting
        Staker storage staker = stakers[addr];

        unchecked {
            if (staker.exitAmount >= amount) {
                staker.exitAmount -= amount;
            } else {
                uint64 burnAmount = (amount - staker.exitAmount);
                TaikoToken(resolve("taiko_token", false)).burn(addr, burnAmount);
                staker.exitAmount = 0;
            }
        }

        staker.exitRequestedAt =
            staker.exitAmount == 0 ? 0 : uint64(block.timestamp);

        staker.maxCapacity = maxCapacity;

        // Find the prover id
        uint32 proverId = 1;
        for (uint32 i = 2; i <= MAX_NUM_PROVERS;) {
            if (provers[proverId].stakedAmount > provers[i].stakedAmount) {
                proverId = i;
            }
            unchecked {
                ++i;
            }
        }

        if (provers[proverId].stakedAmount >= amount) {
            revert PROVER_NOT_GOOD_ENOUGH();
        }

        // Force the replaced prover to exit
        address replaced = proverIdToAddress[proverId];
        if (replaced != address(0)) {
            _withdraw(replaced);
            _exit(replaced, false);
        }
        proverIdToAddress[proverId] = addr;
        staker.proverId = proverId;

        // Insert the prover in the top prover list
        provers[proverId] = Prover({
            stakedAmount: amount,
            rewardPerGas: rewardPerGas,
            currentCapacity: maxCapacity
        });

        emit Staked(addr, amount, rewardPerGas, maxCapacity);
    }

    /// @dev See the documentation for the callers of this internal function.
    function _exit(address addr, bool checkExitTimestamp) private {
        Staker storage staker = stakers[addr];
        if (staker.proverId == 0) return;

        Prover memory prover = provers[staker.proverId];

        delete proverIdToAddress[staker.proverId];

        // Delete the prover but make it non-zero for cheaper rewrites
        // by keeping rewardPerGas = 1
        provers[staker.proverId] = Prover(0, 1, 0);

        // Clear data if there is an 'exit' anyway, regardless of
        // staked amount.
        if (
            checkExitTimestamp
                && block.timestamp <= staker.exitRequestedAt + MIN_CHANGE_DELAY
        ) {
            revert CHANGE_TOO_FREQUENT();
        }

        staker.exitAmount += prover.stakedAmount;
        staker.exitRequestedAt = uint64(block.timestamp);
        staker.proverId = 0;

        emit Exited(addr, staker.exitAmount);
    }

    /// @dev See the documentation for the callers of this internal function.
    /// @param addr The address of the staker to withdraw. This is where the
    /// staked tokens are sent.
    /// @return success Whether the withdrawal is successful.
    function _withdraw(address addr) private returns (bool success) {
        Staker storage staker = stakers[addr];
        if (
            staker.exitAmount == 0 || staker.exitRequestedAt == 0
                || block.timestamp <= staker.exitRequestedAt + EXIT_PERIOD
        ) {
            return false;
        }

        TaikoToken(AddressResolver(this).resolve("taiko_token", false)).mint(
            addr, staker.exitAmount
        );

        emit Withdrawn(addr, staker.exitAmount);
        staker.exitRequestedAt = 0;
        staker.exitAmount = 0;
        return true;
    }

    /// @dev See the documentation for the callers of this internal function.
    /// @param stakedAmount The staked amount of the prover.
    /// @param rewardPerGas The reward per gas of the prover.
    /// @return weight The weight of the prover (essentially a "score").
    function _calcWeight(
        uint64 stakedAmount,
        uint32 rewardPerGas
    )
        private
        pure
        returns (uint64 weight)
    {
        if (rewardPerGas == 0) {
            return 0;
        }
        // The weight has a direct linear relationship to the staked amount and
        // an inverse square relationship to the rewardPerGas.
        weight = stakedAmount / rewardPerGas / rewardPerGas;
        if (weight == 0) {
            weight = 1;
        }
    }

    /// @dev See the documentation for the callers of this internal function.
    /// This function will select a prover and those that have a higher weight
    /// are more likely to be selected.
    /// @param rand A random input used as a seed.
    /// @param weights An array of the weights of the provers.
    /// @return proverId The selected prover id.
    function _selectProver(
        bytes32 rand,
        uint256[MAX_NUM_PROVERS] memory weights
    )
        private
        pure
        returns (uint256 proverId)
    {
        unchecked {
            uint256 totalWeight;
            // Calculate the total weight
            for (uint256 i; i < MAX_NUM_PROVERS; ++i) {
                totalWeight += weights[i];
            }
            // If the weight is 0 select the first prover
            if (totalWeight == 0) return 0;
            // Select a random number in the range [0, totalWeight)
            uint256 r = uint256(rand) % totalWeight;
            uint256 accumulatedWeight;
            // Go through each prover and check if the random number is in range
            // of the accumulatedWeight. The probability of a prover being
            // selected is proportional to its weight.
            for (uint256 i; i < MAX_NUM_PROVERS; ++i) {
                accumulatedWeight += weights[i];
                if (r < accumulatedWeight) {
                    return i + 1;
                }
            }
            assert(false); // shall not reach here
        }
    }
}

/// @title ProxiedProverPool
/// @notice Proxied version of the ProverPool contract.
contract ProxiedProverPool is Proxied, ProverPool { }
