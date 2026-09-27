// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategy} from "./IStrategy.sol";

/// @notice Deterministic allocation engine. One router serves every vault;
/// each vault registers its strategies and curator-set target weights. The
/// keeper executes rebalance, but on-chain constraints decide what it may do:
/// moves must reduce distance to target, respect caps and hysteresis, and
/// never pull epoch-locked collateral mid-epoch.
interface IEqueRouter {
    event StrategyRegistered(address indexed vault, address indexed strategy, uint256 capBps);
    event WeightsSet(address indexed vault, uint256 epochBps, uint256 lendingBps);
    event Rebalanced(address indexed vault, uint256 epochAssets, uint256 lendingAssets);

    error UnknownVault();
    error UnknownStrategy();
    error StrategyLocked();
    error CapExceeded(uint256 capBps, uint256 requestedBps);
    error RebalanceRejected(uint256 currentBps, uint256 targetBps);
    error WeightsInvalid(uint256 totalBps);
    error NothingToRebalance();

    function registerStrategy(address vault, address strategy, uint256 capBps) external;

    function setWeights(address vault, uint256 epochBps, uint256 lendingBps) external;

    function weights(address vault) external view returns (uint256 epochBps, uint256 lendingBps);

    function strategyAssets(address vault, address strategy) external view returns (uint256);

    /// Holdings per registered strategy, in the same order as the returned
    /// strategy list. The vault reads this for its free/locked split.
    function strategyHoldings(address vault) external view returns (address[] memory strategies, uint256[] memory holdings);

    /// Total locked collateral reported by the vault's epoch strategies.
    function strategyLocked(address vault) external view returns (uint256);

    /// Next epoch boundary timestamp for the vault, used to time redeem claims.
    function nextEpochBoundary(address vault) external view returns (uint256);

    /// Deterministic split of the vault's free assets across registered
    /// strategies, respecting caps. No state change; the vault calls this at
    /// epoch boundaries and the router returns the plan.
    function planAllocation(address vault) external view returns (address[] memory strategies, uint256[] memory amounts);

    /// Keeper-executed but constrained: rebalance(vault) must move the vault
    /// toward its target weights within tolerance or revert.
    function rebalance(address vault) external;

    function toleranceBps() external view returns (uint256);

    function setToleranceBps(uint256 bps) external;
}
