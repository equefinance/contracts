// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqueVault} from "../../contracts/core/EqueVault.sol";
import {EqueRouter} from "../../contracts/core/EqueRouter.sol";
import {EqueVaultFactory} from "../../contracts/core/EqueVaultFactory.sol";
import {MockB20} from "../../contracts/mocks/MockB20.sol";

/// A lending stub that accrues a fixed 2% APY-style yield linearly per second
/// so router and vault tests can watch allocations without a fork. The vault
/// is set once after the vault exists, because the vault is deployed through
/// the factory after its strategies.
contract StubLendingStrategy is ERC20 {
    address public asset;
    address public vault;
    address public router;
    uint256 public principal;
    uint256 public depositedAt;

    error OnlyVault();
    error AlreadySet();

    constructor(address asset_) ERC20("stub", "STUB") {
        asset = asset_;
    }

    function setVault(address vault_, address router_) external {
        if (vault != address(0)) revert AlreadySet();
        vault = vault_;
        router = router_;
    }

    function totalAssets() external view returns (uint256) {
        if (principal == 0) return 0;
        return principal + (principal * 2 * (block.timestamp - depositedAt)) / 100 / 365 days;
    }

    function allocate(uint256 amount) external {
        if (msg.sender != vault && msg.sender != router) revert OnlyVault();
        if (principal == 0) depositedAt = block.timestamp;
        principal += amount;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        if (msg.sender != vault && msg.sender != router) revert OnlyVault();
        uint256 bal = principal;
        if (amount > bal) amount = bal;
        principal -= amount;
        ERC20(asset).transfer(msg.sender, amount);
        return amount;
    }

    function harvest() external {}
}

/// An epoch stub that locks its whole notional between start and settle, so
/// the vault's free/locked split and the router's locked-constraint are
/// exercised without the full auction machinery.
contract StubEpochStrategy is ERC20 {
    address public asset;
    address public vault;
    address public router;
    uint256 public notional;
    bool public locked;

    error OnlyVault();
    error AlreadySet();
    error Locked();

    constructor(address asset_) ERC20("stub", "STUB") {
        asset = asset_;
    }

    function setVault(address vault_, address router_) external {
        if (vault != address(0)) revert AlreadySet();
        vault = vault_;
        router = router_;
    }

    function totalAssets() external view returns (uint256) {
        return notional;
    }

    function allocate(uint256 amount) external {
        if (msg.sender != vault && msg.sender != router) revert OnlyVault();
        notional += amount;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        if (msg.sender != vault && msg.sender != router) revert OnlyVault();
        if (locked) revert Locked();
        uint256 take = amount > notional ? notional : amount;
        notional -= take;
        ERC20(asset).transfer(msg.sender, take);
        return take;
    }

    function start() external {
        locked = true;
    }

    function settle() external {
        locked = false;
    }

    function harvest() external {}

    // Router-facing epoch surface (the real machine comes in 1.4).
    uint64 public boundary;

    function setBoundary(uint64 ts) external {
        boundary = ts;
    }

    function state() external view returns (uint8) {
        return locked ? 2 : 0;
    }

    function currentEpoch()
        external
        view
        returns (uint128, uint128, uint64, uint64, uint64, uint96, uint96, address, uint96, uint256)
    {
        return (0, 0, 0, boundary, boundary, 0, 0, address(0), 0, 0);
    }
}

contract CoreFixture is Test {
    EqueVault internal vault;
    EqueRouter internal router;
    MockB20 internal token;
    StubEpochStrategy internal epochStrategy;
    StubLendingStrategy internal lendingStrategy;

    address internal curator = address(0xC01);
    address internal keeper = address(0xC02);
    address internal guardian = address(0xC03);
    address internal admin = address(0xC04);
    address internal depositor = address(0xC05);
    address internal secondDepositor = address(0xC06);

    uint256 internal constant CAP = 10_000 ether;

    function setUpCore() internal {
        token = new MockB20("Test Tokenized Stock", "TST", admin);
        vm.prank(admin);
        token.transfer(depositor, 10_000 ether);
        vm.prank(admin);
        token.transfer(secondDepositor, 10_000 ether);

        // Strategies before the vault so the factory can wire everything in
        // one transaction; they learn the vault address right after.
        epochStrategy = new StubEpochStrategy(address(token));
        lendingStrategy = new StubLendingStrategy(address(token));

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
        // deployVault is admin-gated since the router is shared.
        vm.prank(admin);
        vault = EqueVault(factory.deployVault(spec));
        router = factory.router();

        epochStrategy.setVault(address(vault), address(router));
        lendingStrategy.setVault(address(vault), address(router));

        // Role getters are external calls that would consume a vm.prank.
        bytes32 keeperRole = vault.KEEPER_ROLE();
        bytes32 guardianRole = vault.GUARDIAN_ROLE();
        bytes32 curatorRole = vault.CURATOR_ROLE();
        vm.prank(admin);
        vault.grantRole(keeperRole, keeper);
        vm.prank(admin);
        vault.grantRole(guardianRole, guardian);
        vm.prank(admin);
        vault.grantRole(curatorRole, curator);
        bytes32 routerCuratorRole = router.CURATOR_ROLE();
        bytes32 routerKeeperRole = router.KEEPER_ROLE();
        vm.prank(admin);
        router.grantRole(routerCuratorRole, curator);
        vm.prank(admin);
        router.grantRole(routerKeeperRole, keeper);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
    }
}
