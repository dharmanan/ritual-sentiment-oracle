require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const privateKey = (process.env.PRIVATE_KEY || "").trim();
const normalizedPrivateKey = /^(0x)?[0-9a-fA-F]{64}$/.test(privateKey)
  ? privateKey.startsWith("0x")
    ? privateKey
    : `0x${privateKey}`
  : undefined;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    "ritual-testnet": {
      url:      process.env.RITUAL_RPC_URL || "https://rpc.ritualfoundation.org",
      accounts: normalizedPrivateKey ? [normalizedPrivateKey] : [],
      chainId:  1979,
    },
  },
};
