// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Shared role definitions for every Eque contract. DEFAULT_ADMIN_ROLE
/// is granted to the deployer and is the sole admin of the three roles, so
/// grant and revocation have one accountable owner. Parameter delays such as
/// curator timelocks live in the consuming contracts, not in access control.
contract EqueAccess is AccessControl {
    error NotCurator();
    error NotKeeper();
    error NotGuardian();

    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    constructor(address admin) {
        if (admin == address(0)) _revertZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    modifier onlyCurator() {
        if (!hasRole(CURATOR_ROLE, msg.sender)) revert NotCurator();
        _;
    }

    modifier onlyKeeper() {
        if (!hasRole(KEEPER_ROLE, msg.sender)) revert NotKeeper();
        _;
    }

    modifier onlyGuardian() {
        if (!hasRole(GUARDIAN_ROLE, msg.sender)) revert NotGuardian();
        _;
    }

    function _revertZeroAddress() private pure {
        assembly ("memory-safe") {
            mstore(0x00, 0x33578a6d00000000000000000000000000000000000000000000000000000000)
            revert(0x00, 0x04)
        }
    }
}
