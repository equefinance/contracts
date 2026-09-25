// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EqueAccess} from "../utils/EqueAccess.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IEpochStrategy} from "../interfaces/IEpochStrategy.sol";
import {OracleGuard} from "../oracle/OracleGuard.sol";
import {EpochMath} from "../libraries/EpochMath.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice The covered-call engine. One strategy per vault runs a repeating
/// epoch: snapshot the oracle spot, auction one call on the vault's allocated
/// notional at a 105% strike, lock through expiry, then cash-settle the payoff
/// against the winning premium and roll. Bids are permissionless; the winner
/// pays the premium at settlement, netted against the payoff the vault owes,
/// so a winning bid never needs escrow. Collateral (the notional) never
/// leaves the strategy while an epoch runs.
contract EpochStrategy is EqueAccess, IStrategy, IEpochStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    address public vault;
    OracleGuard.Feed public feed;
    uint256 public floorBps;
    uint64 public epochDuration;
    uint64 public auctionWindow;
    uint64 public maxExtensions;

    IEpochStrategy.State private _state;
    uint256 private _lastSpot;

    uint256 internal _epochId;
    uint256 internal _notional;
    uint256 internal _start;
    uint256 internal _auctionEnd;
    uint256 internal _expiry;
    uint256 internal _strike;
    uint256 internal _spot;
    address internal _highBidder;
    uint256 internal _highBid;
    uint256 internal _extensionCount;

    uint256 private constant BPS = 10_000;

    error AlreadySet();

    constructor(
        address asset_,
        OracleGuard.Feed memory feed_,
        uint256 floorBps_,
        uint64 epochDuration_,
        uint64 auctionWindow_,
        address admin
    ) EqueAccess(admin) {
        if (asset_ == address(0)) revert Errors.ZeroAddress();
        if (floorBps_ == 0 || floorBps_ > 10_000) revert Errors.InvalidConfig();
        if (epochDuration_ == 0 || auctionWindow_ == 0 || auctionWindow_ >= epochDuration_) {
            revert Errors.InvalidDuration();
        }
        assetToken = IERC20(asset_);
        feed = feed_;
        floorBps = floorBps_;
        epochDuration = epochDuration_;
        auctionWindow = auctionWindow_;
        maxExtensions = 10;
        _state = IEpochStrategy.State.None;
    }

    // --- Views ---

    function state() external view returns (IEpochStrategy.State) {
        return _state;
    }

    function currentEpochId() external view returns (uint256) {
        return _epochId;
    }

    function currentEpoch() external view returns (IEpochStrategy.Epoch memory) {
        return
            IEpochStrategy.Epoch({
                id: uint128(_epochId),
                notional: uint128(_notional),
                start: uint64(_start),
                auctionEnd: uint64(_auctionEnd),
                expiry: uint64(_expiry),
                strike: uint96(_strike),
                spot: uint96(_spot),
                highBidder: _highBidder,
                highBid: uint96(_highBid),
                extensionCount: _extensionCount
            });
    }

    function epoch(uint256) external view returns (IEpochStrategy.Epoch memory) {
        // History is indexed offchain from events; the chain serves the
        // current epoch only.
        return this.currentEpoch();
    }

    function claimablePremium() external view returns (uint256) {
        if (_state == IEpochStrategy.State.Locked) return _highBid;
        return 0;
    }

    // --- IStrategy ---

    function totalAssets() external view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    /// Liquid means withdrawable now: everything except the locked notional
    /// of a running epoch.
    function liquidAssets() public view returns (uint256) {
        uint256 balance = assetToken.balanceOf(address(this));
        if (_state == IEpochStrategy.State.Locked) {
            return balance - _notional;
        }
        return balance;
    }

    function allocate(uint256) external view {
        if (msg.sender != vault && !hasRole(KEEPER_ROLE, msg.sender)) revert Errors.NotVault();
        // The vault transfers the tokens itself; allocation is refused while
        // an epoch runs so the notional can never shift mid-auction.
        if (_state == IEpochStrategy.State.Auction || _state == IEpochStrategy.State.Locked) {
            revert IEpochStrategy.AuctionNotOpen();
        }
    }

    function withdraw(uint256 assets) external returns (uint256) {
        if (msg.sender != vault && !hasRole(KEEPER_ROLE, msg.sender)) revert Errors.NotVault();
        uint256 liquid = liquidAssets();
        uint256 take = assets > liquid ? liquid : assets;
        assetToken.safeTransfer(msg.sender, take);
        return take;
    }

    /// Premium compounds into totalAssets at settlement; harvest is a no-op
    /// so the router's uniform call surface stays intact.
    function harvest() external {}

    // --- Epoch lifecycle ---

    function startEpoch(bool bypassMarketHours) external onlyKeeper {
        IEpochStrategy.State s = _state;
        if (s != IEpochStrategy.State.None && s != IEpochStrategy.State.Settled) {
            revert IEpochStrategy.StateMismatch(IEpochStrategy.State.Settled, s);
        }
        uint256 notional = assetToken.balanceOf(address(this));
        if (notional == 0) revert IEpochStrategy.NothingBid();

        // Guarded read for the strike; deviation anchors to the previous
        // epoch's spot so a manipulated jump fails the check. The market-hours
        // check is the feed's own, so the bypass runs the read against a
        // copy with the hours gate lifted: refusing off-hours is the default
        // and the bypass is an explicit, keeper-signed choice, never silent.
        OracleGuard.Feed memory readFeed = feed;
        if (bypassMarketHours) readFeed.checkMarketHours = false;
        uint256 spot = OracleGuard.read(readFeed, _lastSpot).price;
        uint256 strike = EpochMath.strike(spot, EpochMath.STRIKE_BPS);

        _epochId += 1;
        _notional = notional;
        _start = block.timestamp;
        _auctionEnd = block.timestamp + auctionWindow;
        _expiry = block.timestamp + epochDuration;
        _strike = strike;
        _spot = spot;
        _highBidder = address(0);
        _highBid = 0;
        _extensionCount = 0;
        _lastSpot = spot;
        _state = IEpochStrategy.State.Auction;

        emit EpochStarted(_epochId, notional, strike, spot, _auctionEnd);
    }

    function bid(uint256 amount) external {
        if (_state != IEpochStrategy.State.Auction) revert IEpochStrategy.AuctionNotOpen();
        if (block.timestamp >= _auctionEnd) revert IEpochStrategy.AuctionStillOpen(_auctionEnd);
        if (amount == 0) revert IEpochStrategy.NothingBid();

        uint256 floor = EpochMath.reserveFloor(_notional, floorBps);
        if (amount < floor) revert IEpochStrategy.BidBelowFloor(floor, amount);
        if (_highBid > 0) {
            uint256 minNext = EpochMath.nextBidFloor(_highBid);
            if (amount < minNext) revert IEpochStrategy.BidTooLow(minNext, amount);
        }

        _highBidder = msg.sender;
        _highBid = amount;

        if (EpochMath.bidInSnipeZone(_auctionEnd, block.timestamp, auctionWindow) && _extensionCount < maxExtensions) {
            _auctionEnd += EpochMath.snipeExtension(auctionWindow);
            _extensionCount += 1;
            emit AuctionExtended(_epochId, _auctionEnd);
        }

        emit BidPlaced(_epochId, msg.sender, amount);
    }

    function closeAuction() external onlyKeeper {
        if (_state != IEpochStrategy.State.Auction) revert IEpochStrategy.AuctionNotOpen();
        if (block.timestamp < _auctionEnd) revert IEpochStrategy.AuctionStillOpen(_auctionEnd);
        _state = IEpochStrategy.State.Locked;
        emit AuctionClosed(_epochId, _highBidder, _highBid);
    }

    function settleEpoch() external onlyKeeper {
        if (_state != IEpochStrategy.State.Locked) {
            revert IEpochStrategy.StateMismatch(IEpochStrategy.State.Locked, _state);
        }
        if (block.timestamp < _expiry) revert IEpochStrategy.EpochNotExpired(_expiry);

        uint256 spotAtExpiry = OracleGuard.read(feed, _lastSpot).price;
        uint256 payoff = EpochMath.payoff(_notional, spotAtExpiry, _strike);

        if (_highBidder != address(0)) {
            // Winner pays the premium; if the call finished in the money the
            // payoff flows back, netted in two transfers at settle.
            assetToken.safeTransferFrom(_highBidder, address(this), _highBid);
            if (payoff > 0) {
                assetToken.safeTransfer(_highBidder, payoff);
            }
        }

        uint256 kept = EpochMath.settle(_notional, spotAtExpiry, _strike, _highBid);
        _lastSpot = spotAtExpiry;
        _state = IEpochStrategy.State.Settled;

        emit EpochSettled(_epochId, spotAtExpiry, payoff, _highBid, kept);
    }

    // --- Keeper-config ---

    /// One-time vault wiring; the factory deploys strategies before the
    /// vault clone exists, then calls this in the same transaction.
    function setVault(address vault_) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert Errors.Unauthorized();
        if (vault != address(0) || vault_ == address(0)) revert AlreadySet();
        vault = vault_;
    }

    function setFloorBps(uint256 bps) external onlyCurator {
        if (bps == 0 || bps > 10_000) revert Errors.InvalidConfig();
        floorBps = bps;
    }

    function nextEpochBoundaryView() external view returns (uint256) {
        if (_state == IEpochStrategy.State.Auction) return _auctionEnd;
        if (_state == IEpochStrategy.State.Locked) return _expiry;
        return 0;
    }
}
