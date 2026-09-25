// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MockB20} from "../../contracts/mocks/MockB20.sol";
import {MockV3Aggregator} from "../../contracts/oracle/MockV3Aggregator.sol";
import {OracleGuard} from "../../contracts/oracle/OracleGuard.sol";
import {EpochStrategy} from "../../contracts/strategies/EpochStrategy.sol";
import {IEpochStrategy} from "../../contracts/interfaces/IEpochStrategy.sol";
import {EpochMath} from "../../contracts/libraries/EpochMath.sol";

contract EpochStrategyTest is Test {
    MockB20 token;
    MockV3Aggregator feed;
    EpochStrategy strategy;

    address admin = address(0xD01);
    address keeper = address(0xD02);
    address curator = address(0xD03);
    address vault = address(0xD04);
    address bidder1 = address(0xD05);
    address bidder2 = address(0xD06);
    address stranger = address(0xD07);

    uint64 constant EPOCH = 10 minutes;
    uint64 constant WINDOW = 5 minutes;
    uint256 constant NOTIONAL = 10 ether;
    uint256 constant FLOOR_BPS = 120; // 0.12 tokens on 10

    // Monday 2026-01-05 14:00 UTC, inside the equity window.
    uint256 constant MONDAY_1400 = 1_767_621_600;

    function setUp() public {
        vm.warp(MONDAY_1400);
        token = new MockB20("Test Stock", "TST", admin);
        vm.prank(admin);
        feed = new MockV3Aggregator(keeper, 180_00000000);
        strategy = new EpochStrategy(address(token), _feedConfig(), FLOOR_BPS, EPOCH, WINDOW, admin);
        vm.prank(admin);
        strategy.setVault(address(vault));

        bytes32 keeperRole = strategy.KEEPER_ROLE();
        bytes32 curatorRole = strategy.CURATOR_ROLE();
        vm.prank(admin);
        strategy.grantRole(keeperRole, keeper);
        vm.prank(admin);
        strategy.grantRole(curatorRole, curator);

        // The vault funds the strategy with the epoch notional; the vault
        // is the custodian and moves the tokens itself.
        vm.prank(admin);
        token.mint(vault, NOTIONAL);
        vm.prank(vault);
        token.transfer(address(strategy), NOTIONAL);

        vm.prank(admin);
        token.mint(bidder1, 100 ether);
        vm.prank(admin);
        token.mint(bidder2, 100 ether);
        vm.startPrank(bidder1);
        token.approve(address(strategy), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bidder2);
        token.approve(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    function _feedConfig() internal view returns (OracleGuard.Feed memory) {
        return OracleGuard.Feed({
            aggregator: AggregatorV3Interface(address(feed)),
            sequencerFeed: AggregatorV3Interface(address(0)),
            heartbeat: 1 hours,
            stalenessBuffer: 5 minutes,
            deviationBps: 0,
            checkMarketHours: false, // hours are tested separately
            checkPaused: false,
            checkSequencer: false
        });
    }

    function _start() internal {
        vm.prank(keeper);
        strategy.startEpoch(false);
    }

    function _bid(address who, uint256 amount) internal {
        vm.prank(who);
        strategy.bid(amount);
    }

    function _close() internal {
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(keeper);
        strategy.closeAuction();
    }

    function _settleAt(int256 price) internal {
        vm.prank(keeper);
        feed.updateAnswer(price);
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        strategy.settleEpoch();
    }

    // --- State machine ---

    function test_InitialStatIsNone() public view {
        assertEq(uint8(strategy.state()), uint8(IEpochStrategy.State.None));
    }

    function test_StartEpochSnapshotsAndOpens() public {
        _start();
        IEpochStrategy.Epoch memory e = strategy.currentEpoch();
        assertEq(uint8(strategy.state()), uint8(IEpochStrategy.State.Auction));
        assertEq(e.id, 1);
        assertEq(e.spot, 180 ether);
        assertEq(e.strike, 189 ether); // 105%
        assertGt(e.auctionEnd, block.timestamp);
    }

    function test_NextBidRevertsDuringAuctionEnd() public {
        _start();
        vm.warp(block.timestamp + WINDOW + 1);
        uint256 auctionEnd = strategy.currentEpoch().auctionEnd;
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IEpochStrategy.AuctionStillOpen.selector, auctionEnd));
        strategy.bid(1 ether);
    }

    function test_StartRefusedWhileAuctionOpen() public {
        _start();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IEpochStrategy.StateMismatch.selector, IEpochStrategy.State.Settled, IEpochStrategy.State.Auction)
        );
        strategy.startEpoch(false);
    }

    function test_BidRefusedWhenNotAuction() public {
        vm.prank(bidder1);
        vm.expectRevert(IEpochStrategy.AuctionNotOpen.selector);
        strategy.bid(1 ether);
    }

    function test_OnlyKeeperStarts() public {
        vm.prank(stranger);
        vm.expectRevert();
        strategy.startEpoch(false);
    }

    // --- Auction rules ---

    function test_FirstBidMustMeetFloor() public {
        _start();
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(IEpochStrategy.BidBelowFloor.selector, 0.12 ether, 0.05 ether));
        strategy.bid(0.05 ether);
        _bid(bidder1, 0.12 ether);
        assertEq(strategy.currentEpoch().highBid, 0.12 ether);
        assertEq(strategy.currentEpoch().highBidder, bidder1);
    }

    function test_TickRequiresOnePercentOver() public {
        _start();
        _bid(bidder1, 0.12 ether);
        // 0.12 * 1.01 = 0.1212; +1 wei
        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(IEpochStrategy.BidTooLow.selector, 0.1212 ether + 1, 0.1212 ether));
        strategy.bid(0.1212 ether);
        _bid(bidder2, 0.1212 ether + 1);
        assertEq(strategy.currentEpoch().highBidder, bidder2);
    }

    function test_AntiSnipeExtendsWindow() public {
        _start();
        uint256 end = strategy.currentEpoch().auctionEnd;
        vm.warp(end - 10); // last 30 seconds of the 5-minute window
        _bid(bidder1, 0.12 ether);
        // window/10 = 30 second extension
        assertEq(strategy.currentEpoch().auctionEnd, end + 30);
        assertEq(strategy.currentEpoch().extensionCount, 1);
    }

    function test_ExtensionsBounded() public {
        _start();
        uint256 end = strategy.currentEpoch().auctionEnd;
        uint256 bid = 0.12 ether;
        for (uint256 i; i < 15; i++) {
            vm.warp(strategy.currentEpoch().auctionEnd - 10);
            _bid(bidder1, bid);
            bid = EpochMath.nextBidFloor(bid);
        }
        // After 10 extensions the window no longer moves.
        assertEq(strategy.currentEpoch().extensionCount, 10);
        assertEq(strategy.currentEpoch().auctionEnd, end + 30 * 10);
    }

    function test_CloseBeforeWindowEndRefused() public {
        _start();
        uint256 auctionEnd = strategy.currentEpoch().auctionEnd;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IEpochStrategy.AuctionStillOpen.selector, auctionEnd));
        strategy.closeAuction();
    }

    function test_DoubleCloseRefused() public {
        _start();
        _close();
        vm.prank(keeper);
        vm.expectRevert(IEpochStrategy.AuctionNotOpen.selector);
        strategy.closeAuction();
    }

    // --- Settlement math (worked examples from the spec) ---

    function test_SettleOTMKeepsNotionalPlusPremium() public {
        _start();
        _bid(bidder1, 0.12 ether);
        _close();
        // S_T = 185 < K = 189: keep 10.12
        _settleAt(185_00000000);
        uint256 kept = token.balanceOf(address(strategy));
        assertEq(kept, 10.12 ether);
        assertEq(token.balanceOf(bidder1), 100 ether - 0.12 ether);
        assertEq(uint8(strategy.state()), uint8(IEpochStrategy.State.Settled));
    }

    function test_SettleITMPaysPayoff() public {
        _start();
        _bid(bidder1, 0.12 ether);
        _close();
        // S_T = 200 > K = 189: payoff 0.55, keep 9.57
        _settleAt(200_00000000);
        assertEq(token.balanceOf(address(strategy)), 9.57 ether);
        // bidder1 paid 0.12 premium, received 0.55 payoff
        assertEq(token.balanceOf(bidder1), 100 ether - 0.12 ether + 0.55 ether);
    }

    function test_SettleAtStrikeIsOTM() public {
        _start();
        _bid(bidder1, 0.12 ether);
        _close();
        _settleAt(189_00000000);
        assertEq(token.balanceOf(address(strategy)), 10.12 ether);
        assertEq(token.balanceOf(bidder1), 100 ether - 0.12 ether);
    }

    function test_NoBidRollKeepsNotional() public {
        _start();
        _close();
        _settleAt(200_00000000); // even ITM: with no option sold, no payoff
        assertEq(token.balanceOf(address(strategy)), 10 ether);
        assertEq(uint8(strategy.state()), uint8(IEpochStrategy.State.Settled));
    }

    function test_SettleBeforeExpiryRefused() public {
        _start();
        _bid(bidder1, 0.12 ether);
        _close();
        vm.warp(block.timestamp + 1);
        uint256 expiry = strategy.currentEpoch().expiry;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IEpochStrategy.EpochNotExpired.selector, expiry));
        strategy.settleEpoch();
    }

    function test_DoubleSettleRefused() public {
        _start();
        _bid(bidder1, 0.12 ether);
        _close();
        _settleAt(185_00000000);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IEpochStrategy.StateMismatch.selector, IEpochStrategy.State.Locked, IEpochStrategy.State.Settled)
        );
        strategy.settleEpoch();
    }

    function test_RollFoldsPremiumIntoNextNotional() public {
        _start();
        _bid(bidder1, 0.12 ether);
        _close();
        _settleAt(185_00000000);
        // Next epoch's notional is the full settled balance.
        vm.prank(keeper);
        strategy.startEpoch(false);
        assertEq(strategy.currentEpoch().notional, 10.12 ether);
    }

    // --- Locked collateral ---

    function test_LockedNotionalUntouchableMidEpoch() public {
        _start();
        _bid(bidder1, 0.12 ether);
        _close();
        vm.prank(keeper);
        uint256 got = strategy.withdraw(10 ether);
        assertEq(got, 0); // nothing liquid while locked
    }

    function test_ClaimablePremiumDuringLock() public {
        _start();
        _bid(bidder1, 0.12 ether);
        _close();
        assertEq(strategy.claimablePremium(), 0.12 ether);
        _settleAt(185_00000000);
        assertEq(strategy.claimablePremium(), 0);
    }

    // --- Market hours ---

    function test_StartOffHoursRefusedWithoutBypass() public {
        // Rebuild the feed config with market hours on.
        strategy = new EpochStrategy(address(token), _hoursFeedConfig(), FLOOR_BPS, EPOCH, WINDOW, admin);
        vm.prank(admin);
        strategy.setVault(address(vault));
        bytes32 role = strategy.KEEPER_ROLE();
        vm.prank(admin);
        strategy.grantRole(role, keeper);
        vm.prank(admin);
        token.mint(vault, NOTIONAL);
        vm.prank(vault);
        token.transfer(address(strategy), NOTIONAL);

        vm.warp(MONDAY_1400 + 7 hours); // 21:00 UTC, outside the window
        vm.prank(keeper);
        vm.expectRevert();
        strategy.startEpoch(false);

        vm.prank(keeper);
        feed.updateAnswer(180_00000000); // refresh so the bypass read is clean
        vm.prank(keeper);
        strategy.startEpoch(true); // explicit bypass works and is disclosed
        assertEq(uint8(strategy.state()), uint8(IEpochStrategy.State.Auction));
    }

    function test_StartOnWeekendRefused() public {
        strategy = new EpochStrategy(address(token), _hoursFeedConfig(), FLOOR_BPS, EPOCH, WINDOW, admin);
        vm.prank(admin);
        strategy.setVault(address(vault));
        bytes32 role = strategy.KEEPER_ROLE();
        vm.prank(admin);
        strategy.grantRole(role, keeper);
        vm.prank(admin);
        token.mint(vault, NOTIONAL);
        vm.prank(vault);
        token.transfer(address(strategy), NOTIONAL);

        vm.warp(1_768_053_600); // Saturday 14:00 UTC
        vm.prank(keeper);
        vm.expectRevert();
        strategy.startEpoch(false);
    }

    function _hoursFeedConfig() internal view returns (OracleGuard.Feed memory) {
        return OracleGuard.Feed({
            aggregator: AggregatorV3Interface(address(feed)),
            sequencerFeed: AggregatorV3Interface(address(0)),
            heartbeat: 1 hours,
            stalenessBuffer: 5 minutes,
            deviationBps: 0,
            checkMarketHours: true,
            checkPaused: false,
            checkSequencer: false
        });
    }

    // --- IStrategy surface ---

    function test_TotalAssetsTracksBalance() public view {
        assertEq(strategy.totalAssets(), NOTIONAL);
    }

    function test_WithdrawClampsToLiquid() public {
        vm.prank(vault);
        uint256 got = strategy.withdraw(100 ether);
        assertEq(got, NOTIONAL);
        assertEq(token.balanceOf(vault), NOTIONAL);
    }

    function test_WithdrawOnlyVaultOrKeeper() public {
        vm.prank(stranger);
        vm.expectRevert();
        strategy.withdraw(1);
    }

}
