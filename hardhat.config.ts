import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import hardhatTypechain from "@nomicfoundation/hardhat-typechain";
import hardhatSlangSolx from "@nomicfoundation/hardhat-slang-solx";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [
    hardhatToolboxViemPlugin,
    hardhatTypechain,
    hardhatSlangSolx,
  ],
  solidity: {
    profiles: {
      default: {
        version: "0.8.34",
        settings: {
          viaIR: true,
        },
      },
      production: {
        version: "0.8.34",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
      "slang-solx": {
        type: "slang-solx",
        version: "0.8.34",
        settings: {
          optimizer: {
            enabled: true,
            mode: "3",
          },
          dangerouslyAllowSlangSolxInProduction: true,
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    hardhatFork: {
      type: "edr-simulated",
      forking: {
        url: configVariable("FORK_RPC_URL"),
      },
      accounts: [
        {
          privateKey: configVariable("DEPLOYER_PRIVATE_KEY"),
          balance: "1000000000000000000000",
        },
      ],
    },
    tenderly: {
      type: "http",
      chainType: "generic",
      url: configVariable("TENDERLY_FORK_RPC"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
      chainId: 1524,
    },
    "robinhood-testnet": {
      type: "http",
      chainType: "generic",
      url: configVariable("ROBINHOOD_TESTNET_RPC"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
      chainId: 46630,
    },
    "base-sepolia": {
      type: "http",
      chainType: "op",
      chainId: 84532,
      url: configVariable("BASE_SEPOLIA_RPC"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
    },
  },
  chainDescriptors: {
    84532: {
      name: "Base Sepolia",
      blockExplorers: {
        etherscan: {
          name: "BaseScan",
          url: "https://sepolia.basescan.org",
          apiUrl: "https://api-sepolia.basescan.org/api",
        },
        blockscout: {
          name: "Base Sepolia Blockscout",
          url: "https://base-sepolia.blockscout.com",
        },
      },
    },
    46630: {
      name: "Robinhood Chain Testnet",
      blockExplorers: {
        blockscout: {
          name: "Robinhood Chain Blockscout",
          url: "https://robinhood-testnet.blockscout.com",
          apiUrl: "https://robinhood-testnet.blockscout.com/api/v2",
        },
      },
    },
  },
  verify: {
    etherscan: {
      apiKey: configVariable("BASESCAN_API_KEY"),
    },
    blockscout: {
      apiKey: configVariable("ROBINHOOD_EXPLORER_API_KEY"),
    },
  },
});
