import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";
import hardhatTypechain from "@nomicfoundation/hardhat-typechain";

export default defineConfig({
  plugins: [
    hardhatToolboxViemPlugin,
    hardhatTypechain
  ],
  solidity: {
    profiles: {
      default: {
        version: "0.8.34",
      },
      production: {
        version: "0.8.34",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
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
    tenderlyFork: {
      type: "http",
      chainType: "generic",
      url: configVariable("TENDERLY_FORK_RPC"),
      accounts: [configVariable("DEPLOYER_PRIVATE_KEY")],
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
