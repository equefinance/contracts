// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Testnet token dripper with two tabs: the depositor tab feeds users
/// who need vault-able stock tokens, the bidder tab feeds the market-maker bot
/// that keeps the auction live. Each tab has its own amount and per-wallet
/// cool-down so one wallet cannot drain the pool.
contract TestnetFaucet {
    using SafeERC20 for IERC20;

    struct Tab {
        IERC20 token;
        uint256 amount;
        uint32 interval;
    }

    Tab public depositorTab;
    Tab public bidderTab;
    mapping(address wallet => uint256 lastClaim) public depositorLastClaim;
    mapping(address wallet => uint256 lastClaim) public bidderLastClaim;
    address public owner;

    event Claimed(address indexed wallet, bool bidder, uint256 amount);

    error NotOwner();
    error Cooldown(uint256 readyAt);

    constructor(address depositorToken, address bidderToken) {
        if (depositorToken == address(0) || bidderToken == address(0)) revert Errors.ZeroAddress();
        owner = msg.sender;
        depositorTab = Tab({token: IERC20(depositorToken), amount: 10 ether, interval: 1 hours});
        bidderTab = Tab({token: IERC20(bidderToken), amount: 1000 ether, interval: 10 minutes});
    }

    function claimDepositor() external returns (uint256 amount) {
        amount = _claim(depositorTab.token, depositorTab.amount, depositorTab.interval, depositorLastClaim[msg.sender]);
        depositorLastClaim[msg.sender] = block.timestamp;
        emit Claimed(msg.sender, false, amount);
    }

    function claimBidder() external returns (uint256 amount) {
        amount = _claim(bidderTab.token, bidderTab.amount, bidderTab.interval, bidderLastClaim[msg.sender]);
        bidderLastClaim[msg.sender] = block.timestamp;
        emit Claimed(msg.sender, true, amount);
    }

    function nextDepositorClaim(address wallet) external view returns (uint256) {
        return depositorLastClaim[wallet] + depositorTab.interval;
    }

    function nextBidderClaim(address wallet) external view returns (uint256) {
        return bidderLastClaim[wallet] + bidderTab.interval;
    }

    function setDepositorTab(address token, uint256 amount, uint32 interval) external {
        if (msg.sender != owner) revert NotOwner();
        _setTab(depositorTab, token, amount, interval);
    }

    function setBidderTab(address token, uint256 amount, uint32 interval) external {
        if (msg.sender != owner) revert NotOwner();
        _setTab(bidderTab, token, amount, interval);
    }

    function drain(address token, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        SafeERC20.safeTransfer(IERC20(token), owner, amount);
    }

    function _claim(IERC20 token, uint256 amount, uint32 interval, uint256 lastClaim) private returns (uint256) {
        if (lastClaim != 0 && block.timestamp < lastClaim + interval) {
            revert Cooldown(lastClaim + interval);
        }
        if (amount == 0) revert Errors.ZeroAmount();
        SafeERC20.safeTransfer(token, msg.sender, amount);
        return amount;
    }

    function _setTab(Tab storage tab, address token, uint256 amount, uint32 interval) private {
        if (token == address(0) || amount == 0 || interval == 0) revert Errors.InvalidConfig();
        tab.token = IERC20(token);
        tab.amount = amount;
        tab.interval = interval;
    }
}
