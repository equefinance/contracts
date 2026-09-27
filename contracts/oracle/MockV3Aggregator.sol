// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {EqueAccess} from "../utils/EqueAccess.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice 8-decimals price feed mock for testnets. Chainlink's own
/// MockV3Aggregator leaves updateAnswer unrestricted, here the keeper address
/// set at deployment is the only writer, matching the production shape where
/// only the price-keeper bot pushes rounds.
contract MockV3Aggregator is AggregatorV3Interface, EqueAccess {
    uint8 public decimals_;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    uint80 public latestRound;

    event AnswerUpdated(int256 indexed answer, uint80 indexed round, uint256 updatedAt);

    error AnswerTooLarge();

    constructor(address keeper, int256 initialAnswer) EqueAccess(keeper) {
        if (keeper == address(0)) revert Errors.ZeroAddress();
        decimals_ = 8;
        _grantRole(KEEPER_ROLE, keeper);
        _push(initialAnswer);
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function description() external pure returns (string memory) {
        return "eque mock equity feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 _roundId
    ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        if (_roundId == 0 || _roundId > latestRound) revert("no such round");
        return (_roundId, latestAnswer, latestTimestamp, latestTimestamp, latestRound);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (latestRound, latestAnswer, latestTimestamp, latestTimestamp, latestRound);
    }

    /// Keeper-only price push; the price-keeper bot holds KEEPER_ROLE.
    function updateAnswer(int256 answer) external onlyKeeper {
        _push(answer);
    }

    function _push(int256 answer) private {
        if (answer <= 0) revert Errors.OracleUnavailable();
        if (answer > type(int256).max / 1e10) revert AnswerTooLarge();
        latestRound++;
        latestAnswer = answer;
        latestTimestamp = block.timestamp;
        emit AnswerUpdated(answer, latestRound, block.timestamp);
    }

}
