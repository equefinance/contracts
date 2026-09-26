import { network } from "hardhat";
import { deployMain } from "./deploy.ts";
import type { Deployed } from "./deploy.ts";

/**
 * Deploys the full stack and immediately proves the wiring with one
 * complete epoch: deposit, allocate, auction, lock, settle, redeem, with
 * the premium visible in the depositor's final balance. Runs on the local
 * network (and the Tenderly fork); on testnets the runbook drives the same
 * steps by hand.
 *
 * npx hardhat run --network hardhatMainnet scripts/deploy-and-smoke.ts
 */

// One connection for the whole run: deploy writes to it and the smoke test
// reads the same chain.
const connection = await network.create();
const { viem, networkHelpers } = connection;
const publicClient = await viem.getPublicClient();
const [deployer] = await viem.getWalletClients();

const artifact: Deployed = await deployMain(connection);

const vaultSymbol = Object.keys(artifact.vaults)[0]!;
const vault = await viem.getContractAt("EqueVault", artifact.vaults[vaultSymbol]!);
const epochStrategy = await viem.getContractAt("EpochStrategy", artifact.strategies[`${vaultSymbol}-epoch`]!);
const token = await viem.getContractAt("MockB20", artifact.tokens[Object.keys(artifact.tokens)[0]!]!);

console.log(`\nSmoke test on ${vaultSymbol}`);

// 1. Fund the depositor and deposit.
const depositor = deployer.account.address;
await token.write.mint([depositor, 10n * 10n ** 18n]);
await token.write.approve([vault.address, 10n * 10n ** 18n]);
await vault.write.deposit([10n * 10n ** 18n, depositor]);
console.log("deposit: 10 tokens ->", (await vault.read.balanceOf([depositor])).toString(), "shares");

// 2. Allocate into strategies.
await vault.write.allocate();
console.log("allocate: epoch strategy holds", (await epochStrategy.read.totalAssets()).toString());

// 3. Full epoch: start, bid the floor, close, settle.
await epochStrategy.write.startEpoch([true]);
const notional = await epochStrategy.read.totalAssets();
const floor = (notional * 120n) / 10_000n + 1n;
await token.write.approve([epochStrategy.address, floor]);
await epochStrategy.write.bid([floor]);
console.log("bid:", floor.toString());

const epoch = await epochStrategy.read.currentEpoch();
await networkHelpers.time.increaseTo(BigInt(epoch.auctionEnd) + 1n);
await epochStrategy.write.closeAuction();
console.log("auction closed");

await networkHelpers.time.increaseTo(BigInt(epoch.expiry) + 1n);
await epochStrategy.write.settleEpoch();
console.log("settled: strategy holds", (await epochStrategy.read.totalAssets()).toString());

// 4. Redeem through the two-step queue.
const bal = await vault.read.balanceOf([depositor]);
await vault.write.requestRedeem([bal]);
const readyAt = await vault.read.redeemReadyAt([depositor]);
// A settled epoch reports no future boundary, so the claim is immediate.
if (readyAt > 0) {
  await networkHelpers.time.increaseTo(BigInt(readyAt) + 1n);
}
await vault.write.claim();
console.log("redeemed; vault totalAssets", (await vault.read.totalAssets()).toString());

// The depositor must exit with more than they put in: the premium compounded.
const tokenBack = await token.read.balanceOf([depositor]);
if (tokenBack <= 10n * 10n ** 18n) {
  throw new Error(`smoke failed: depositor ended with ${tokenBack}`);
}
console.log("\nSMOKE OK: deposit -> bid -> settle -> premium compounded -> withdraw");
