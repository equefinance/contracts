// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Epoch covered-call engine: state machine, auction, and
/// settlement. Events here are the live auction feed the spectator page reads.
interface IEpochStrategy {
    enum State {
        None,
        Auction,
        Locked,
        Settled
    }

    struct Epoch {
        uint128 id;
        uint128 notional;
        uint64 start;
        uint64 auctionEnd;
        uint64 expiry;
        uint96 strike;
        uint96 spot;
        address highBidder;
        uint96 highBid;
        uint256 extensionCount;
    }

    event EpochStarted(uint256 indexed epochId, uint256 notional, uint256 strike, uint256 spot, uint256 auctionEnd);
    event BidPlaced(uint256 indexed epochId, address indexed bidder, uint256 amount);
    event AuctionExtended(uint256 indexed epochId, uint256 newEnd);
    event AuctionClosed(uint256 indexed epochId, address indexed winner, uint256 premium);
    event EpochSettled(uint256 indexed epochId, uint256 spotAtExpiry, uint256 payoff, uint256 premium, uint256 kept);
    event EpochRolled(uint256 indexed epochId, uint256 notional);

    error NotVault();
    error StateMismatch(State expected, State actual);
    error AuctionNotOpen();
    error AuctionStillOpen(uint256 auctionEnd);
    error EpochNotExpired(uint256 expiry);
    error BidBelowFloor(uint256 floor, uint256 bid);
    error BidTooLow(uint256 minBid, uint256 bid);
    error PremiumAboveBound(uint256 cap, uint256 premium);
    error NothingBid();

    function vault() external view returns (address);

    function state() external view returns (State);

    function currentEpoch() external view returns (Epoch memory);

    /// The market-hours bypass is an explicit parameter, never silent.
    function startEpoch(bool bypassMarketHours) external;

    function bid(uint256 amount) external;

    function closeAuction() external;

    function settleEpoch() external;
}
