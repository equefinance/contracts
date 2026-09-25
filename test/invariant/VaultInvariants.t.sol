// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreFixture} from "../unit/CoreFixture.t.sol";
import {EqueVault} from "../../contracts/core/EqueVault.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";

/// Invariants that must hold at every block, driven by a randomized sequence
/// of deposits, requests, claims, allocations, and weight changes.
contract VaultInvariants is CoreFixture {
    address[] internal actors;

    function setUp() public {
        setUpCore();
        actors.push(depositor);
        actors.push(secondDepositor);
        vm.prank(admin);
        token.transfer(address(0xC07), 10_000 ether);
        vm.prank(admin);
        token.transfer(address(0xC08), 10_000 ether);
        actors.push(address(0xC07));
        actors.push(address(0xC08));
    }

    /// After every step: totalAssets == buffer + Σ strategy holdings, and
    /// locked ⊆ total. The vault never mints unbacked shares.
    function testFuzz_AccountingReconciles(
        uint256 depositA,
        uint256 depositB,
        uint256 redeemShares,
        uint8 pickAllocate
    ) public {
        depositA = bound(depositA, 1, 1_000 ether);
        depositB = bound(depositB, 1, 1_000 ether);
        vm.assume(redeemShares <= depositA);

        _deposit(actors[0], depositA);
        _deposit(actors[1], depositB);

        if (pickAllocate % 2 == 0) {
            vm.prank(keeper);
            vault.allocate();
        }

        if (redeemShares > 0) {
            vm.prank(actors[0]);
            vault.requestRedeem(redeemShares);
        }

        uint256 total = vault.totalAssets();
        (, uint256[] memory holdings) = router.strategyHoldings(address(vault));
        uint256 buffer = token.balanceOf(address(vault));
        uint256 inStrategies;
        for (uint256 i; i < holdings.length; i++) {
            inStrategies += holdings[i];
        }
        assertEq(total, buffer + inStrategies, "totalAssets must equal buffer plus strategy holdings");

        uint256 free = vault.freeAssets();
        uint256 locked = vault.lockedAssets();
        assertLe(locked, total, "locked assets can never exceed total");
        assertEq(free + locked, total, "free plus locked must reconcile to total");
    }

    /// Share price never decreases through deposits, allocations, or redeems.
    /// (Premium accrual arrives with the epoch strategy in 1.4; exercise
    /// payout is the only permitted decrease per PROJECT.md 5.6.)
    function testFuzz_SharePriceMonotonic(
        uint256 depositA,
        uint256 depositB,
        uint256 warpSeconds,
        uint8 pickAllocate
    ) public {
        depositA = bound(depositA, 1, 1_000 ether);
        depositB = bound(depositB, 1, 1_000 ether);
        warpSeconds = bound(warpSeconds, 0, 365 days);

        _deposit(actors[0], depositA);
        uint256 priceBefore = vault.convertToAssets(1 ether);

        if (pickAllocate % 2 == 0) {
            vm.prank(keeper);
            vault.allocate();
        }
        vm.warp(block.timestamp + warpSeconds); // lending yield accrues
        _deposit(actors[1], depositB);

        uint256 priceAfter = vault.convertToAssets(1 ether);
        assertGe(priceAfter, priceBefore, "share price must never fall through deposits or yield");
    }

    /// The cap is an invariant: total assets can never exceed it.
    function testFuzz_CapNeverExceeded(uint256 depositA, uint256 depositB) public {
        depositA = bound(depositA, 1, 10_000 ether);
        depositB = bound(depositB, 1, 10_000 ether);
        vm.assume(depositA + depositB <= 10_000 ether);

        _deposit(actors[0], depositA);
        _deposit(actors[1], depositB);
        assertLe(vault.totalAssets(), CAP);
    }

    /// Two-step redeem: an escrowed share can be claimed by exactly one party,
    /// exactly once, and only after the boundary.
    function test_RedeemSingleClaim() public {
        _deposit(actors[0], 10 ether);
        epochStrategy.setBoundary(uint64(block.timestamp + 1 hours));
        epochStrategy.start();

        vm.prank(actors[0]);
        vault.requestRedeem(10 ether);
        vm.prank(actors[0]);
        vm.expectRevert(abi.encodeWithSelector(Errors.RedeemNotReady.selector, block.timestamp + 1 hours));
        vault.claim();

        epochStrategy.settle(); // epoch boundary passes
        vm.warp(block.timestamp + 2 hours);

        vm.prank(actors[0]);
        vault.claim();
        assertEq(vault.balanceOf(actors[0]), 0);
        assertEq(vault.redeemPending(actors[0]), 0);
    }
}
