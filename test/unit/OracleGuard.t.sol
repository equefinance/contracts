// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleGuard} from "../../contracts/oracle/OracleGuard.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";

contract MockFeed is AggregatorV3Interface {
    uint8 public decimals;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    bool public isPaused;

    constructor(uint8 _decimals, int256 _initial) {
        decimals = _decimals;
        latestAnswer = _initial;
        latestTimestamp = block.timestamp;
    }

    function updateAnswer(int256 _answer) external {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
    }

    function warp(uint256 ts) external {
        latestTimestamp = ts;
    }

    function setPaused(bool p) external virtual {
        isPaused = p;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("unused");
    }

    function latestRoundData() external view virtual returns (uint80, int256, uint256, uint256, uint80) {
        return (1, latestAnswer, latestTimestamp, latestTimestamp, 1);
    }
}

contract MockSequencer {
    int256 public latestAnswer = 1;
    uint256 public latestTimestamp;

    constructor() {
        latestTimestamp = block.timestamp;
    }

    function update(bool up) external {
        latestAnswer = up ? int256(1) : int256(0);
        latestTimestamp = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, latestAnswer, latestTimestamp, latestTimestamp, 1);
    }
}

contract PausingFeed is MockFeed {
    bool public paused;

    constructor(uint8 d, int256 a) MockFeed(d, a) {}

    function setPaused(bool p) external override {
        paused = p;
        isPaused = p;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (paused) revert("oracle paused");
        return (1, latestAnswer, latestTimestamp, latestTimestamp, 1);
    }
}

contract OracleGuardTest is Test {
    OracleGuard.Feed feed;
    MockFeed priceFeed;

    function setUp() public {
        priceFeed = new MockFeed(8, 180_00000000);
        feed = OracleGuard.Feed({
            aggregator: AggregatorV3Interface(address(priceFeed)),
            sequencerFeed: AggregatorV3Interface(address(0)),
            heartbeat: 1 hours,
            stalenessBuffer: 5 minutes,
            deviationBps: 0,
            checkMarketHours: false,
            checkPaused: false,
            checkSequencer: false
        });
    }

    uint256 testPrevPrice;

    function _read() internal view returns (uint256) {
        return OracleGuard.read(feed, testPrevPrice).price;
    }

    function readExternal() external view returns (uint256) {
        return _read();
    }

    function test_ReadsWadPrice() public view {
        // 8-decimals 180 * 1e8 -> 180e18 WAD
        assertEq(_read(), 180 ether);
    }

    function test_RejectsZeroAndNegative() public {
        priceFeed.updateAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleUnavailable.selector));
        this.readExternal();
        priceFeed.updateAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleUnavailable.selector));
        this.readExternal();
    }

    function test_RejectsStale() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleStale.selector, block.timestamp - 2 hours, block.timestamp - 2 hours + 1 hours + 5 minutes)
        );
        this.readExternal();
    }

    function test_AcceptsWithinHeartbeat() public {
        vm.warp(block.timestamp + 1 hours);
        assertEq(_read(), 180 ether);
    }

    function test_RejectsDeviation() public {
        feed.deviationBps = 500;
        assertEq(_read(), 180 ether);
        priceFeed.updateAnswer(190_00000000);
        testPrevPrice = 180 ether;
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleDeviated.selector, 190 ether, 180 ether));
        this.readExternal();
    }

    function test_RejectsPausedFeed() public {
        PausingFeed pf = new PausingFeed(8, 180_00000000);
        feed.aggregator = AggregatorV3Interface(address(pf));
        feed.checkPaused = true;
        assertEq(OracleGuard.read(feed, 0).price, 180 ether);

        pf.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(Errors.OraclePaused.selector));
        this.readExternal();
    }

    function test_FeedsWithoutPausedStillWork() public view {
        // MockFeed has no paused(); the check is off and the read succeeds.
        assertEq(_read(), 180 ether);
    }

    function test_SequencerDownReverts() public {
        MockSequencer seq = new MockSequencer();
        feed.checkSequencer = true;
        feed.sequencerFeed = AggregatorV3Interface(address(seq));

        seq.update(false);
        vm.expectRevert(abi.encodeWithSelector(Errors.SequencerDown.selector));
        this.readExternal();

        // missing feed address is also a hard stop
        feed.sequencerFeed = AggregatorV3Interface(address(0));
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleUnavailable.selector));
        this.readExternal();
    }

    function test_SequencerGracePeriod() public {
        MockSequencer seq = new MockSequencer();
        feed.checkSequencer = true;
        feed.sequencerFeed = AggregatorV3Interface(address(seq));

        // fresh "up" answer inside the grace period is not yet trustworthy
        vm.expectRevert(abi.encodeWithSelector(Errors.SequencerDown.selector));
        this.readExternal();

        vm.warp(block.timestamp + 2 hours);
        // price feed itself is now stale; refresh it to isolate the check
        priceFeed.updateAnswer(180_00000000);
        assertEq(_read(), 180 ether);
    }

    function test_MarketHoursWeekdayOpen() public {
        feed.checkMarketHours = true;
        // Monday 2026-01-05 14:00 UTC
        vm.warp(1_767_621_600);
        priceFeed.updateAnswer(180_00000000);
        assertEq(_read(), 180 ether);
    }

    function test_MarketHoursWeekendRejected() public {
        feed.checkMarketHours = true;
        // Saturday 2026-01-10 14:00 UTC
        vm.warp(1_768_053_600);
        priceFeed.updateAnswer(180_00000000);
        vm.expectRevert(abi.encodeWithSelector(Errors.MarketClosed.selector, 6, 14 hours));
        this.readExternal();
    }

    function test_MarketHoursOutsideWindowRejected() public {
        feed.checkMarketHours = true;
        // Monday 2026-01-05 21:00 UTC
        vm.warp(1_767_646_800);
        priceFeed.updateAnswer(180_00000000);
        vm.expectRevert(abi.encodeWithSelector(Errors.MarketClosed.selector, 1, 21 hours));
        this.readExternal();
    }

    function test_DecimalsConversion() public {
        MockFeed six = new MockFeed(6, 180_000000);
        feed.aggregator = AggregatorV3Interface(address(six));
        assertEq(_read(), 180 ether);
    }

    function test_RejectsTooManyDecimals() public {
        MockFeed weird = new MockFeed(20, 180);
        feed.aggregator = AggregatorV3Interface(address(weird));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDecimals.selector, 20));
        this.readExternal();
    }
}
