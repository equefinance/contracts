import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { network } from "hardhat";
import { verifyContract } from "@nomicfoundation/hardhat-verify/verify";
import type { HardhatRuntimeEnvironment } from "hardhat/types/hre";
import hrePkg from "hardhat";

/**
 * Deploys the full Eque stack for one chain, driven entirely by the JSON
 * config in scripts/config/<network>.json. Order: oracle and token mocks,
 * strategies, the router + vault factory, one vault clone per configured
 * stock, the faucet, then role wiring. Every deployment is followed by an
 * explorer verification attempt with one retry; whatever still fails is
 * listed at the end so nothing is left silently unverified. Returns the
 * deployment artifact (also written to deployments/<network>.json).
 *
 * Local dry-run:
 *   npx hardhat run --network hardhatMainnet scripts/deploy.ts
 * Local deploy plus smoke test:
 *   npx hardhat run --network hardhatMainnet scripts/deploy-and-smoke.ts
 */

type VaultConfig = {
  symbol: string;
  shareTokenName: string;
  underlying: { symbol: string; name: string; decimals: number };
  underlyingSource: "MockStocks" | "MockB20" | "real";
  oracle: { decimals: number; initialPrice: string; heartbeatSec: number; stalenessBufferSec: number };
  strikeBps: number;
  floorBps: number;
  epochDurationSec: number;
  auctionWindowSec: number;
  premiumSanityCapBps: number;
  tvlCap: string;
  strategyCaps: { epoch: number; lending: number };
  routerTargetWeights: { epoch: number; lending: number };
  lendingStrategy: string;
};

type ChainConfig = {
  chainId?: number | string;
  vaults: VaultConfig[];
  lendingStrategyFallback: string;
};

type VerificationRecord = { address: string; name: string; status: "verified" | "skipped" | "failed" };

export type Deployed = {
  network: string;
  chainId: number | string;
  deployedAt: string;
  deployer: `0x${string}`;
  tokens: Record<string, `0x${string}`>;
  feeds: Record<string, `0x${string}`>;
  strategies: Record<string, `0x${string}`>;
  vaults: Record<string, `0x${string}`>;
  router: `0x${string}`;
  factory: `0x${string}`;
  faucet: `0x${string}`;
  verification: VerificationRecord[];
};

const hre = hrePkg as unknown as HardhatRuntimeEnvironment;
const LOCAL_NETWORKS = ["hardhatMainnet", "hardhatOp", "hardhatFork", "tenderly"];

type Connection = Awaited<ReturnType<typeof network.create>>;

// Pacing knobs: public RPCs and Blockscout rate-limit aggressively, so the
// script spreads its calls out. Override through the environment when a slow
// or fast run is wanted; the defaults suit the public testnets.
function envMs(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

const VERIFY_DELAY_MS = envMs("VERIFY_DELAY_MS", 20_000);
const DEPLOY_TX_DELAY_MS = envMs("DEPLOY_TX_DELAY_MS", 10_000);
const VERIFY_PACE_MS = 5_000;
const READ_RETRY_DELAY_MS = 4_000;
const READ_ATTEMPTS = 5;
const VERIFY_ATTEMPTS = 3;

function sleep(ms: number): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  setTimeout(resolve, ms);
  return promise;
}

