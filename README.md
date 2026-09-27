# Eque Protocol contracts

Solidity contracts for the Eque Protocol.
Each vault wraps one underlying stock token as an ERC-4626 vault and runs a repeating covered-call cycle: deposits sit
in a free buffer, a keeper starts an epoch that allocates the notional to a
covered-call strategy and auctions it off in an ascending English auction, and
at expiry the vault settles the payoff and credits the winning premium to
shareholders.

A deterministic onchain router moves funds between the epoch
strategy and a lending strategy toward curator-set target weights.

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

## Deploy

Deployments are config-driven. `scripts/deploy.ts` reads
`scripts/config/<chain>.json`, deploys the oracle and token mocks, the vault
factory (which deploys the router and vault implementation and clones one vault
per configured stock), both strategies per vault, and the faucet; it wires the
keeper and curator roles; then it verifies every contract on Blockscout in the
same run. Deployment addresses will be recorded and stored in `deployments/<network>.json`.

Prove the whole flow locally first, this deploys the full stack and runs one
complete epoch (deposit, escrowed bid, settle, redeem) through it:

```
npx hardhat run --network hardhatMainnet scripts/deploy-and-smoke.ts
```

Then the real chains. `--build-profile production` matters: verification
compares deployed bytecode against that profile:

```
npx hardhat run --build-profile production --network base-sepolia scripts/deploy.ts
npx hardhat run --build-profile production --network robinhood-testnet scripts/deploy.ts
```

## Environment variables

Copy `.env.example` to `.env` and fill in real values.

| Variable | Purpose |
|---|---|
| `ROBINHOOD_TESTNET_RPC` | JSON-RPC endpoint for the Robinhood testnet |
| `BASE_SEPOLIA_RPC` | JSON-RPC endpoint for Base Sepolia |
| `FORK_RPC_URL` | (Optional) upstream chain for the local fork network |
| `TENDERLY_FORK_RPC` | (Optional) endpoint for a Tenderly virtual testnet fork |
| `DEPLOYER_PRIVATE_KEY` | Private key signing deploys and keeper transactions |
| `KEEPER_ADDRESS` | Address of the keeper bot that runs the epoch lifecycle |

No explorer API keys are needed: verification runs on Blockscout for both
chains, and those instances are keyless.

## Scripts and configuration

Deployment scripts and their per-chain settings live in `scripts/`. Each chain
has a JSON config under `scripts/config/` (`robinhood-testnet.json`,
`base-sepolia.json`) listing the vaults, underlying tokens, oracle parameters,
caps, and strategy targets for that chain. `scripts/deploy-and-smoke.ts` runs
the deploy and then one full epoch against it on a local network or a fork.
`ignition/modules/` is reserved for future Ignition modules.

## Eque testnet deployment addresses

- [Base Sepolia](https://github.com/equefinance/contracts/blob/main/deployments/base-sepolia.json)
- [Robinhood Testnet](https://github.com/equefinance/contracts/blob/main/deployments/robinhood-testnet.json)