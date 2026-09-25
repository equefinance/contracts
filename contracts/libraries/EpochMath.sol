// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Pure settlement math for epoch covered calls. Every function takes
/// everything it needs as arguments and reads no state, so the whole library
/// is fuzz-targetable. All prices are WAD (18 decimals) regardless of the
/// oracle's native decimals; conversion happens in OracleGuard.
library EpochMath {
    // Strike is a fixed percentage above spot at epoch start, curator-tunable
    // around the default 105% but clamped so it can never go at-the-money.
    uint256 public constant STRIKE_BPS = 10_500;
    uint256 public constant MIN_STRIKE_BPS = 10_001;
    uint256 public constant MAX_STRIKE_BPS = 12_000;

    // Bids below the reserve floor are ignored, and the winning premium may
    // never exceed this fraction of notional.
    uint256 public constant MAX_PREMIUM_BPS = 500;

    uint256 internal constant BPS = 10_000;

    /// @notice Strike for an epoch: strikeBps of spot, with 10500 meaning 105%.
    /// Rounded up so the strike is strictly above spot even for tiny prices.
    function strike(uint256 spot, uint256 strikeBps) internal pure returns (uint256) {
        if (spot == 0) return 0;
        return Math.mulDiv(spot, strikeBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice Cash-settled call payoff in underlying units, converted at the
    /// expiry spot. Only meaningful when spot is above strike; returns zero
    /// otherwise, which folds exactly-at-strike into the no-payoff case.
    function payoff(uint256 notional, uint256 spot, uint256 strikePrice) internal pure returns (uint256) {
        if (spot == 0 || spot <= strikePrice || notional == 0) return 0;
        // notional * (spot - strike) / spot; 512-bit safe via mulDiv.
        return Math.mulDiv(notional, spot - strikePrice, spot, Math.Rounding.Floor);
    }

    /// @notice Amount the vault keeps after settlement: collateral minus the
    /// exercised slice, plus the premium. For OTM settles this is notional
    /// plus the full premium.
    function settle(
        uint256 notional,
        uint256 spot,
        uint256 strikePrice,
        uint256 premium
    ) internal pure returns (uint256) {
        return notional - payoff(notional, spot, strikePrice) + premium;
    }

    /// @notice The reserve floor: floorBps of the notional, the minimum
    /// qualifying bid for the epoch's auction.
    function reserveFloor(uint256 notional, uint256 floorBps) internal pure returns (uint256) {
        return Math.mulDiv(notional, floorBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice True when a bid qualifies for the auction: at or above the
    /// reserve floor.
    function bidQualifies(uint256 bid, uint256 notional, uint256 floorBps) internal pure returns (bool) {
        if (notional == 0) return false;
        return bid >= reserveFloor(notional, floorBps);
    }

    /// @notice Minimum acceptable next bid: 1% over the current high, rounded
    /// so a tick can never be satisfied by an equal amount.
    function nextBidFloor(uint256 currentHigh) internal pure returns (uint256) {
        if (currentHigh == 0) return 0;
        return Math.mulDiv(currentHigh, 10_100, BPS, Math.Rounding.Ceil) + 1;
    }

    /// @notice Premium sanity bound: the premium must not exceed capBps of the
    /// notional. Rejects absurd auctions rather than trusting the winning bid.
    function premiumInBounds(uint256 notional, uint256 premium, uint256 capBps) internal pure returns (bool) {
        return premium <= Math.mulDiv(notional, capBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice Anti-sniping window: the extension scales with the epoch so a
    /// 5-minute demo epoch gets a 30-second extension while a 7-day epoch gets
    /// roughly two days.
    function snipeExtension(uint256 auctionWindow) internal pure returns (uint256) {
        return Math.mulDiv(auctionWindow, 1, 10);
    }

    /// @notice True when a bid landed inside the final tenth of the auction
    /// window, triggering an extension.
    function bidInSnipeZone(uint256 auctionEnd, uint256 now_, uint256 auctionWindow) internal pure returns (bool) {
        uint256 zone = snipeExtension(auctionWindow);
        return auctionEnd > now_ && auctionEnd - now_ <= zone;
    }

    function validateStrikeBps(uint256 strikeBps) internal pure returns (bool) {
        return strikeBps >= MIN_STRIKE_BPS && strikeBps <= MAX_STRIKE_BPS;
    }
}
