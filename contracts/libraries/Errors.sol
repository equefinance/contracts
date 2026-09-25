// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Custom errors shared across Eque contracts. Declared in one library
/// so revert data stays identical no matter which contract throws.
library Errors {
    error ZeroAddress();
    error ZeroAmount();
    error NotVault();
    error NotRouter();
    error NotStrategy();
    error NotKeeper();
    error NotCurator();
    error NotGuardian();
    error Unauthorized();
    error TransferFailed();
    error VaultPaused();
    error VaultCapExceeded(uint256 cap, uint256 requested);
    error StrategyCapExceeded(uint256 capBps, uint256 requestedBps);
    error AlreadyAllocated();
    error NothingToWithdraw();
    error BadWeights(uint256 totalBps);
    error RebalanceAwayFromTarget();
    error HysteresisLocked(uint256 currentBps, uint256 targetBps);
    error UnknownStrategy();
    error EpochNotOpen();
    error EpochNotLocked();
    error EpochNotSettleable();
    error EpochAlreadySettled();
    error EpochLockedForWithdraw();
    error BidTooLow(uint256 floor, uint256 bid);
    error BidNotHigher(uint256 currentHigh, uint256 bid);
    error AuctionNotClosed();
    error OracleUnavailable();
    error OracleStale(uint256 updatedAt, uint256 deadline);
    error OracleDeviated(uint256 price, uint256 prevPrice);
    error OraclePaused();
    error SequencerDown();
    error MarketClosed(uint256 dayOfWeek, uint256 hourUtc);
    error InvalidConfig();
    error InvalidDecimals(uint8 decimals);
    error InvalidDuration();
    error InvalidStrike();
    error FeeHookMisconfigured();
    error RedeemRequestPending();
    error NoRedeemRequest();
    error RequestTooFresh(uint256 readyAt);
}
