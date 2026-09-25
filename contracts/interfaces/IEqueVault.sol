// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Vault surface beyond stock ERC-4626: the free/locked split, the
/// two-step withdrawal queue, per-vault caps, and the router allocation hook.
/// The vault is the sole custodian; only the router can pull funds, and only
/// through allocate.
interface IEqueVault is IERC4626 {
    event RedeemRequested(address indexed owner, uint256 shares, uint256 assets, uint256 readyAt);
    event RedeemClaimed(address indexed owner, uint256 assets);
    event Allocating(uint256 assets);
    event CapSet(uint256 cap);
    event EpochBoundary();

    error RedeemNotReady(uint256 readyAt);
    error NoRedeemRequest();
    error CapExceeded(uint256 cap, uint256 requested);

    /// Assets sitting in pendingBuffer plus what can be pulled back from the
    /// lending leg without touching locked epoch collateral.
    function freeAssets() external view returns (uint256);

    /// Collateral locked in the epoch strategy plus accrued premium.
    function lockedAssets() external view returns (uint256);

    /// Timestamp at which a pending redeem request becomes claimable.
    function redeemReadyAt(address owner) external view returns (uint256);

    /// Shares currently escrowed for a pending redeem request.
    function redeemPending(address owner) external view returns (uint256);

    function requestRedeem(uint256 shares) external;

    function claim() external returns (uint256 assets);

    function allocate() external;

    function setCap(uint256 cap) external;

    function cap() external view returns (uint256);

    function router() external view returns (address);
}
