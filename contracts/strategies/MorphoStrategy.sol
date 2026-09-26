// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EqueAccess} from "../utils/EqueAccess.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Errors} from "../libraries/Errors.sol";

// ---------------------------------------------------------------------------
// TODO - DEMO SCOPE NOTE: 
// 
// MorphoStrategy is intentionally NOT deployed right now.
// The current deployment ships two strategies per vault:
//   - EpochStrategy        → the options-premium engine
//   - MockLendingStrategy  → the lending leg of the router's two-strategy model
// A mock lending leg is sufficient for the demo: what is being demonstrated
// is the epoch/auction mechanism, not the lending venue.
//
// Morpho Blue integration is a tracked post-demo milestone.
// Two known integration gaps, both with a defined fix:
//   1. allocate() is pull-style while the vault pushes funds  → make it push-style
//   2. the constructor needs the vault address before the vault clone exists
//      → one-time setVault wiring after the clone is created
// ---------------------------------------------------------------------------


interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);
    function withdraw(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);
    function market(bytes32 id)
        external
        view
        returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
    function position(bytes32 id, address user) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

/// @notice Thin lending adapter over a Morpho Blue market. Supply-only by
/// design: a supplied position carries no debt and no liquidation risk, so
/// the borrow-side health-factor machinery has nothing to monitor here. The
/// full amount sits in the market; withdrawals pull the needed slice.
contract MorphoStrategy is EqueAccess, IStrategy {
    using SafeERC20 for IERC20;

    IMorpho public immutable morpho;
    address public immutable loanToken;
    address public immutable collateralToken;
    address public immutable morphoOracle;
    address public immutable irm;
    uint256 public immutable lltv;
    bytes32 public immutable marketId;
    IERC20 public immutable assetToken;
    address public immutable vault;

    uint256 internal supplyShares;

    constructor(
        address morpho_,
        IMorpho.MarketParams memory marketParams_,
        address vault_,
        address admin
    ) EqueAccess(admin) {
        if (morpho_ == address(0) || vault_ == address(0)) revert Errors.ZeroAddress();
        if (marketParams_.loanToken == address(0)) revert Errors.ZeroAddress();
        morpho = IMorpho(morpho_);
        loanToken = marketParams_.loanToken;
        collateralToken = marketParams_.collateralToken;
        morphoOracle = marketParams_.oracle;
        irm = marketParams_.irm;
        lltv = marketParams_.lltv;
        marketId = _marketId(marketParams_);
        assetToken = IERC20(marketParams_.loanToken);
        vault = vault_;
    }

    /// Market id is the keccak256 of the packed 160-byte MarketParams, per
    /// the Morpho Blue docs; recomputed here so the adapter carries no
    /// extra dependency.
    function _params() internal view returns (IMorpho.MarketParams memory) {
        return IMorpho.MarketParams({loanToken: loanToken, collateralToken: collateralToken, oracle: morphoOracle, irm: irm, lltv: lltv});
    }

    function _marketId(IMorpho.MarketParams memory mp) internal pure returns (bytes32) {
        return keccak256(abi.encode(mp.loanToken, mp.collateralToken, mp.oracle, mp.irm, mp.lltv));
    }

    function totalAssets() external view returns (uint256) {
        return _expectedSupplyAssets();
    }

    /// Fund flows are vault-only: the keeper key must never be able to pull
    /// strategy funds to itself. (The push-style allocate rework is tracked
    /// separately.)
    function allocate(uint256 assets) external {
        if (msg.sender != vault) revert Errors.NotVault();
        if (assets == 0) revert Errors.ZeroAmount();
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        assetToken.forceApprove(address(morpho), assets);
        (, uint256 shares) = morpho.supply(_params(), assets, 0, address(this), "");
        supplyShares += shares;
    }

    function withdraw(uint256 assets) external returns (uint256) {
        if (msg.sender != vault) revert Errors.NotVault();
        if (assets == 0) return 0;
        uint256 owned = _expectedSupplyAssets();
        uint256 take = assets > owned ? owned : assets;
        // Withdraw by assets, capped at what the position holds; Morpho
        // clamps shares internally.
        (uint256 withdrawn, uint256 shares) = morpho.withdraw(_params(), take, 0, address(this), address(this));
        supplyShares -= shares;
        assetToken.safeTransfer(msg.sender, withdrawn);
        return withdrawn;
    }

    function harvest() external {}

    /// Supply assets valued at current market rates: supply shares scaled by
    /// the onchain exchange rate, with the same rounding Morpho uses.
    function _expectedSupplyAssets() internal view returns (uint256) {
        if (supplyShares == 0) return 0;
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,) = _market();
        return (supplyShares * totalSupplyAssets) / totalSupplyShares;
    }

    function _market() internal view returns (uint128, uint128, uint128, uint128, uint128) {
        (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate,) =
            morpho.market(marketId);
        return (totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate);
    }
}
