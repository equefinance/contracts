// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockLendingStrategy} from "../../contracts/strategies/MockLendingStrategy.sol";
import {MockB20} from "../../contracts/mocks/MockB20.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";

contract MockLendingStrategyTest is Test {
    MockB20 token;
    MockLendingStrategy strategy;

    address admin = address(0xA01);
    address vault = address(0xA02);
    address keeper = address(0xA03);
    address stranger = address(0xA04);

    function setUp() public {
        token = new MockB20("Test Stock", "TST", admin);
        strategy = new MockLendingStrategy(address(token), admin);
        vm.prank(admin);
        strategy.setVault(vault);
    }

    function test_ConstructorRejectsZeroAsset() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        new MockLendingStrategy(address(0), admin);
    }

    function test_SetVaultIsAdminOnlyAndOneTime() public {
        MockLendingStrategy fresh = new MockLendingStrategy(address(token), admin);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.Unauthorized.selector));
        fresh.setVault(vault);
        vm.prank(admin);
        fresh.setVault(vault);
        assertEq(fresh.vault(), vault);
        vm.prank(admin);
        vm.expectRevert(MockLendingStrategy.AlreadySet.selector);
        fresh.setVault(address(0xA05));
    }

    function test_SetVaultRejectsZeroAddress() public {
        MockLendingStrategy fresh = new MockLendingStrategy(address(token), admin);
        vm.prank(admin);
        vm.expectRevert(MockLendingStrategy.AlreadySet.selector);
        fresh.setVault(address(0));
    }

    function test_AllocateIsVaultOnlyAndAccumulates() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotVault.selector));
        strategy.allocate(1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotVault.selector));
        strategy.allocate(1 ether);

        // The vault pushes the tokens itself, then calls allocate to book them.
        vm.prank(admin);
        token.mint(address(strategy), 5 ether);
        vm.prank(vault);
        strategy.allocate(5 ether);
        assertEq(strategy.principal(), 5 ether);
        assertEq(strategy.totalAssets(), 5 ether);

        // A second allocation keeps the original deposit timestamp so the
        // yield clock does not restart.
        uint256 startedAt = strategy.depositedAt();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(admin);
        token.mint(address(strategy), 2 ether);
        vm.prank(vault);
        strategy.allocate(2 ether);
        assertEq(strategy.principal(), 7 ether);
        assertEq(strategy.depositedAt(), startedAt);
    }

    function test_AccruedYieldIsTwoPercentLinear() public {
        vm.prank(admin);
        token.mint(address(strategy), 100 ether);
        vm.prank(vault);
        strategy.allocate(100 ether);
        assertEq(strategy.accruedYield(), 0);

        vm.warp(block.timestamp + 365 days);
        assertEq(strategy.accruedYield(), 2 ether);
        // Realizable assets never count the accrued yield: totalAssets is
        // exactly what the strategy can transfer back.
        assertEq(strategy.totalAssets(), 100 ether);
    }

    function test_WithdrawIsVaultOnlyAndClampsToPrincipal() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotVault.selector));
        strategy.withdraw(1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotVault.selector));
        strategy.withdraw(1 ether);

        vm.prank(admin);
        token.mint(address(strategy), 8 ether);
        vm.prank(vault);
        strategy.allocate(8 ether);

        vm.prank(vault);
        uint256 got = strategy.withdraw(100 ether); // asked for more than held
        assertEq(got, 8 ether);
        assertEq(strategy.principal(), 0);
        assertEq(token.balanceOf(vault), 8 ether);
    }

    function test_WithdrawPartialKeepsAccrualRunning() public {
        vm.prank(admin);
        token.mint(address(strategy), 10 ether);
        vm.prank(vault);
        strategy.allocate(10 ether);

        vm.prank(vault);
        assertEq(strategy.withdraw(4 ether), 4 ether);
        assertEq(strategy.principal(), 6 ether);
        // No tokens left idle on the strategy beyond what it owes back later.
        assertEq(token.balanceOf(address(strategy)), 6 ether);
    }

    function test_HarvestChangesNothing() public {
        vm.prank(admin);
        token.mint(address(strategy), 3 ether);
        vm.prank(vault);
        strategy.allocate(3 ether);
        strategy.harvest();
        assertEq(strategy.principal(), 3 ether);
        assertEq(strategy.totalAssets(), 3 ether);
    }
}