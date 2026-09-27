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
import {Errors} from "../../contracts/libraries/Errors.sol";
import {IEpochStrategy} from "../../contracts/interfaces/IEpochStrategy.sol";

/// Full-stack flow: factory deploys vault wired to a real EpochStrategy and a
/// MockLendingStrategy; a depositor enters, the keeper allocates and runs a
/// full epoch, the premium compounds, and the depositor exits through the
/// two-step redeem.
contract EpochFlowTest is Test {
    EqueVault vault;
    EqueRouter router;
    MockB20 token;
    MockV3Aggregator feed;
    EpochStrategy epochStrategy;
    MockLendingStrategy lendingStrategy;

    address admin = address(0xE01);
    address keeper = address(0xE02);
    address curator = address(0xE03);
    address guardian = address(0xE04);
    address depositor = address(0xE05);
    address bidder = address(0xE06);

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

        // Strategies learn their vault; the deployer wiring is one-time.
        vm.prank(admin);
        epochStrategy.setVault(address(vault));
        vm.prank(admin);
        lendingStrategy.setVault(address(vault));

        bytes32 vaultKeeper = vault.KEEPER_ROLE();
        bytes32 vaultGuardian = vault.GUARDIAN_ROLE();
        bytes32 vaultCurator = vault.CURATOR_ROLE();
        vm.prank(admin);
        vault.grantRole(vaultKeeper, keeper);
        vm.prank(admin);
        vault.grantRole(vaultGuardian, guardian);
        vm.prank(admin);
        vault.grantRole(vaultCurator, curator);

        bytes32 stratKeeper = epochStrategy.KEEPER_ROLE();
        vm.prank(admin);
        epochStrategy.grantRole(stratKeeper, keeper);

        bytes32 routerCurator = router.CURATOR_ROLE();
        vm.prank(admin);
        router.grantRole(routerCurator, curator);
        bytes32 routerKeeper = router.KEEPER_ROLE();
        vm.prank(admin);
        router.grantRole(routerKeeper, keeper);

        vm.prank(admin);
        token.mint(depositor, 1_000 ether);
        vm.prank(admin);
        token.mint(bidder, 100 ether);
        vm.startPrank(bidder);
        token.approve(address(epochStrategy), type(uint256).max);
        vm.stopPrank();
    }

    function test_FullEpochThroughVault() public {
        // 1. Deposit lands in the vault buffer.
        vm.startPrank(depositor);
        token.approve(address(vault), 10 ether);
        vault.deposit(10 ether, depositor);
        vm.stopPrank();
        assertEq(vault.freeAssets(), 10 ether);
        assertEq(vault.lockedAssets(), 0);

        // 2. Keeper allocates 70/30 into the strategies.
        vm.prank(keeper);
        vault.allocate();
        assertEq(epochStrategy.totalAssets(), 7 ether);
        assertEq(lendingStrategy.totalAssets(), 3 ether);

        // 3. A full epoch runs: auction, lock, settle with an OTM close.
        vm.prank(keeper);
        epochStrategy.startEpoch(false);
        assertEq(epochStrategy.currentEpoch().notional, 7 ether);

        vm.prank(bidder);
        epochStrategy.bid(0.084 ether); // 120 bps of 7
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(keeper);
        epochStrategy.closeAuction();

        vm.prank(keeper);
        feed.updateAnswer(185_00000000); // OTM vs 189 strike
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        epochStrategy.settleEpoch();

        // 4. The premium compounded: strategy balance grew by 0.084.
        assertEq(epochStrategy.totalAssets(), 7.084 ether);
        assertGt(vault.totalAssets(), 10 ether); // lending yield plus premium
    }

    function test_WithdrawalWaitsForSettlement() public {
        vm.startPrank(depositor);
        token.approve(address(vault), 10 ether);
        vault.deposit(10 ether, depositor);
        vm.stopPrank();
        vm.prank(keeper);
        vault.allocate();

        vm.prank(keeper);
        epochStrategy.startEpoch(false);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(keeper);
        epochStrategy.closeAuction(); // notional locked now

        // A redeem request during the locked epoch is served only after
        // settlement; the vault knows the boundary from the strategy.
        vm.prank(depositor);
        vault.requestRedeem(10 ether);
        uint256 readyAt = vault.redeemReadyAt(depositor);
        assertGt(readyAt, block.timestamp);

        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(Errors.RedeemNotReady.selector, readyAt));
        vault.claim();
    }

    function test_MidEpochDepositStaysInBufferUntilBoundary() public {
        vm.startPrank(depositor);
        token.approve(address(vault), 15 ether);
        vault.deposit(10 ether, depositor);
        vm.stopPrank();
        vm.prank(keeper);
        vault.allocate();

        // Run the epoch into its locked phase.
        vm.prank(keeper);
        epochStrategy.startEpoch(false);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(keeper);
        epochStrategy.closeAuction();

        // A mid-epoch deposit sits in the buffer; the epoch is untouched.
        vm.prank(depositor);
        vault.deposit(5 ether, depositor);
        assertEq(token.balanceOf(address(vault)), 5 ether);
        assertEq(vault.lockedAssets(), 7 ether);
        assertEq(vault.freeAssets(), 8 ether); // buffer 5 plus lending 3

        // Allocation is refused mid-epoch: the vault reverts on the strategy
        // leg and the whole call rolls back, so nothing moves.
        vm.prank(keeper);
        vm.expectRevert(IEpochStrategy.AuctionNotOpen.selector);
        vault.allocate();
        assertEq(token.balanceOf(address(vault)), 5 ether);
        assertEq(epochStrategy.totalAssets(), 7 ether);

        // After settlement the boundary opens and the buffer is allocated.
        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(keeper);
        epochStrategy.settleEpoch();
        vm.prank(keeper);
        vault.allocate();
        assertEq(epochStrategy.totalAssets(), 10.5 ether); // 70% of 15
        assertEq(lendingStrategy.totalAssets(), 4.5 ether);
    }

    function test_RebalancePullsFromLendingOnlyMidEpoch() public {
        vm.startPrank(depositor);
        token.approve(address(vault), 10 ether);
        vault.deposit(10 ether, depositor);
        vm.stopPrank();
        vm.prank(keeper);
        vault.allocate();

        vm.prank(keeper);
        epochStrategy.startEpoch(false);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(keeper);
        epochStrategy.closeAuction();

        // Curator shifts the target; the epoch leg is locked, so rebalance
        // must refuse rather than touch the locked notional.
        vm.prank(curator);
        router.setWeights(address(vault), 6_000, 4_000);
        vm.prank(keeper);
        vm.expectRevert();
        router.rebalance(address(vault));
    }
}
