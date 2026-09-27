# Eque Protocol contracts

Solidity contracts for the Eque Protocol.
Each vault wraps one underlying stock token as an ERC-4626 vault and runs a repeating covered-call cycle: deposits sit
in a free buffer, a keeper starts an epoch that allocates the notional to a
covered-call strategy and auctions it off in an ascending English auction, and
at expiry the vault settles the payoff and credits the winning premium to
shareholders.

A deterministic onchain router moves funds between the epoch
strategy and a lending strategy toward curator-set target weights.

## Eque Demo workflow

```md
== smoke test evNVDA on robinhood testnet ==
vault:    0xd86e58E4F80bb0F83432EAf309F02332EeB80AF6
strategy: 0xbf2332f1610671f9b9082430ab3cab6ad84fc153
keeper:   0x00000AC095ab728FeeBef880A3D4801f71732808
feed fresh (19545s old)
faucet: 0x00000AC095ab728FeeBef880A3D4801f71732808 already claimed, skipping (cooldown until 1790490141)
faucet: 0xf30aA18252c3c56339b08Aeb30A884F13CfcF204 already claimed, skipping (cooldown until 1790490145)
faucet: 0xa11361a68f63d79711a43CcC272b36F34C01620C claimed 10 NVDA
deposit: 10 NVDA -> 10000000000000000000 shares (depositor started with 1000010.000000000000000000)
allocate: strategy holds 7000000000000000000
epoch started (state=Auction)
bot1 bid 0.1
bot2 outbid 0.15 (bot1 auto-refunded)
waiting 330s for auction to end...
auction closed (state=Locked)
waiting 330s for epoch expiry...
settled (state=Settled), strategy holds 7150000000000000000
depositor: 1000010.000000000000000000 -> 1000010.149999999999999999 NVDA

```

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
