// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreFixture} from "./CoreFixture.t.sol";
import {EqueRouter} from "../../contracts/core/EqueRouter.sol";
import {IEqueRouter} from "../../contracts/interfaces/IEqueRouter.sol";
import {EqueAccess} from "../../contracts/utils/EqueAccess.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";

contract EqueRouterTest is CoreFixture {
    function test_RegistryAndWeightsWired() public {
        setUpCore();
        (uint256 epochBps, uint256 lendingBps) = router.weights(address(vault));
        assertEq(epochBps, 7_000);
        assertEq(lendingBps, 3_000);
    }

    function test_PlanAllocationRespectsWeights() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        (address[] memory strategies, uint256[] memory amounts) = router.planAllocation(address(vault));
        assertEq(strategies.length, 2);
        // 70/30 of the 10-token buffer: epoch 7, lending 3.
        assertEq(amounts[0], 7 ether);
        assertEq(amounts[1], 3 ether);
    }

    function test_PlanAllocationWithinHysteresisDoesNothing() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(keeper);
        vault.allocate();
        // 70/30 achieved; a small deposit (5%) stays inside the default 5%
        // tolerance? 500 bps tolerance: new split vs target — verify no churn.
        _deposit(depositor, 0.4 ether);
        (, uint256[] memory amounts) = router.planAllocation(address(vault));
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 0);
    }

    function test_PlanAllocationBeyondHysteresisResumes() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(keeper);
        vault.allocate();
        // A large deposit pushes the split outside tolerance.
        _deposit(depositor, 10 ether);
        (, uint256[] memory amounts) = router.planAllocation(address(vault));
        assertGt(amounts[0], 0);
    }

    function test_CapClampsEpochAllocation() public {
        setUpCore();
        // Cap epoch at 60% instead of 70%: allocation stops at the cap.
        vm.prank(curator);
        router.setWeights(address(vault), 7_000, 3_000);
        _deposit(depositor, 10 ether);
        vm.prank(keeper);
        vault.allocate(); // epoch holds 7

        // The curator moves the target to 60/40; rebalance must walk toward it.
        vm.prank(curator);
        router.setWeights(address(vault), 6_000, 4_000);
        vm.prank(keeper);
        router.rebalance(address(vault));
        assertEq(epochStrategy.totalAssets(), 6 ether);
        assertEq(lendingStrategy.totalAssets(), 4 ether);
    }

    function test_RebalanceRejectsWhenLocked() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(keeper);
        vault.allocate();
        // A weight change creates distance; the lock then blocks the move.
        vm.prank(curator);
        router.setWeights(address(vault), 6_000, 4_000);
        epochStrategy.start(); // lock the epoch leg
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IEqueRouter.StrategyLocked.selector));
        router.rebalance(address(vault));
    }

    function test_PlanAllocationSurvivesCapBelowHoldings() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(keeper);
        vault.allocate(); // epoch holds 7, lending 3

        // The curator lowers the epoch cap below what the strategy already
        // holds and moves the target up; planning must refuse to add to that
        // leg rather than underflow.
        vm.prank(curator);
        router.registerStrategy(address(vault), address(epochStrategy), 5_000);
        vm.prank(curator);
        router.setWeights(address(vault), 8_000, 2_000);

        (, uint256[] memory amounts) = router.planAllocation(address(vault));
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 0);
    }

    function test_RebalanceAtTargetReverts() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(keeper);
        vault.allocate(); // lands exactly on 70/30

        // The keeper cannot churn the book: a rebalance that would not move
        // the vault toward its target must revert.
        vm.prank(keeper);
        vm.expectRevert(IEqueRouter.NothingToRebalance.selector);
        router.rebalance(address(vault));
    }

    function test_RebalanceRequiresKeeper() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(EqueAccess.NotKeeper.selector));
        router.rebalance(address(vault));
    }

    function test_WeightsMustSumToTenThousand() public {
        setUpCore();
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IEqueRouter.WeightsInvalid.selector, 9_999));
        router.setWeights(address(vault), 6_999, 3_000);
    }

    function test_StrategyHoldingsReported() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(keeper);
        vault.allocate();
        (address[] memory strategies, uint256[] memory holdings) = router.strategyHoldings(address(vault));
        assertEq(strategies[0], address(epochStrategy));
        assertEq(holdings[0], 7 ether);
        assertEq(holdings[1], 3 ether);
    }

    function test_LendingYieldGrowsHoldings() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(keeper);
        vault.allocate();
        vm.warp(block.timestamp + 365 days / 2); // half year: ~1% of 3
        (, uint256[] memory holdings) = router.strategyHoldings(address(vault));
        assertGt(holdings[1], 3 ether);
    }
}
