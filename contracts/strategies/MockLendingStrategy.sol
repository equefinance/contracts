// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EqueAccess} from "../utils/EqueAccess.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Fixed-yield stand-in for the lending leg wherever Morpho Blue has
/// no usable market, and for router tests without a fork. Accrues 2% per year
/// linearly on the principal, exactly like the stub the unit tests use.
contract MockLendingStrategy is EqueAccess, IStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    address public vault;

    uint256 public principal;
    uint256 public depositedAt;

    error AlreadySet();

    constructor(address asset_, address admin) EqueAccess(admin) {
        if (asset_ == address(0)) revert Errors.ZeroAddress();
        assetToken = IERC20(asset_);
    }

    /// One-time vault wiring, called by the factory after the vault exists.
    function setVault(address vault_) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert Errors.Unauthorized();
        if (vault != address(0) || vault_ == address(0)) revert AlreadySet();
        vault = vault_;
    }

    function totalAssets() external view returns (uint256) {
        if (principal == 0) return 0;
        return principal + (principal * 2 * (block.timestamp - depositedAt)) / 100 / 365 days;
    }

    function allocate(uint256 assets) external {
        if (msg.sender != vault && !hasRole(KEEPER_ROLE, msg.sender)) revert Errors.NotVault();
        if (principal == 0) depositedAt = block.timestamp;
        principal += assets;
    }

    function withdraw(uint256 assets) external returns (uint256) {
        if (msg.sender != vault && !hasRole(KEEPER_ROLE, msg.sender)) revert Errors.NotVault();
        uint256 available = this.totalAssets();
        uint256 take = assets > available ? available : assets;
        if (take > principal) take = principal;
        principal -= take;
        assetToken.safeTransfer(msg.sender, take);
        return take;
    }

    function harvest() external {}
}
