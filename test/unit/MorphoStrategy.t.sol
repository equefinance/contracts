// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MorphoStrategy, IMorpho} from "../../contracts/strategies/MorphoStrategy.sol";
import {MockB20} from "../../contracts/mocks/MockB20.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";

/// Minimal Morpho Blue stub: records markets and returns them for valuation
/// reads. The adapter's allocate path against a live market is exercised once
/// the push-style rework lands; these tests pin the surface that does not
/// depend on it.
contract MockMorpho is IMorpho {
    struct StoredMarket {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    mapping(bytes32 id => StoredMarket) internal _markets;

    function setMarket(bytes32 id, uint128 assets, uint128 shares) external {
        _markets[id] = StoredMarket(assets, shares, 0, 0, uint128(block.timestamp), 0);
    }

    function supply(MarketParams memory, uint256, uint256, address, bytes memory) external pure override returns (uint256, uint256) {
        revert("supply not used");
    }

    function withdraw(
        MarketParams memory,
        uint256,
        uint256,
        address,
        address
    ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function market(bytes32 id) external view override returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        StoredMarket memory m = _markets[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee);
    }

    function position(bytes32, address) external pure override returns (uint256, uint128, uint128) {
        return (0, 0, 0);
    }
}

contract MorphoStrategyTest is Test {
    MockB20 token;
    MockMorpho morpho;
    MorphoStrategy strategy;

    address admin = address(0xC10);
    address vault = address(0xC11);
    address keeper = address(0xC12);
    address stranger = address(0xC13);

    IMorpho.MarketParams params;

    function setUp() public {
        token = new MockB20("Test Loan Token", "TLT", admin);
        morpho = new MockMorpho();
        params = IMorpho.MarketParams({
            loanToken: address(token),
            collateralToken: address(0xC011),
            oracle: address(0x0AC0),
            irm: address(0x1B40),
            lltv: 0.6e18
        });
        strategy = new MorphoStrategy(address(morpho), params, vault, admin);
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        new MorphoStrategy(address(0), params, vault, admin);

        IMorpho.MarketParams memory emptyParams = params;
        emptyParams.loanToken = address(0);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        new MorphoStrategy(address(morpho), emptyParams, vault, admin);

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        new MorphoStrategy(address(morpho), params, address(0), admin);
    }

    function test_MarketIdMatchesPackedParams() public view {
        bytes32 expected = keccak256(abi.encode(params.loanToken, params.collateralToken, params.oracle, params.irm, params.lltv));
        assertEq(strategy.marketId(), expected);
        assertEq(strategy.lltv(), 0.6e18);
        assertEq(strategy.loanToken(), address(token));
    }

    function test_TotalAssetsZeroWithoutPosition() public view {
        assertEq(strategy.totalAssets(), 0);
    }

    function test_AllocateIsVaultOnly() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotVault.selector));
        strategy.allocate(1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotVault.selector));
        strategy.allocate(1 ether);
    }

    function test_WithdrawIsVaultOnly() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotVault.selector));
        strategy.withdraw(1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotVault.selector));
        strategy.withdraw(1 ether);
    }

    function test_WithdrawZeroReturnsZero() public {
        vm.prank(vault);
        assertEq(strategy.withdraw(0), 0);
    }

    function test_WithdrawWithNoPositionReturnsZero() public {
        vm.prank(vault);
        assertEq(strategy.withdraw(1 ether), 0);
    }

    function test_HarvestChangesNothing() public {
        strategy.harvest();
        assertEq(strategy.totalAssets(), 0);
    }
}