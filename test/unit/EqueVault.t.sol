// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreFixture} from "./CoreFixture.t.sol";
import {EqueVault} from "../../contracts/core/EqueVault.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract EqueVaultTest is CoreFixture {
    function test_InitializeViaFactory() public {
        setUpCore();
        assertEq(vault.name(), "Eque TST");
        assertEq(vault.symbol(), "eTST");
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(token));
        assertEq(vault.cap(), CAP);
        assertEq(address(vault.router()), address(router));
    }

    function test_DepositMintsShares() public {
        setUpCore();
        vm.startPrank(depositor);
        token.approve(address(vault), 10 ether);
        uint256 shares = vault.deposit(10 ether, depositor);
        vm.stopPrank();
        assertEq(shares, 10 ether);
        assertEq(vault.balanceOf(depositor), 10 ether);
        assertEq(vault.totalAssets(), 10 ether);
        assertEq(token.balanceOf(address(vault)), 10 ether);
    }

    function test_FreeAndLockedSplitEmpty() public {
        setUpCore();
        assertEq(vault.freeAssets(), 0);
        assertEq(vault.lockedAssets(), 0);
    }

    function test_FreeAndLockedSplitWithBuffer() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        assertEq(vault.freeAssets(), 10 ether);
        assertEq(vault.lockedAssets(), 0);
    }

    function test_CapExceededReverts() public {
        setUpCore();
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(Errors.VaultCapExceeded.selector, CAP, CAP + 1));
        vault.deposit(CAP + 1, depositor);
    }

    function test_CapBoundaryAccepted() public {
        setUpCore();
        _deposit(depositor, CAP);
        assertEq(vault.totalAssets(), CAP);
    }

    function test_GuardianCanPause() public {
        setUpCore();
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vault.deposit(1 ether, depositor);
    }

    function test_GuardianCannotUnpause() public {
        setUpCore();
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCurator.selector));
        vault.unpause();
    }

    function test_ClaimStillOpenWhenPaused() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(depositor);
        vault.requestRedeem(10 ether);
        vm.prank(guardian);
        vault.pause();
        // Emergency exit stays available: claiming pays out even while paused.
        vm.prank(depositor);
        vault.claim();
        assertEq(vault.balanceOf(depositor), 0);
        assertEq(token.balanceOf(depositor), 10_000 ether);
    }

    function test_TwoStepRedeemFlow() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(depositor);
        vault.requestRedeem(4 ether);
        assertEq(vault.redeemPending(depositor), 4 ether);
        // Escrow: supply unchanged, shares moved into vault custody.
        assertEq(vault.totalSupply(), 10 ether);
        assertEq(vault.balanceOf(depositor), 6 ether);
        assertEq(vault.balanceOf(address(vault)), 4 ether);
    }

    function test_RequestRedeemNotReadyBeforeBoundary() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        uint64 future = uint64(block.timestamp + 1 hours);
        epochStrategy.setBoundary(future);
        epochStrategy.start();
        vm.prank(depositor);
        vault.requestRedeem(4 ether);
        assertEq(vault.redeemReadyAt(depositor), future);
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(Errors.RedeemNotReady.selector, future));
        vault.claim();
    }

    function test_FeesFlowToRecipient() public {
        setUpCore();
        vm.prank(curator);
        vault.setFees(100, 50); // 1% deposit, 0.5% withdraw
        vm.prank(curator);
        vault.setFeeRecipient(address(0xFEE1));
        vm.startPrank(depositor);
        token.approve(address(vault), 10 ether);
        vault.deposit(10 ether, depositor);
        vm.stopPrank();
        assertEq(token.balanceOf(address(0xFEE1)), 0.1 ether);
        assertEq(vault.totalAssets(), 9.9 ether);
    }

    function test_OnlyCuratorSetsCap() public {
        setUpCore();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCurator.selector));
        vault.setCap(1 ether);
        vm.prank(curator);
        vault.setCap(5 ether);
        assertEq(vault.cap(), 5 ether);
    }

    function test_DirectWithdrawAlwaysReverts() public {
        setUpCore();
        vm.prank(depositor);
        vm.expectRevert(EqueVault.UnsupportedDirectWithdraw.selector);
        vault.withdraw(1 ether, depositor, depositor);
        vm.prank(depositor);
        vm.expectRevert(EqueVault.UnsupportedDirectWithdraw.selector);
        vault.redeem(1 ether, depositor, depositor);
    }

    function test_SharePriceMonotonicOnDeposit() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        uint256 p1 = vault.convertToAssets(1 ether);
        _deposit(secondDepositor, 30 ether);
        uint256 p2 = vault.convertToAssets(1 ether);
        assertGe(p2, p1);
    }

    function test_ZeroDepositReverts() public {
        setUpCore();
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAmount.selector));
        vault.deposit(0, depositor);
    }

    function test_SecondRequestRejected() public {
        setUpCore();
        _deposit(depositor, 10 ether);
        vm.prank(depositor);
        vault.requestRedeem(1 ether);
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(Errors.RedeemRequestPending.selector));
        vault.requestRedeem(1 ether);
    }
}

