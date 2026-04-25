// scripts/deploy.js
// Deploy SentimentOracle to Ritual Chain Testnet
// Usage: npx hardhat run scripts/deploy.js --network ritual-testnet

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying SentimentOracle...");
  console.log("  Deployer :", deployer.address);
  console.log("  Balance  :", ethers.formatEther(
    await ethers.provider.getBalance(deployer.address)
  ), "RITUAL");

  const Factory = await ethers.getContractFactory("SentimentOracle");
  const contract = await Factory.deploy();
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log("\n✅ SentimentOracle deployed at:", address);
  console.log("\nAdd to your .env:");
  console.log(`CONTRACT_ADDRESS=${address}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
