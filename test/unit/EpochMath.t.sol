// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EpochMath} from "../../contracts/libraries/EpochMath.sol";

contract EpochMathTest is Test {
    function test_StrikeIs105PercentOfSpot() public pure {
        assertEq(EpochMath.strike(180 ether, 10_500), 189 ether);
        assertEq(EpochMath.strike(230 ether, 10_500), 241.5 ether);
    }

    function test_StrikeZeroSpotReturnsZero() public pure {
        assertEq(EpochMath.strike(0, 10_500), 0);
    }

    function test_PayoffZeroWhenSpotAtOrBelowStrike() public pure {
        assertEq(EpochMath.payoff(10 ether, 189 ether, 189 ether), 0);
        assertEq(EpochMath.payoff(10 ether, 180 ether, 189 ether), 0);
        assertEq(EpochMath.payoff(10 ether, 0, 189 ether), 0);
    }

    function test_PayoffMatchesWorkedExample() public pure {
        // spot 180, strike 189, notional 10, S_T 200: payoff = 10 * 11 / 200
        assertEq(EpochMath.payoff(10 ether, 200 ether, 189 ether), 0.55 ether);
    }

    function test_SettleOTMKeepsFullPremium() public pure {
        // Case A: S_T 185 <= K 189: keep N + P
        assertEq(EpochMath.settle(10 ether, 185 ether, 189 ether, 0.12 ether), 10.12 ether);
    }

    function test_SettleITMMatchesWorkedExample() public pure {
        // Case B: S_T 200 > K 189: keep 10 - 0.55 + 0.12
        assertEq(EpochMath.settle(10 ether, 200 ether, 189 ether, 0.12 ether), 9.57 ether);
    }

    function test_BidQualifiesAtFloorAndAbove() public pure {
        // floorBps 120 on 10 tokens: floor = 0.12
        assertTrue(EpochMath.bidQualifies(0.12 ether, 10 ether, 120));
        assertTrue(EpochMath.bidQualifies(0.5 ether, 10 ether, 120));
        assertFalse(EpochMath.bidQualifies(0.11 ether, 10 ether, 120));
        assertFalse(EpochMath.bidQualifies(1 ether, 0, 120));
    }

    function test_NextBidFloorIsOnePercentPlus() public pure {
        assertEq(EpochMath.nextBidFloor(1 ether), 1.01 ether + 1);
        assertEq(EpochMath.nextBidFloor(0), 0);
        // a bid exactly at the old high can never satisfy the floor
        assertTrue(1.01 ether < EpochMath.nextBidFloor(1 ether));
        assertTrue(1.01 ether + 1 >= EpochMath.nextBidFloor(1 ether));
    }

    function test_PremiumBoundRejectsAboveFivePercent() public pure {
        assertTrue(EpochMath.premiumInBounds(10 ether, 0.5 ether, 500));
        assertFalse(EpochMath.premiumInBounds(10 ether, 0.51 ether, 500));
    }

    function test_SnipeExtensionIsTenthOfWindow() public pure {
        assertEq(EpochMath.snipeExtension(300), 30);
        assertEq(EpochMath.snipeExtension(7 days), 16 hours + 48 minutes);
    }

    function test_BidInSnipeZoneEdges() public pure {
        // 300s window: last 30s trigger extension; exactly at the zone edge
        // still counts as sniping.
        assertTrue(EpochMath.bidInSnipeZone(1_000, 971, 300));
        assertTrue(EpochMath.bidInSnipeZone(1_000, 970, 300));
        assertFalse(EpochMath.bidInSnipeZone(1_000, 969, 300));
        assertFalse(EpochMath.bidInSnipeZone(1_000, 1_001, 300));
    }

    function test_StrikeBpsBounds() public pure {
        assertTrue(EpochMath.validateStrikeBps(10_500));
        assertFalse(EpochMath.validateStrikeBps(10_500 + 1_500 + 1));
        assertFalse(EpochMath.validateStrikeBps(10_000));
    }

    // Fuzz: payoff never exceeds notional; settle >= premium; strike above spot.
    function testFuzz_PayoffCappedByNotional(uint256 notional, uint256 spot, uint256 strikePrice) public pure {
        notional = bound(notional, 1, 1e30);
        spot = bound(spot, 1, 1e30);
        strikePrice = bound(strikePrice, 1, type(uint256).max / 2);
        strikePrice = strikePrice > spot ? strikePrice : spot + 1;

        uint256 p = EpochMath.payoff(notional, spot, strikePrice);
        assertLt(p, notional + 1);

        uint256 kept = EpochMath.settle(notional, spot, strikePrice, 0);
        assertLt(kept, notional + 1);
        assertGt(kept, 0);
    }

    // Fuzz: OTM settle is always exactly notional + premium.
    function testFuzz_OTMSettleKeepsAll(uint256 notional, uint256 spot, uint256 premium) public pure {
        notional = bound(notional, 1, 1e30);
        spot = bound(spot, 1, 1e30);
        premium = bound(premium, 0, 1e24);
        assertEq(EpochMath.settle(notional, spot, spot, premium), notional + premium);
        assertEq(EpochMath.settle(notional, spot - 1, spot, premium), notional + premium);
    }

    // Fuzz: strike never at or below spot when strikeBps is validated.
    function testFuzz_StrikeAboveSpot(uint256 spot, uint256 strikeBps) public pure {
        spot = bound(spot, 1, 1e30);
        strikeBps = bound(strikeBps, EpochMath.MIN_STRIKE_BPS, EpochMath.MAX_STRIKE_BPS);
        assertTrue(EpochMath.strike(spot, strikeBps) > spot);
    }
}
