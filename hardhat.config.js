import { defineConfig } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatNetworkHelpers from "@nomicfoundation/hardhat-network-helpers";
import hardhatNodeTestRunner from "@nomicfoundation/hardhat-node-test-runner";
import dotenv from "dotenv";

dotenv.config();

const privateKey = (process.env.PRIVATE_KEY || "").trim();
const normalizedPrivateKey = /^(0x)?[0-9a-fA-F]{64}$/.test(privateKey)
  ? privateKey.startsWith("0x")
    ? privateKey
    : `0x${privateKey}`
  : undefined;

const config = defineConfig({
  plugins: [
    hardhatEthers,
    hardhatNetworkHelpers,
    hardhatNodeTestRunner,
  ],
  solidity: {
    version: "0.8.30",
    settings: {
      viaIR: true,
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    "ritual-testnet": {
      type: "http",
      chainType: "l1",
      url:      process.env.RITUAL_RPC_URL || "https://rpc.ritualfoundation.org",
      accounts: normalizedPrivateKey ? [normalizedPrivateKey] : [],
      chainId:  1979,
    },
  },
});

export default config;
