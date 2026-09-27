// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {EqueVault} from "../../contracts/core/EqueVault.sol";
import {EqueRouter} from "../../contracts/core/EqueRouter.sol";
import {EqueVaultFactory} from "../../contracts/core/EqueVaultFactory.sol";
import {EpochStrategy} from "../../contracts/strategies/EpochStrategy.sol";
import {MockLendingStrategy} from "../../contracts/strategies/MockLendingStrategy.sol";
import {MockB20} from "../../contracts/mocks/MockB20.sol";
import {MockV3Aggregator} from "../../contracts/oracle/MockV3Aggregator.sol";
import {OracleGuard} from "../../contracts/oracle/OracleGuard.sol";
import {EpochMath} from "../../contracts/libraries/EpochMath.sol";

/// Full-stack invariants for one complete epoch, fuzzed over the expiry price
/// and the winning premium: the books must move by exactly premium minus
/// payoff, never anything else, and the share price may only fall via an
/// exercise payout (PROJECT.md 5.6).
contract EpochInvariants is Test {
    EqueVault vault;
    EqueRouter router;
    MockB20 token;
    MockV3Aggregator feed;
    EpochStrategy epochStrategy;
    MockLendingStrategy lendingStrategy;

    address admin = address(0xB01);
    address keeper = address(0xB02);
    address curator = address(0xB03);
    address depositor = address(0xB04);
    address bidder = address(0xB05);

    uint64 constant EPOCH = 10 minutes;
    uint64 constant WINDOW = 5 minutes;
    uint256 constant CAP = 10_000 ether;
    uint256 constant MONDAY_1400 = 1_767_621_600;

    function setUp() public {
        vm.warp(MONDAY_1400);
        token = new MockB20("Test Stock", "TST", admin);
        vm.prank(admin);
        feed = new MockV3Aggregator(keeper, 180_00000000);

        OracleGuard.Feed memory cfg = OracleGuard.Feed({
            aggregator: AggregatorV3Interface(address(feed)),
            sequencerFeed: AggregatorV3Interface(address(0)),
            heartbeat: 1 hours,
            stalenessBuffer: 5 minutes,
            deviationBps: 0,
            checkMarketHours: false,
            checkPaused: false,
            checkSequencer: false
        });

        epochStrategy = new EpochStrategy(address(token), cfg, 120, EPOCH, WINDOW, admin);
        lendingStrategy = new MockLendingStrategy(address(token), admin);

        EqueVaultFactory factory = new EqueVaultFactory(admin);
        EqueVaultFactory.VaultSpec memory spec = EqueVaultFactory.VaultSpec({
            underlying: token,
            name: "Eque TST",
            symbol: "eTST",
            cap: CAP,
            feeRecipient: address(0),
            depositFeeBps: 0,
            withdrawFeeBps: 0,
            epochStrategy: address(epochStrategy),
            lendingStrategy: address(lendingStrategy),
            epochCapBps: 9_000,
            lendingCapBps: 5_000,
            epochWeightBps: 7_000,
            lendingWeightBps: 3_000
        });
        vm.prank(admin);
        vault = EqueVault(factory.deployVault(spec));
        router = factory.router();

        vm.prank(admin);
        epochStrategy.setVault(address(vault));
        vm.prank(admin);
        lendingStrategy.setVault(address(vault));

        bytes32 vaultKeeper = vault.KEEPER_ROLE();
        vm.prank(admin);
        vault.grantRole(vaultKeeper, keeper);
        bytes32 stratKeeper = epochStrategy.KEEPER_ROLE();
        vm.prank(admin);
        epochStrategy.grantRole(stratKeeper, keeper);

        vm.prank(admin);
        token.mint(depositor, 1_000 ether);
        vm.prank(admin);
        token.mint(bidder, 100 ether);
        vm.startPrank(bidder);
        token.approve(address(epochStrategy), type(uint256).max);
        vm.stopPrank();
    }

    /// One full cycle at a fuzzed expiry price and winning premium: everything
    /// that moves must move by exactly premium minus payoff.
    function testFuzz_FullCycleBooksMoveOnlyByPremiumMinusPayoff(
        uint256 priceRaw,
        uint256 premiumRaw,
        uint8 rollWithNoBid
    ) public {
        priceRaw = bound(priceRaw, 100e8, 400e8);
        bool placeBid = rollWithNoBid % 2 == 0;

        vm.startPrank(depositor);
        token.approve(address(vault), 10 ether);
        vault.deposit(10 ether, depositor);
        vm.stopPrank();
        vm.prank(keeper);
        vault.allocate();

        uint256 totalBefore = vault.totalAssets(); // buffer plus both strategies
        vm.prank(keeper);
        epochStrategy.startEpoch(false);
        uint256 notional = epochStrategy.currentEpoch().notional;
        uint256 strike = epochStrategy.currentEpoch().strike;

        uint256 premium;
        if (placeBid) {
            uint256 floor = EpochMath.reserveFloor(notional, 120);
            uint256 cap = (notional * 500) / 10_000; // premium sanity bound
            premium = bound(premiumRaw, floor, cap);
            vm.prank(bidder);
            epochStrategy.bid(premium);
        }

        // Mid-cycle reconciliation: the free/locked split always adds back up
        // and a running epoch counts as locked in full.
        assertEq(vault.freeAssets() + vault.lockedAssets(), vault.totalAssets());
        assertEq(vault.lockedAssets(), epochStrategy.totalAssets());

        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(keeper);
        epochStrategy.closeAuction();
        vm.prank(keeper);
        feed.updateAnswer(int256(priceRaw));
        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(keeper);
        epochStrategy.settleEpoch();

        // The feed carries 8-decimals while OracleGuard normalizes every read
        // to WAD, so the payoff expectation uses the normalized price. With
        // no winning bid no option was sold, so an in-the-money expiry pays
        // nothing: zero premium, zero impairment.
        uint256 payoff = placeBid ? EpochMath.payoff(notional, priceRaw * 1e10, strike) : 0;

        assertEq(epochStrategy.totalAssets(), notional + premium - payoff);
        assertEq(vault.totalAssets(), totalBefore + premium - payoff);

        if (placeBid) {
            assertEq(token.balanceOf(bidder), 100 ether - premium + payoff);
        } else {
            assertEq(premium, 0);
        }

        // Share price is monotonic except via exercise payout; when an
        // exercise outpaced the premium, the loss is exactly that difference.
        if (premium >= payoff) {
            assertGe(vault.totalAssets(), totalBefore);
        } else {
            assertEq(totalBefore - vault.totalAssets(), payoff - premium);
        }
    }

    /// The no-bid roll: zero premium, zero impairment, books untouched.
    function test_NoBidRollMovesNothing() public {
        vm.startPrank(depositor);
        token.approve(address(vault), 10 ether);
        vault.deposit(10 ether, depositor);
        vm.stopPrank();
        vm.prank(keeper);
        vault.allocate();
        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        epochStrategy.startEpoch(false);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(keeper);
        epochStrategy.closeAuction();
        vm.prank(keeper);
        feed.updateAnswer(200_00000000); // even far in the money
        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(keeper);
        epochStrategy.settleEpoch();

        assertEq(epochStrategy.totalAssets(), 7 ether);
        assertEq(vault.totalAssets(), totalBefore); // zero impairment
    }
}