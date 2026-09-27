// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Router-facing strategy surface. The router never talks to a concrete
/// strategy; every allocation flows through these four calls. totalAssets is
/// what the strategy reports as working capital, which for the epoch strategy
/// means locked collateral plus accrued premium.
interface IStrategy {
    function totalAssets() external view returns (uint256);

    function allocate(uint256 assets) external;

    /// Returns the amount actually withdrawn, which may be less than requested.
    function withdraw(uint256 assets) external returns (uint256);

    function harvest() external;
}
