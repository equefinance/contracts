// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Stock-like mock token for the Robinhood testnet vaults.
/// Minting is keeper-gated, the faucet holds the keeper role on testnet.
contract MockStocks is ERC20 {
    address public keeper;
    string public issuer;
    string public underlyingTicker;

    error NotKeeper();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory issuer_,
        address keeper_
    ) ERC20(name_, symbol_) {
        if (keeper_ == address(0)) revert Errors.ZeroAddress();
        keeper = keeper_;
        issuer = issuer_;
        underlyingTicker = symbol_;
        _mint(keeper_, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != keeper) revert NotKeeper();
        _mint(to, amount);
    }
}
