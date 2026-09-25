// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IEqueVault} from "../interfaces/IEqueVault.sol";
import {IEqueRouter} from "../interfaces/IEqueRouter.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Single-underlying ERC-4626 vault for one tokenized stock. Written
/// directly over ERC-20 rather than on OZ's ERC4626 so the asset can be
/// supplied through initialize: the minimal-proxy deployment used by the
/// factory cannot carry constructor arguments. All ERC-4626 accounting
/// (conversion rounding, max*/preview* consistency) follows the EIP as
/// implemented by OpenZeppelin.
///
/// The vault is the sole custodian. Deposits rest in the pendingBuffer until
/// the router allocates them at an epoch boundary. Withdrawals are two-step:
/// requestRedeem escrows shares into vault custody (supply unchanged, so the
/// share price stays monotonic) and claim pays out once the epoch that may
/// have locked the underlying collateral has settled.
contract EqueVault is IERC20, IERC4626, IEqueVault, ERC20, AccessControl, Pausable, Initializable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    IERC20 internal _underlying;
    IEqueRouter public router_;
    uint256 public cap;

    address public feeRecipient;
    uint16 public depositFeeBps;
    uint16 public withdrawFeeBps;

    mapping(address owner => uint256 pending) public redeemPending;
    mapping(address owner => uint256 readyAt) public redeemReadyAt;

    // Assets controlled by the vault: its own token balance plus whatever the
    // router has parked in strategies. Maintained on every deposit, withdraw,
    // and allocation so share pricing never re-derives from balances.
    uint256 internal _assets;

    error NothingClaimable();
    error NotRouter();
    error FeesTooHigh(uint16 max);
    error UnsupportedDirectWithdraw();

    // ERC20 keeps its own name/symbol storage private and uninitializable
    // through a clone, so the vault carries its own.
    string private _vaultName;
    string private _vaultSymbol;

    event FeeRecipientSet(address indexed recipient);
    event FeesSet(uint16 depositBps, uint16 withdrawBps);

    uint16 internal constant MAX_FEE_BPS = 2_000;

    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return _vaultName;
    }

    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return _vaultSymbol;
    }

    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    constructor() ERC20("", "") {
        _disableInitializers();
    }

    function initialize(
        IERC20 underlying,
        string calldata name_,
        string calldata symbol_,
        address admin,
        address routerAddress,
        uint256 cap_,
        address feeRecipient_,
        uint16 depositFeeBps_,
        uint16 withdrawFeeBps_
    ) external initializer {
        if (address(underlying) == address(0) || admin == address(0) || routerAddress == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (depositFeeBps_ > MAX_FEE_BPS || withdrawFeeBps_ > MAX_FEE_BPS) {
            revert FeesTooHigh(MAX_FEE_BPS);
        }
        _underlying = underlying;
        _vaultName = name_;
        _vaultSymbol = symbol_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CURATOR_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        router_ = IEqueRouter(routerAddress);
        cap = cap_;
        feeRecipient = feeRecipient_;
        depositFeeBps = depositFeeBps_;
        withdrawFeeBps = withdrawFeeBps_;
    }

    // --- ERC-4626 view surface ---

    function asset() public view override returns (address) {
        return address(_underlying);
    }

    /// Decimals are fixed at 18 regardless of the underlying so share pricing
    /// stays consistent across stock tokens on both chains.
    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 18;
    }

    function totalAssets() public view override returns (uint256) {
        return _assets;
    }

    /// Buffer plus whatever strategies hold that is not epoch-locked.
    function freeAssets() public view returns (uint256) {
        (address[] memory strategies, uint256[] memory holdings) = router_.strategyHoldings(address(this));
        uint256 unlocked;
        for (uint256 i; i < strategies.length; i++) {
            unlocked += holdings[i];
        }
        return _underlying.balanceOf(address(this)) + unlocked - locked();
    }

    function lockedAssets() public view returns (uint256) {
        return locked();
    }

    function locked() internal view returns (uint256) {
        return router_.strategyLocked(address(this));
    }

    // --- ERC-4626 accounting (EIP-4626 rounding, mirrors OpenZeppelin) ---

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalSupply() + 1, _assets + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(_assets + 1, totalSupply() + 1, rounding);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function maxDeposit(address) public view returns (uint256) {
        return cap == 0 ? type(uint256).max : cap - _assets;
    }

    /// Mint is expressed in shares; the asset-side cap is converted so a
    /// deposit that fits also implies the equivalent mint fits.
    function maxMint(address receiver) public view returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// Shares that are spendable: everything except escrowed pending redemptions.
    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(maxRedeem(owner), Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    // --- Entry and exit ---

    function deposit(uint256 assets, address receiver) public whenNotPaused returns (uint256) {
        uint256 max = maxDeposit(receiver);
        if (assets > max) revert Errors.VaultCapExceeded(cap, assets);
        if (assets == 0) revert Errors.ZeroAmount();

        uint256 fee = Math.mulDiv(assets, depositFeeBps, 10_000);
        uint256 netAssets = assets - fee;
        _underlying.safeTransferFrom(msg.sender, address(this), assets);
        if (fee > 0 && feeRecipient != address(0)) {
            _underlying.safeTransfer(feeRecipient, fee);
        }

        uint256 shares = netAssets.mulDiv(totalSupply() + 1, _assets + 1, Math.Rounding.Floor);
        _assets += netAssets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public whenNotPaused returns (uint256) {
        if (shares == 0) revert Errors.ZeroAmount();
        uint256 assets = shares.mulDiv(_assets + 1, totalSupply() + 1, Math.Rounding.Ceil);
        uint256 max = maxMint(receiver);
        if (assets > max) revert Errors.VaultCapExceeded(cap, assets);

        uint256 fee = Math.mulDiv(assets, depositFeeBps, 10_000);
        uint256 netAssets = assets - fee;
        _underlying.safeTransferFrom(msg.sender, address(this), assets);
        if (fee > 0 && feeRecipient != address(0)) {
            _underlying.safeTransfer(feeRecipient, fee);
        }

        _assets += netAssets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256, address, address) public pure returns (uint256) {
        revert UnsupportedDirectWithdraw();
    }

    function redeem(uint256, address, address) public pure returns (uint256) {
        revert UnsupportedDirectWithdraw();
    }

    // --- Two-step redeem ---

    function requestRedeem(uint256 shares) external whenNotPaused {
        if (shares == 0) revert Errors.ZeroAmount();
        if (redeemPending[msg.sender] > 0) revert Errors.RedeemRequestPending();

        _transfer(msg.sender, address(this), shares);
        redeemPending[msg.sender] = shares;
        redeemReadyAt[msg.sender] = _nextReadyAt();
        emit RedeemRequested(msg.sender, shares, previewRedeem(shares), redeemReadyAt[msg.sender]);
    }

    function claim() external returns (uint256 assets) {
        uint256 pending = redeemPending[msg.sender];
        if (pending == 0) revert Errors.NoRedeemRequest();
        if (block.timestamp < redeemReadyAt[msg.sender]) revert Errors.RedeemNotReady(redeemReadyAt[msg.sender]);

        redeemPending[msg.sender] = 0;
        assets = previewRedeem(pending);
        if (assets > freeAssets()) revert Errors.EpochLockedForWithdraw();

        _assets -= assets;
        _burn(address(this), pending);

        uint256 fee = Math.mulDiv(assets, withdrawFeeBps, 10_000);
        uint256 net = assets - fee;
        if (fee > 0 && feeRecipient != address(0)) {
            _underlying.safeTransfer(feeRecipient, fee);
        }
        _underlying.safeTransfer(msg.sender, net);

        emit RedeemClaimed(msg.sender, net);
    }

    function _nextReadyAt() internal view returns (uint256) {
        return router_.nextEpochBoundary(address(this));
    }

    // --- Router plumbing ---

    function allocate() external whenNotPaused {
        if (msg.sender != address(router_) && !hasRole(KEEPER_ROLE, msg.sender)) revert Errors.NotKeeper();
        (address[] memory strategies, uint256[] memory amounts) = router_.planAllocation(address(this));
        uint256 buffer = _underlying.balanceOf(address(this));
        for (uint256 i; i < strategies.length; i++) {
            if (amounts[i] > buffer) revert Errors.NothingToWithdraw();
            _underlying.safeTransfer(strategies[i], amounts[i]);
            IStrategy(strategies[i]).allocate(amounts[i]);
            buffer -= amounts[i];
        }
        emit Allocated(_assets - buffer);
    }

    /// Router reports settled epoch results: strategy balances grew or shrank
    /// and the vault's books must follow.
    function syncAssets(int256 delta) external {
        if (msg.sender != address(router_)) revert NotRouter();
        if (delta >= 0) {
            _assets += uint256(delta);
        } else {
            _assets -= uint256(-delta);
        }
    }

    function setCap(uint256 cap_) external onlyCurator {
        cap = cap_;
        emit CapSet(cap_);
    }

    function setFees(uint16 depositFeeBps_, uint16 withdrawFeeBps_) external onlyCurator {
        if (depositFeeBps_ > MAX_FEE_BPS || withdrawFeeBps_ > MAX_FEE_BPS) revert FeesTooHigh(MAX_FEE_BPS);
        depositFeeBps = depositFeeBps_;
        withdrawFeeBps = withdrawFeeBps_;
        emit FeesSet(depositFeeBps_, withdrawFeeBps_);
    }

    function setFeeRecipient(address recipient) external onlyCurator {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyCurator {
        _unpause();
    }

    function router() external view returns (address) {
        return address(router_);
    }

    modifier onlyCurator() {
        if (!hasRole(CURATOR_ROLE, msg.sender)) revert Errors.NotCurator();
        _;
    }

    modifier onlyGuardian() {
        if (!hasRole(GUARDIAN_ROLE, msg.sender)) revert Errors.NotGuardian();
        _;
    }
}
