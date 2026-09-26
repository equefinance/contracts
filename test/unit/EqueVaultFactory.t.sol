// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EqueVaultFactory} from "../../contracts/core/EqueVaultFactory.sol";
import {MockB20} from "../../contracts/mocks/MockB20.sol";
import {Errors} from "../../contracts/libraries/Errors.sol";

/// deployVault registers strategies on the shared router, so it must be
/// restricted to the admin that deployed the factory; anyone else could
/// otherwise point vaults at arbitrary strategy addresses.
contract EqueVaultFactoryTest is Test {
    EqueVaultFactory factory;
    MockB20 token;

    address admin = address(0xF01);
    address stranger = address(0xF02);

    function setUp() public {
        factory = new EqueVaultFactory(admin);
        token = new MockB20("Test Stock", "TST", admin);
    }

    function _spec() internal view returns (EqueVaultFactory.VaultSpec memory) {
        return EqueVaultFactory.VaultSpec({
            underlying: token,
            name: "Eque TST",
            symbol: "eTST",
            cap: 1_000 ether,
            feeRecipient: address(0),
            depositFeeBps: 0,
            withdrawFeeBps: 0,
            epochStrategy: address(0x1001),
            lendingStrategy: address(0x1002),
            epochCapBps: 9_000,
            lendingCapBps: 5_000,
            epochWeightBps: 7_000,
            lendingWeightBps: 3_000
        });
    }

    function test_DeployVaultRejectsNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.Unauthorized.selector));
        factory.deployVault(_spec());
        assertEq(factory.vaultCount(), 0);
    }

    function test_AdminDeploysVault() public {
        vm.prank(admin);
        address vault = factory.deployVault(_spec());
        assertTrue(vault != address(0));
        assertEq(factory.vaultCount(), 1);
        assertTrue(address(factory.vaultImplementation()) != address(0));
    }

    function test_ImplementationCannotBeInitialized() public {
        // The implementation disables its initializer in the constructor, so
        // it can never be initialized directly and can never hold funds.
        (bool ok, ) = address(factory.vaultImplementation()).call(
            abi.encodeWithSignature(
                "initialize(address,string,string,address,address,uint256,address,uint16,uint16)",
                address(token),
                "x",
                "x",
                admin,
                address(0x1),
                0,
                address(0),
                0,
                0
            )
        );
        assertFalse(ok);
    }
}