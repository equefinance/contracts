// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockB20} from "../../contracts/mocks/MockB20.sol";
import {MockStocks} from "../../contracts/mocks/MockStocks.sol";
import {TestnetFaucet} from "../../contracts/mocks/TestnetFaucet.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";

contract TestnetFaucetTest is Test {
    address keeper = address(0xE11);
    address user = address(0xE22);
    address owner = address(0xE44);

    MockStocks stockToken;
    MockB20 genericToken;
    TestnetFaucet faucet;

    function setUp() public {
        stockToken = new MockStocks("NVIDIA Corporation Tokenized Stock", "NVDA", "Robinhood Chain", owner);
        genericToken = new MockB20("Tesla Inc. Tokenized Stock", "TSLAc", owner);
        vm.prank(owner);
        faucet = new TestnetFaucet(address(stockToken), address(genericToken));
        // Deploy scripts fund the faucet right after deployment; the test
        // mirrors that handoff.
        vm.prank(owner);
        stockToken.transfer(address(faucet), 1_000_000 ether);
        vm.prank(owner);
        genericToken.transfer(address(faucet), 1_000_000 ether);
    }

    function test_DepositorTabClaim() public {
        vm.prank(user);
        uint256 got = faucet.claimDepositor();
        assertEq(got, 10 ether);
        assertEq(stockToken.balanceOf(user), 10 ether);
    }

    function test_BidderTabClaim() public {
        vm.prank(user);
        uint256 got = faucet.claimBidder();
        assertEq(got, 1000 ether);
        assertEq(genericToken.balanceOf(user), 1000 ether);
    }

    function test_DepositorCooldownEnforced() public {
        vm.startPrank(user);
        faucet.claimDepositor();
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.Cooldown.selector, block.timestamp + 1 hours));
        faucet.claimDepositor();
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(user);
        uint256 got = faucet.claimDepositor();
        assertEq(got, 10 ether);
    }

    function test_BidderCooldownShorter() public {
        vm.startPrank(user);
        faucet.claimBidder();
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.Cooldown.selector, block.timestamp + 10 minutes));
        faucet.claimBidder();
        vm.stopPrank();

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(user);
        assertEq(faucet.claimBidder(), 1000 ether);
    }

    function test_TabsAreIndependent() public {
        vm.prank(user);
        faucet.claimDepositor();
        vm.prank(user);
        assertEq(faucet.claimBidder(), 1000 ether);
    }

    function test_NextViewHelpers() public {
        vm.prank(user);
        faucet.claimDepositor();
        assertEq(faucet.nextDepositorClaim(user), block.timestamp + 1 hours);
        assertEq(faucet.nextBidderClaim(user), 10 minutes);
    }

    function test_FirstClaimHasNoCooldown() public view {
        assertEq(faucet.depositorLastClaim(user), 0);
        assertEq(faucet.bidderLastClaim(user), 0);
    }

    function test_OnlyOwnerConfiguresAndDrains() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.NotOwner.selector));
        faucet.setDepositorTab(address(genericToken), 5 ether, 2 hours);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.NotOwner.selector));
        faucet.drain(address(stockToken), 1);

        vm.prank(owner);
        faucet.setDepositorTab(address(genericToken), 5 ether, 2 hours);
        (, uint256 amount, uint32 interval) = faucet.depositorTab();
        assertEq(amount, 5 ether);
        assertEq(interval, 2 hours);
    }

    function test_DrainTransfersToOwner() public {
        // setUp left the owner with zero of each token; draining returns the
        // exact amount requested.
        vm.prank(owner);
        faucet.drain(address(stockToken), 100 ether);
        assertEq(stockToken.balanceOf(owner), 100 ether);
    }

    function test_InvalidTabConfigRejected() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidConfig.selector));
        faucet.setDepositorTab(address(0), 5 ether, 2 hours);
    }
}
