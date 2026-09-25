// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Plain mintable ERC-20 standing in for a tokenized stock on Base
/// Sepolia. Deliberately featureless so the vault and strategy
/// code is exercised against a boring token.
contract MockB20 is ERC20 {
    address public keeper;

    error NotKeeper();

    constructor(string memory name_, string memory symbol_, address keeper_) ERC20(name_, symbol_) {
        if (keeper_ == address(0)) revert Errors.ZeroAddress();
        keeper = keeper_;
        _mint(keeper_, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != keeper) revert NotKeeper();
        _mint(to, amount);
    }
}
