// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EqueAccess} from "../../contracts/utils/EqueAccess.sol";

contract EqueAccessTest is Test {
    EqueAccess access;
    address admin = address(0xA1);
    address keeper = address(0xE11);
    address guardian = address(0x6a1);
    address stranger = address(0x005);

    function setUp() public {
        vm.prank(admin);
        access = new EqueAccess(admin);

        // Role getters are external calls that would consume a vm.prank, so
        // read them once before setting senders.
        bytes32 keeperRole = access.KEEPER_ROLE();
        bytes32 guardianRole = access.GUARDIAN_ROLE();

        vm.prank(admin);
        access.grantRole(keeperRole, keeper);
        vm.prank(admin);
        access.grantRole(guardianRole, guardian);
    }

    function test_AdminIsDeployer() public view {
        assertTrue(access.hasRole(access.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(access.hasRole(access.DEFAULT_ADMIN_ROLE(), stranger));
    }

    function test_RolesGranted() public view {
        assertTrue(access.hasRole(access.KEEPER_ROLE(), keeper));
        assertTrue(access.hasRole(access.GUARDIAN_ROLE(), guardian));
        assertFalse(access.hasRole(access.CURATOR_ROLE(), stranger));
    }

    function test_ZeroAddressAdminRejected() public {
        vm.expectRevert();
        new EqueAccess(address(0));
    }

    function test_OnlyAdminCanGrant() public {
        bytes32 curatorRole = access.CURATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert();
        access.grantRole(curatorRole, stranger);
    }

    function test_AdminCanRevoke() public {
        bytes32 keeperRole = access.KEEPER_ROLE();
        vm.prank(admin);
        access.revokeRole(keeperRole, keeper);
        assertFalse(access.hasRole(access.KEEPER_ROLE(), keeper));
    }

    function test_RoleConstantsUnique() public view {
        assertTrue(access.KEEPER_ROLE() != access.CURATOR_ROLE());
        assertTrue(access.GUARDIAN_ROLE() != access.KEEPER_ROLE());
        assertTrue(access.GUARDIAN_ROLE() != access.CURATOR_ROLE());
    }
}
