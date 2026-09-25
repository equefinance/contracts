# Eque Protocol contracts

Solidity contracts for the Eque Protocol. Each vault wraps one underlying stock
token as an ERC-4626 vault and runs a repeating covered-call cycle: deposits sit
in a free buffer, a keeper starts an epoch that allocates the notional to a
covered-call strategy and auctions it off in an ascending English auction, and
at expiry the vault settles the payoff and credits the winning premium to
shareholders. A deterministic onchain router moves funds between the epoch
strategy and a lending strategy toward curator-set target weights. Mock tokens,
mock price feeds, and a faucet make both testnets self-contained.

## Install

```
npm install
```

## Compile

```
npx hardhat build
```

## Test

```
npx hardhat test
```

`npx hardhat test solidity` runs only the Solidity tests,
`npx hardhat test nodejs` only the TypeScript ones.

## Environment variables

Copy `.env.example` to `.env` and fill in real values. The checked-in file
contains placeholders only.

| Variable | Purpose |
|---|---|
| `ROBINHOOD_TESTNET_RPC` | JSON-RPC endpoint for the Robinhood testnet |
| `BASE_SEPOLIA_RPC` | JSON-RPC endpoint for Base Sepolia |
| `TENDERLY_FORK_RPC` | JSON-RPC endpoint for a Tenderly virtual testnet fork |
| `DEPLOYER_PRIVATE_KEY` | Private key signing deploys and keeper transactions |
| `KEEPER_ADDRESS` | Address of the keeper bot that starts, closes, and settles epochs |
| `BASESCAN_API_KEY` | Block explorer API key for verifying contracts on Base Sepolia |
| `ROBINHOOD_EXPLORER_API_KEY` | Block explorer API key for verifying contracts on the Robinhood testnet |

## Scripts and configuration

Deployment scripts and their per-chain settings live in `scripts/`. Each chain
has a JSON config under `scripts/config/` (`robinhood-testnet.json`,
`base-sepolia.json`) listing the vaults, underlying tokens, oracle parameters,
caps, and strategy targets for that chain. Ignition modules live in
`ignition/modules/`.
