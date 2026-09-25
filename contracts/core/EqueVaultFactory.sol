// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EqueVault} from "./EqueVault.sol";
import {EqueRouter} from "./EqueRouter.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Deploys the four per-underlying vault clones and wires
/// vault -> router -> strategies in one transaction, so there is no window
/// where a clone exists uninitialized. Chain configuration is supplied by the
/// deploy script; addresses are never hardcoded here.
contract EqueVaultFactory {
    using Clones for address;

    struct VaultSpec {
        IERC20 underlying;
        string name;
        string symbol;
        uint256 cap;
        address feeRecipient;
        uint16 depositFeeBps;
        uint16 withdrawFeeBps;
        // Registered strategies in order: epoch strategy first, lending second.
        address epochStrategy;
        address lendingStrategy;
        uint256 epochCapBps;
        uint256 lendingCapBps;
        uint256 epochWeightBps;
        uint256 lendingWeightBps;
    }

    event VaultDeployed(address indexed vault, address indexed underlying, address indexed router);
    event RouterDeployed(address indexed router);

    error EmptySpec();

    EqueVault public immutable vaultImplementation;
    address public immutable admin;
    EqueRouter public router;
    address[] public vaults;

    constructor(address admin_) {
        if (admin_ == address(0)) revert Errors.ZeroAddress();
        admin = admin_;
        // The implementation is deployed with disabled initializers so it can
        // never be initialized directly or hold funds.
        vaultImplementation = new EqueVault();
        router = new EqueRouter(admin_, address(this));
        emit RouterDeployed(address(router));
    }

    function deployVault(VaultSpec memory spec) external returns (address vault) {
        if (address(spec.underlying) == address(0) || spec.epochStrategy == address(0) || spec.lendingStrategy == address(0)) {
            revert Errors.ZeroAddress();
        }

        vault = address(vaultImplementation).clone();
        EqueVault(vault).initialize(
            spec.underlying,
            spec.name,
            spec.symbol,
            admin,
            address(router),
            spec.cap,
            spec.feeRecipient,
            spec.depositFeeBps,
            spec.withdrawFeeBps
        );

        router.registerStrategy(vault, spec.epochStrategy, spec.epochCapBps);
        router.registerStrategy(vault, spec.lendingStrategy, spec.lendingCapBps);
        router.setWeights(vault, spec.epochWeightBps, spec.lendingWeightBps);

        vaults.push(vault);
        emit VaultDeployed(vault, address(spec.underlying), address(router));
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }
}
