// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Arbitrum-style sequencer-uptime mock. A positive answer with an
/// updated timestamp means the sequencer was up, zero means it was down. The
/// startedAt=0 convention marks rounds before the feed started, which the
/// guard treats as unavailable.
contract MockSequencerFeed is AggregatorV3Interface {
    int256 private _answer;
    uint256 private _updatedAt;

    error NotKeeper();

    address public keeper;

    constructor(address keeper_) {
        if (keeper_ == address(0)) revert Errors.ZeroAddress();
        keeper = keeper_;
        _answer = 1;
        _updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function description() external pure returns (string memory) {
        return "mock sequencer uptime";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 _roundId
    ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        if (_roundId == 0) revert("no such round");
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }

    function setUp(bool up) external {
        if (msg.sender != keeper) revert NotKeeper();
        _answer = up ? int256(1) : int256(0);
        _updatedAt = block.timestamp;
    }
}