export async function deployMain(connection?: Connection): Promise<Deployed> {
  const conn = connection ?? (await network.create());
  const { viem } = conn;
  const networkId = conn.networkName === "hardhat" ? "hardhatMainnet" : conn.networkName;
  const configName =
    networkId === "hardhatMainnet" || networkId === "hardhatOp" || networkId === "hardhatFork" || networkId === "tenderly"
      ? "base-sepolia"
      : networkId;
  const config: ChainConfig = JSON.parse(readFileSync(resolve("scripts/config", `${configName}.json`), "utf8"));

  const publicClient = await viem.getPublicClient();
  const [deployer] = await viem.getWalletClients();

  // A transient RPC failure must never kill a deploy that already spent gas,
  // so every onchain read goes through a few retries before giving up.
  async function readWithRetry<T>(label: string, read: () => Promise<T>): Promise<T> {
    let lastError: unknown;
    for (let attempt = 1; attempt <= READ_ATTEMPTS; attempt++) {
      try {
        return await read();
      } catch (err) {
        lastError = err;
        console.warn(`  ${label} attempt ${attempt} failed: ${(err as Error).message}`);
        if (attempt < READ_ATTEMPTS) await sleep(READ_RETRY_DELAY_MS);
      }
    }
    throw lastError;
  }

  const chainId = await readWithRetry("getChainId", () => publicClient.getChainId());

  // Fail fast on a wrong RPC: the config names the chain this run targets and
  // every transaction below would otherwise land somewhere unexpected. Local
  // simulations and rehearsal forks legitimately use their own chain ids.
  if (
    !LOCAL_NETWORKS.includes(networkId) &&
    config.chainId !== undefined &&
    BigInt(config.chainId) !== BigInt(chainId)
  ) {
    throw new Error(
      `Connected chain id ${chainId} does not match the ${networkId} config chain id ${config.chainId}; refusing to deploy.`
    );
  }

  const artifact: Deployed = {
    network: networkId,
    chainId,
    deployedAt: new Date().toISOString(),
    deployer: deployer.account.address,
    tokens: {},
    feeds: {},
    strategies: {},
    vaults: {},
    router: "0x" as `0x${string}`,
    factory: "0x" as `0x${string}`,
    faucet: "0x" as `0x${string}`,
    verification: [],
  };

  const keeper = (process.env.KEEPER_ADDRESS ?? deployer.account.address) as `0x${string}`;
  const feeRecipient = (process.env.FEE_RECIPIENT_ADDRESS ?? deployer.account.address) as `0x${string}`;

  async function verify(address: string, name: string, constructorArgs: unknown[], contractFqn: string) {
    if (LOCAL_NETWORKS.includes(networkId)) {
      artifact.verification.push({ address, name, status: "skipped" });
      return;
    }
    for (let attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt++) {
      try {
        await verifyContract({ address, constructorArgs, contract: contractFqn, provider: "blockscout" }, hre);
        artifact.verification.push({ address, name, status: "verified" });
        console.log(`  verified ${name} at ${address}`);
        // Pace the explorer so a long deploy does not trip its rate limits.
        await sleep(VERIFY_PACE_MS);
        return;
      } catch (err) {
        const message = (err as Error).message;
        console.warn(`  verification attempt ${attempt} failed for ${name}: ${message}`);
        if (attempt === VERIFY_ATTEMPTS) {
          artifact.verification.push({ address, name, status: "failed" });
        } else {
          // Blockscout answers 429 when pushed; back off harder on those.
          const wait = message.includes("429") ? VERIFY_DELAY_MS * 3 : VERIFY_DELAY_MS;
          await sleep(wait);
        }
      }
    }
  }

  async function writeWithRetry(label: string, send: () => Promise<`0x${string}`>) {
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        const hash = await send();
        await publicClient.waitForTransactionReceipt({ hash });
        await sleep(DEPLOY_TX_DELAY_MS);
        return;
      } catch (err) {
        console.warn(`  ${label} attempt ${attempt} failed: ${(err as Error).message}`);
        if (attempt === 2) throw err;
        await sleep(5_000);
      }
    }
  }

  console.log(`\nDeploying Eque on ${networkId} (chain ${chainId})`);
  console.log(`Deployer: ${deployer.account.address}\n`);

  // 1. Oracle and token mocks.
  for (const vaultConfig of config.vaults) {
    const feed = await viem.deployContract("MockV3Aggregator", [keeper, BigInt(vaultConfig.oracle.initialPrice)]);
    await sleep(DEPLOY_TX_DELAY_MS);
    artifact.feeds[vaultConfig.underlying.symbol] = feed.address;
    console.log(`MockV3Aggregator(${vaultConfig.underlying.symbol}) -> ${feed.address}`);
    await verify(
      feed.address,
      `MockV3Aggregator-${vaultConfig.underlying.symbol}`,
      [keeper, BigInt(vaultConfig.oracle.initialPrice)],
      "contracts/oracle/MockV3Aggregator.sol:MockV3Aggregator"
    );

    if (vaultConfig.underlyingSource === "MockStocks") {
      const token = await viem.deployContract("MockStocks", [
        vaultConfig.underlying.name,
        vaultConfig.underlying.symbol,
        "Eque testnet",
        deployer.account.address,
      ]);
      await sleep(DEPLOY_TX_DELAY_MS);
      artifact.tokens[vaultConfig.underlying.symbol] = token.address;
      console.log(`MockStocks(${vaultConfig.underlying.symbol}) -> ${token.address}`);
      await verify(
        token.address,
        `MockStocks-${vaultConfig.underlying.symbol}`,
        [vaultConfig.underlying.name, vaultConfig.underlying.symbol, "Eque testnet", deployer.account.address],
        "contracts/mocks/MockStocks.sol:MockStocks"
      );
    } else if (vaultConfig.underlyingSource === "MockB20") {
      const token = await viem.deployContract("MockB20", [
        vaultConfig.underlying.name,
        vaultConfig.underlying.symbol,
        deployer.account.address,
      ]);
      await sleep(DEPLOY_TX_DELAY_MS);
      artifact.tokens[vaultConfig.underlying.symbol] = token.address;
      console.log(`MockB20(${vaultConfig.underlying.symbol}) -> ${token.address}`);
      await verify(
        token.address,
        `MockB20-${vaultConfig.underlying.symbol}`,
        [vaultConfig.underlying.name, vaultConfig.underlying.symbol, deployer.account.address],
        "contracts/mocks/MockB20.sol:MockB20"
      );
    } else {
      throw new Error(`real underlying tokens for ${vaultConfig.underlying.symbol} need an address in the config first`);
    }
  }

  // 2. Factory (deploys router + vault implementation), then per-vault clones.
  const factory = await viem.deployContract("EqueVaultFactory", [deployer.account.address]);
  await sleep(DEPLOY_TX_DELAY_MS);
  artifact.factory = factory.address;
  const routerAddress = await readWithRetry("factory.read.router", () => factory.read.router());
  artifact.router = routerAddress;
  console.log(`EqueVaultFactory -> ${factory.address}`);
  console.log(`EqueRouter      -> ${routerAddress}`);
  await verify(factory.address, "EqueVaultFactory", [deployer.account.address], "contracts/core/EqueVaultFactory.sol:EqueVaultFactory");
  await verify(routerAddress, "EqueRouter", [deployer.account.address, factory.address], "contracts/core/EqueRouter.sol:EqueRouter");

  const vaultImplementation = await readWithRetry("factory.read.vaultImplementation", () =>
    factory.read.vaultImplementation()
  );
  console.log(`EqueVault implementation -> ${vaultImplementation}`);
  await verify(vaultImplementation, "EqueVault(implementation)", [], "contracts/core/EqueVault.sol:EqueVault");

  const router = await viem.getContractAt("EqueRouter", routerAddress);

  for (const vaultConfig of config.vaults) {
    const tokenAddress = artifact.tokens[vaultConfig.underlying.symbol]!;
    const feedAddress = artifact.feeds[vaultConfig.underlying.symbol]!;

    const epochArgs = [
      tokenAddress,
      {
        aggregator: feedAddress,
        sequencerFeed: "0x0000000000000000000000000000000000000000" as `0x${string}`,
        heartbeat: vaultConfig.oracle.heartbeatSec,
        stalenessBuffer: vaultConfig.oracle.stalenessBufferSec,
        deviationBps: 0,
        checkMarketHours: false,
        checkPaused: false,
        checkSequencer: false,
      },
      BigInt(vaultConfig.floorBps),
      BigInt(vaultConfig.epochDurationSec),
      BigInt(vaultConfig.auctionWindowSec),
      deployer.account.address,
    ] as const;
    const epochStrategy = await viem.deployContract("EpochStrategy", epochArgs);
    await sleep(DEPLOY_TX_DELAY_MS);
    artifact.strategies[`${vaultConfig.symbol}-epoch`] = epochStrategy.address;
    console.log(`EpochStrategy(${vaultConfig.symbol}) -> ${epochStrategy.address}`);
    await verify(
      epochStrategy.address,
      `EpochStrategy-${vaultConfig.symbol}`,
      [...epochArgs],
      "contracts/strategies/EpochStrategy.sol:EpochStrategy"
    );

    const lending = await viem.deployContract(vaultConfig.lendingStrategy, [tokenAddress, deployer.account.address]);
    await sleep(DEPLOY_TX_DELAY_MS);
    artifact.strategies[`${vaultConfig.symbol}-lending`] = lending.address;
    console.log(`${vaultConfig.lendingStrategy}(${vaultConfig.symbol}) -> ${lending.address}`);
    await verify(
      lending.address,
      `${vaultConfig.lendingStrategy}-${vaultConfig.symbol}`,
      [tokenAddress, deployer.account.address],
      `contracts/strategies/${vaultConfig.lendingStrategy}.sol:${vaultConfig.lendingStrategy}`
    );

    // The clone address comes from the factory's VaultDeployed event.
    const deployTx = await factory.write.deployVault([
      {
        underlying: tokenAddress,
        name: vaultConfig.shareTokenName,
        symbol: vaultConfig.symbol,
        cap: BigInt(vaultConfig.tvlCap),
        feeRecipient,
        depositFeeBps: 0,
        withdrawFeeBps: 0,
        epochStrategy: epochStrategy.address,
        lendingStrategy: lending.address,
        epochCapBps: BigInt(vaultConfig.strategyCaps.epoch),
        lendingCapBps: BigInt(vaultConfig.strategyCaps.lending),
        epochWeightBps: BigInt(vaultConfig.routerTargetWeights.epoch),
        lendingWeightBps: BigInt(vaultConfig.routerTargetWeights.lending),
      },
    ]);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: deployTx });
    await sleep(DEPLOY_TX_DELAY_MS);
    const logs = await readWithRetry("getContractEvents(VaultDeployed)", () =>
      publicClient.getContractEvents({
        address: factory.address,
        abi: factory.abi,
        eventName: "VaultDeployed",
        fromBlock: receipt.blockNumber,
        toBlock: receipt.blockNumber,
      })
    );
    const vaultAddress = logs[0]!.args.vault as `0x${string}`;

    const vaultClone = await viem.getContractAt("EqueVault", vaultAddress);
    artifact.vaults[vaultConfig.symbol] = vaultAddress;
    console.log(`EqueVault(${vaultConfig.symbol}) -> ${vaultAddress}`);

    // Strategies learn their vault; one-time admin wiring.
    await writeWithRetry(`setVault(epoch, ${vaultConfig.symbol})`, () =>
      epochStrategy.write.setVault([vaultAddress]),
    );
    await writeWithRetry(`setVault(lending, ${vaultConfig.symbol})`, () =>
      lending.write.setVault([vaultAddress]),
    );

    // Roles: keeper runs epochs and allocations; deployer holds curation.
    const keeperRole = await readWithRetry("vault.read.KEEPER_ROLE", () => vaultClone.read.KEEPER_ROLE());
    await writeWithRetry(`grantRole(keeper, ${vaultConfig.symbol})`, () =>
      vaultClone.write.grantRole([keeperRole, keeper]),
    );
    const vaultCuratorRole = await readWithRetry("vault.read.CURATOR_ROLE", () => vaultClone.read.CURATOR_ROLE());
    await writeWithRetry(`grantRole(curator, ${vaultConfig.symbol})`, () =>
      vaultClone.write.grantRole([vaultCuratorRole, deployer.account.address]),
    );
    const strategyKeeperRole = await readWithRetry("epochStrategy.read.KEEPER_ROLE", () =>
      epochStrategy.read.KEEPER_ROLE()
    );
    await writeWithRetry(`grantRole(strategy keeper, ${vaultConfig.symbol})`, () =>
      epochStrategy.write.grantRole([strategyKeeperRole, keeper]),
    );

    console.log(`  wired ${vaultConfig.symbol}: vault -> router -> strategies`);
  }

  // Router keeper grant for rebalance calls.
  const routerKeeperRole = await readWithRetry("router.read.KEEPER_ROLE", () => router.read.KEEPER_ROLE());
  await writeWithRetry("grantRole(router keeper)", () => router.write.grantRole([routerKeeperRole, keeper]));

  // 3. Faucet over the first token pair.
  const first = config.vaults[0]!;
  const second = config.vaults[1]!;
  const faucet = await viem.deployContract("TestnetFaucet", [
    artifact.tokens[first.underlying.symbol]!,
    artifact.tokens[second.underlying.symbol]!,
  ]);
  await sleep(DEPLOY_TX_DELAY_MS);
  artifact.faucet = faucet.address;
  console.log(`TestnetFaucet -> ${faucet.address}`);
  await verify(
    faucet.address,
    "TestnetFaucet",
    [artifact.tokens[first.underlying.symbol]!, artifact.tokens[second.underlying.symbol]!],
    "contracts/mocks/TestnetFaucet.sol:TestnetFaucet"
  );

  // Fund the faucet so testers can unblock themselves immediately.
  const firstToken = await viem.getContractAt("MockStocks", artifact.tokens[first.underlying.symbol]!);
  await writeWithRetry("mint(faucet, first)", () =>
    firstToken.write.mint([faucet.address, 100_000_000n * 10n ** 18n]),
  );
  if (second.underlyingSource === "MockStocks") {
    const secondStocks = await viem.getContractAt("MockStocks", artifact.tokens[second.underlying.symbol]!);
    await writeWithRetry("mint(faucet, second)", () =>
      secondStocks.write.mint([faucet.address, 100_000_000n * 10n ** 18n]),
    );
  } else {
    const secondB20 = await viem.getContractAt("MockB20", artifact.tokens[second.underlying.symbol]!);
    await writeWithRetry("mint(faucet, second)", () =>
      secondB20.write.mint([faucet.address, 100_000_000n * 10n ** 18n]),
    );
  }

  // 4. Artifact.
  mkdirSync("deployments", { recursive: true });
  const artifactPath = join("deployments", `${networkId}.json`);
  writeFileSync(artifactPath, JSON.stringify(artifact, null, 2));
  console.log(`\nDeployment artifact -> ${artifactPath}`);

  const verified = artifact.verification.filter((v) => v.status === "verified").length;
  const skipped = artifact.verification.filter((v) => v.status === "skipped").length;
  const failed = artifact.verification.filter((v) => v.status === "failed");
  if (failed.length > 0) {
    console.log(`\nMANUAL VERIFICATION STILL NEEDED for ${failed.length} contract(s):`);
    for (const f of failed) console.log(`  ${f.name} at ${f.address}`);
  }
  console.log(`\nVerification: ${verified} verified, ${skipped} skipped (no explorer), ${failed.length} failed.`);
  if (failed.length === 0 && skipped === 0) {
    console.log("All contracts verified.");
  } else if (failed.length === 0) {
    console.log("Local run: verification skipped; nothing needs manual attention.");
  }

  return artifact;
}

if (
  process.argv.some((arg) => arg.endsWith("scripts/deploy.ts")) &&
  !process.argv.some((arg) => arg.endsWith("scripts/deploy-and-smoke.ts"))
) {
  deployMain()
    .then(() => process.exit(0))
    .catch((err: unknown) => {
      console.error(err);
      process.exit(1);
    });
}
