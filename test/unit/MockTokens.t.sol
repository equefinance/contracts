// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockB20} from "../../contracts/mocks/MockB20.sol";
import {MockStocks} from "../../contracts/mocks/MockStocks.sol";

contract MockTokensTest is Test {
    address keeper = address(0xE11);
    address user = address(0xE22);
    address stranger = address(0xE33);

    function test_MockB20MetadataAndInitialMint() public {
        MockB20 t = new MockB20("Tesla Inc. Tokenized Stock", "TSLAc", keeper);
        assertEq(t.name(), "Tesla Inc. Tokenized Stock");
        assertEq(t.symbol(), "TSLAc");
        assertEq(t.decimals(), 18);
        assertEq(t.balanceOf(keeper), 1_000_000 ether);
    }

    function test_MockB20KeeperMints() public {
        MockB20 t = new MockB20("T", "T", keeper);
        vm.prank(keeper);
        t.mint(user, 5 ether);
        assertEq(t.balanceOf(user), 5 ether);
    }

    function test_MockB20StrangerCannotMint() public {
        MockB20 t = new MockB20("T", "T", keeper);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockB20.NotKeeper.selector));
        t.mint(user, 1);
    }

    function test_MockStocksMetadata() public {
        MockStocks t = new MockStocks(
            "NVIDIA Corporation Tokenized Stock",
            "NVDA",
            "Robinhood Chain",
            keeper
        );
        assertEq(t.name(), "NVIDIA Corporation Tokenized Stock");
        assertEq(t.symbol(), "NVDA");
        assertEq(t.decimals(), 18);
        assertEq(t.issuer(), "Robinhood Chain");
        assertEq(t.underlyingTicker(), "NVDA");
        assertEq(t.balanceOf(keeper), 1_000_000 ether);
    }

    function test_MockStocksKeeperMints() public {
        MockStocks t = new MockStocks("Apple Inc. Tokenized Stock", "AAPL", "Robinhood Chain", keeper);
        vm.prank(keeper);
        t.mint(user, 2 ether);
        assertEq(t.balanceOf(user), 2 ether);
    }

    function test_MockStocksStrangerCannotMint() public {
        MockStocks t = new MockStocks("A", "A", "Robinhood Chain", keeper);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockStocks.NotKeeper.selector));
        t.mint(user, 1);
    }
}
