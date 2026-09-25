// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Guarded price reads for epoch starts and settlements. A feed is
/// described once at deployment and every read re-checks freshness, deviation,
/// zero answers, decimals, sequencer uptime, and market hours. Returns WAD
/// (18 decimals) so settlement math never depends on the feed's native scale.
library OracleGuard {
    struct Feed {
        AggregatorV3Interface aggregator;
        // Sequencer-uptime feed lives at its own address on L2s; zero disables
        // the check (L1 deployments).
        AggregatorV3Interface sequencerFeed;
        uint32 heartbeat;
        uint32 stalenessBuffer;
        uint32 deviationBps;
        bool checkMarketHours;
        bool checkPaused;
        bool checkSequencer;
    }

    // L2 sequencer feeds report uptime with a positive answer; a zero answer
    // means the sequencer was down at that round. New feeds need a grace
    // period before prices are trusted.
    uint256 internal constant SEQ_GRACE_PERIOD = 1 hours;

    // Traditional equities trade weekdays 13:30-20:00 UTC. Tokenized stocks
    // trade 24/7 but the strike is set against the equity market, so epochs
    // are only opened inside this window. DST is not modelled: outside the
    // window the epoch is refused, which is the safe direction.
    uint256 internal constant MARKET_OPEN = 13 hours + 30 minutes;
    uint256 internal constant MARKET_CLOSE = 20 hours;

    struct Read {
        uint256 price;
        uint256 updatedAt;
        uint80 roundId;
    }

    function read(Feed memory feed, uint256 prevPrice) internal view returns (Read memory out) {
        if (address(feed.aggregator) == address(0)) revert Errors.ZeroAddress();

        if (feed.checkSequencer) _checkSequencer(feed.sequencerFeed);
        if (feed.checkPaused) {
            // oraclePaused is not part of AggregatorV3Interface; probe it by
            // selector and treat absence as not paused so v2-style feeds and
            // mocks without the function still work.
            (bool ok, bytes memory ret) = address(feed.aggregator).staticcall(
                abi.encodeWithSelector(0x5c975abb) // paused()
            );
            if (ok && ret.length >= 32 && abi.decode(ret, (bool))) revert Errors.OraclePaused();
        }

        (, int256 answer, , uint256 updatedAt, ) = feed.aggregator.latestRoundData();
        if (answer <= 0) revert Errors.OracleUnavailable();
        out.price = uint256(answer);
        out.updatedAt = updatedAt;
        out.roundId = 0;

        uint8 decimals = feed.aggregator.decimals();
        if (decimals == 0 || decimals > 18) revert Errors.InvalidDecimals(decimals);
        if (out.price > type(uint256).max / (10 ** (18 - decimals))) revert Errors.OracleUnavailable();
        out.price = out.price * (10 ** (18 - decimals));

        if (updatedAt == 0 || block.timestamp < updatedAt) revert Errors.OracleUnavailable();
        uint256 deadline = updatedAt + feed.heartbeat + feed.stalenessBuffer;
        if (block.timestamp > deadline) revert Errors.OracleStale(updatedAt, deadline);

        if (feed.deviationBps > 0 && prevPrice > 0) {
            uint256 high = prevPrice + Math.mulDiv(prevPrice, feed.deviationBps, 10_000);
            uint256 low = prevPrice - Math.mulDiv(prevPrice, feed.deviationBps, 10_000);
            if (out.price > high || out.price < low) revert Errors.OracleDeviated(out.price, prevPrice);
        }

        if (feed.checkMarketHours) _checkMarketHours();
    }

    function _checkSequencer(AggregatorV3Interface sequencerFeed) private view {
        if (address(sequencerFeed) == address(0)) revert Errors.OracleUnavailable();
        // The sequencer-uptime feed answers 1 while up and 0 while down; a
        // fresh positive answer plus the grace period is the accepted state.
        (, int256 answer, , uint256 updatedAt, ) = sequencerFeed.latestRoundData();
        if (answer <= 0) revert Errors.SequencerDown();
        if (block.timestamp - updatedAt < SEQ_GRACE_PERIOD) revert Errors.SequencerDown();
    }

    function _checkMarketHours() private view {
        uint256 day = (block.timestamp / 1 days + 4) % 7; // 0 = Thursday epoch time
        if (day == 0 || day == 6) revert Errors.MarketClosed(day, (block.timestamp % 1 days));
        uint256 timeOfDay = block.timestamp % 1 days;
        if (timeOfDay < MARKET_OPEN || timeOfDay >= MARKET_CLOSE) {
            revert Errors.MarketClosed(day, timeOfDay);
        }
    }
}
