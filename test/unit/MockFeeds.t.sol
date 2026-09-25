// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockV3Aggregator} from "../../contracts/oracle/MockV3Aggregator.sol";
import {EqueAccess} from "../../contracts/utils/EqueAccess.sol";
import {MockSequencerFeed} from "../../contracts/oracle/MockSequencerFeed.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";

contract MockFeedsTest is Test {
    address keeper = address(0xE11);
    address stranger = address(0xE33);

    MockV3Aggregator feed;

    function setUp() public {
        vm.prank(keeper);
        feed = new MockV3Aggregator(keeper, 180_00000000);
    }

    function test_MetadataAndInitialAnswer() public view {
        assertEq(feed.decimals(), 8);
        assertEq(feed.version(), 1);
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        assertEq(answer, 180_00000000);
        assertEq(updatedAt, block.timestamp);
        assertGt(feed.latestRound(), 0);
    }

    function test_KeeperUpdatesAnswer() public {
        vm.prank(keeper);
        feed.updateAnswer(181_00000000);
        (, int256 answer, , , ) = feed.latestRoundData();
        assertEq(answer, 181_00000000);
        assertGt(feed.latestRound(), 1);
    }

    function test_StrangerCannotUpdate() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EqueAccess.NotKeeper.selector));
        feed.updateAnswer(1);
    }

    function updateExternal(int256 a) external {
        feed.updateAnswer(a);
    }

    function test_RejectsZeroAndNegativeAnswers() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleUnavailable.selector));
        feed.updateAnswer(0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleUnavailable.selector));
        feed.updateAnswer(-5);
    }

    function test_RejectsOverflowingAnswer() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MockV3Aggregator.AnswerTooLarge.selector));
        feed.updateAnswer(type(int256).max);
    }

    function test_GetRoundDataBounds() public view {
        (, int256 answer, , , uint80 answeredIn) = feed.getRoundData(feed.latestRound());
        assertEq(answer, 180_00000000);
        assertEq(answeredIn, feed.latestRound());
    }

    function test_GetRoundDataRejectsUnknown() public {
        vm.expectRevert("no such round");
        this.roundExternal(0);
    }

    function roundExternal(uint80 r) external view {
        feed.getRoundData(r);
    }

    function test_SequencerUpAndDown() public {
        MockSequencerFeed seq = new MockSequencerFeed(keeper);
        (, int256 up, uint256 updatedAt, , ) = seq.latestRoundData();
        assertEq(up, 1);
        assertEq(updatedAt, block.timestamp);

        vm.prank(keeper);
        seq.setUp(false);
        (, int256 down, , , ) = seq.latestRoundData();
        assertEq(down, 0);
    }

    function test_SequencerStrangerCannotUpdate() public {
        MockSequencerFeed seq = new MockSequencerFeed(keeper);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockSequencerFeed.NotKeeper.selector));
        seq.setUp(true);
    }
}
