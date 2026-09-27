// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IEpochStrategy} from "../interfaces/IEpochStrategy.sol";
import {EqueAccess} from "../utils/EqueAccess.sol";
import {IEqueRouter} from "../interfaces/IEqueRouter.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Deterministic allocation engine shared by every vault. The router
/// holds no funds: it computes allocation plans from curator weights, caps,
/// and hysteresis, and the vault executes the transfers itself. Rebalance is
/// keeper-executed but constrained on-chain — a move that does not reduce the
/// distance to target, or that would pull epoch-locked collateral, reverts.
contract EqueRouter is EqueAccess, IEqueRouter {
    using SafeERC20 for IERC20;

    struct VaultConfig {
        address[] strategies;
        mapping(address strategy => uint256 capBps) capBps;
        uint256 epochBps;
        uint256 lendingBps;
    }

    mapping(address vault => VaultConfig) internal _configs;
    uint256 public override toleranceBps;

    error OnlyVault();

    constructor(address admin, address wireAuthority) EqueAccess(admin) {
        toleranceBps = 500;
        if (wireAuthority != address(0)) _grantRole(CURATOR_ROLE, wireAuthority);
    }

    // --- Registration and curator settings ---

    function registerStrategy(address vault, address strategy, uint256 capBps) external onlyCurator {
        if (vault == address(0) || strategy == address(0)) revert Errors.ZeroAddress();
        if (capBps > 10_000) revert IEqueRouter.CapExceeded(10_000, capBps);
        VaultConfig storage config = _configs[vault];
        config.strategies.push(strategy);
        config.capBps[strategy] = capBps;
        emit StrategyRegistered(vault, strategy, capBps);
    }

    function setWeights(address vault, uint256 epochBps, uint256 lendingBps) external onlyCurator {
        if (epochBps + lendingBps != 10_000) revert IEqueRouter.WeightsInvalid(epochBps + lendingBps);
        VaultConfig storage config = _configs[vault];
        if (config.strategies.length == 0) revert IEqueRouter.UnknownStrategy();
        config.epochBps = epochBps;
        config.lendingBps = lendingBps;
        emit WeightsSet(vault, epochBps, lendingBps);
    }

    function setToleranceBps(uint256 bps) external onlyCurator {
        if (bps > 10_000) revert Errors.InvalidConfig();
        toleranceBps = bps;
    }

    function weights(address vault) external view returns (uint256 epochBps, uint256 lendingBps) {
        VaultConfig storage config = _configs[vault];
        return (config.epochBps, config.lendingBps);
    }

    function strategyAssets(address vault, address strategy) external view returns (uint256) {
        if (_isRegistered(vault, strategy)) return IStrategy(strategy).totalAssets();
        return 0;
    }

    function strategyHoldings(address vault) external view returns (address[] memory, uint256[] memory) {
        address[] memory strategies = _configs[vault].strategies;
        uint256[] memory holdings = new uint256[](strategies.length);
        for (uint256 i; i < strategies.length; i++) {
            holdings[i] = IStrategy(strategies[i]).totalAssets();
        }
        return (strategies, holdings);
    }

    /// Registry position 0 is the epoch strategy by wiring order. Its whole
    /// balance counts as locked from the moment an epoch opens: the notional
    /// backs the option being auctioned and the escrowed premium backs
    /// settlement, so neither may be paid out before the epoch settles.
    function strategyLocked(address vault) external view returns (uint256) {
        address[] memory strategies = _configs[vault].strategies;
        if (strategies.length == 0) return 0;
        IEpochStrategy.State s = IEpochStrategy(strategies[0]).state();
        if (s == IEpochStrategy.State.Auction || s == IEpochStrategy.State.Locked) {
            return IStrategy(strategies[0]).totalAssets();
        }
        return 0;
    }

    function nextEpochBoundary(address vault) external view returns (uint256) {
        address[] memory strategies = _configs[vault].strategies;
        if (strategies.length == 0) return 0;
        IEpochStrategy epoch = IEpochStrategy(strategies[0]);
        IEpochStrategy.State s = epoch.state();
        if (s == IEpochStrategy.State.Auction) {
            return epoch.currentEpoch().auctionEnd;
        }
        if (s == IEpochStrategy.State.Locked) {
            return epoch.currentEpoch().expiry;
        }
        return 0;
    }

    // --- Deterministic planning ---

    /// Split of the vault's free assets across registered strategies. Order
    /// follows the registry: the epoch strategy is filled first (up to its
    /// cap), the remainder goes to the lending strategy (up to its cap).
    /// Hysteresis: allocations only change when the current split sits outside
    /// tolerance of the target, which keeps small deposits from churning the
    /// book.
    function planAllocation(address vault) external view returns (address[] memory strategies, uint256[] memory amounts) {
        VaultConfig storage config = _configs[vault];
        strategies = config.strategies;
        amounts = new uint256[](strategies.length);
        if (strategies.length < 2) revert IEqueRouter.UnknownStrategy();

        address epochStrategy = strategies[0];
        address lendingStrategy = strategies[1];
        uint256 epochHeld = IStrategy(epochStrategy).totalAssets();
        uint256 lendingHeld = IStrategy(lendingStrategy).totalAssets();
        uint256 buffer = _bufferOf(vault);

        uint256 total = buffer + epochHeld + lendingHeld;
        if (total == 0) return (strategies, amounts);

        uint256 targetEpoch = Math.mulDiv(total, config.epochBps, 10_000);
        uint256 targetLending = total - targetEpoch;

        // Current shares in bps for the hysteresis check.
        uint256 currentEpochBps = Math.mulDiv(epochHeld, 10_000, total);
        uint256 currentLendingBps = 10_000 - currentEpochBps;
        uint256 tol = toleranceBps;
        bool epochOff = _distance(currentEpochBps, config.epochBps) > tol;
        bool lendingOff = _distance(currentLendingBps, config.lendingBps) > tol;

        if (!epochOff && !lendingOff) return (strategies, amounts);

        uint256 epochWant = targetEpoch > epochHeld ? targetEpoch - epochHeld : 0;
        uint256 lendingWant = targetLending > lendingHeld ? targetLending - lendingHeld : 0;

        // Caps are enforced on the post-allocation holding, so the request is
        // clamped to what each strategy may still receive.
        // Caps are upper bounds on new allocation, not forced moves: if a
        // curator lowers one below current holdings, planning stops adding to
        // that leg instead of underflowing.
        uint256 epochCap = Math.mulDiv(total, config.capBps[epochStrategy], 10_000);
        if (epochHeld + epochWant > epochCap) {
            epochWant = epochCap > epochHeld ? epochCap - epochHeld : 0;
        }
        uint256 lendingCap = Math.mulDiv(total, config.capBps[lendingStrategy], 10_000);
        if (lendingHeld + lendingWant > lendingCap) {
            lendingWant = lendingCap > lendingHeld ? lendingCap - lendingHeld : 0;
        }

        uint256 budget = buffer;
        amounts[0] = epochWant > budget ? budget : epochWant;
        budget -= amounts[0];
        amounts[1] = lendingWant > budget ? budget : lendingWant;
    }

    /// Rebalance pulls excess from an over-allocated strategy and pushes to
    /// the under-allocated one. Constrained: the move must strictly reduce
    /// the distance to target, and nothing may be pulled while its epoch is
    /// locked (the vault refuses anyway at allocation time).
    function rebalance(address vault) external onlyKeeper {
        VaultConfig storage config = _configs[vault];
        address[] memory strategies = config.strategies;
        if (strategies.length < 2) revert IEqueRouter.UnknownStrategy();

        address epochStrategy = strategies[0];
        address lendingStrategy = strategies[1];
        uint256 epochHeld = IStrategy(epochStrategy).totalAssets();
        uint256 lendingHeld = IStrategy(lendingStrategy).totalAssets();
        uint256 buffer = _bufferOf(vault);
        uint256 total = buffer + epochHeld + lendingHeld;
        if (total == 0) revert IEqueRouter.NothingToRebalance();

        uint256 targetEpoch = Math.mulDiv(total, config.epochBps, 10_000);
        uint256 currentEpochBps = Math.mulDiv(epochHeld, 10_000, total);
        if (_distance(currentEpochBps, config.epochBps) <= toleranceBps) revert IEqueRouter.NothingToRebalance();

        if (IEpochStrategy(epochStrategy).state() == IEpochStrategy.State.Locked) revert IEqueRouter.StrategyLocked();

        if (epochHeld < targetEpoch) {
            // Lending has excess; pull from it and push to the epoch strategy.
            uint256 want = targetEpoch - epochHeld;
            uint256 excess = lendingHeld + buffer - Math.mulDiv(total - want, config.lendingBps, 10_000);
            if (excess == 0) revert IEqueRouter.NothingToRebalance();
            uint256 take = excess < want ? excess : want;
            uint256 pulled = IStrategy(lendingStrategy).withdraw(take);
            IStrategy(epochStrategy).allocate(pulled);
            emit Rebalanced(vault, epochHeld + pulled, lendingHeld - pulled);
        } else {
            // Epoch has excess; pull from it (only safe when not locked) and
            // push to lending.
            uint256 want = epochHeld - targetEpoch;
            uint256 pulled = IStrategy(epochStrategy).withdraw(want);
            if (pulled == 0) revert IEqueRouter.NothingToRebalance();
            IStrategy(lendingStrategy).allocate(pulled);
            emit Rebalanced(vault, epochHeld - pulled, lendingHeld + pulled);
        }
    }

    function _isRegistered(address vault, address strategy) internal view returns (bool) {
        address[] memory strategies = _configs[vault].strategies;
        for (uint256 i; i < strategies.length; i++) {
            if (strategies[i] == strategy) return true;
        }
        return false;
    }

    /// Buffer the vault holds directly: the vault is the custodian, so its
    /// balance of its own asset is authoritative.
    function _bufferOf(address vault) internal view returns (uint256) {
        return IERC20(IERC4626(vault).asset()).balanceOf(vault);
    }

    function _distance(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
