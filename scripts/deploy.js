// Deploy ScheduledMarketWatcher to Ritual Chain Testnet
// Usage: npx hardhat run scripts/deploy.js --network ritual-testnet

import { network } from "hardhat";

async function main() {
  const { ethers } = await network.create();
  const [deployer] = await ethers.getSigners();

  console.log("Deploying ScheduledMarketWatcher...");
  console.log("  Deployer :", deployer.address);
  console.log("  Balance  :", ethers.formatEther(
    await ethers.provider.getBalance(deployer.address)
  ), "RITUAL");

  const Factory = await ethers.getContractFactory(
    "contracts/ScheduledMarketWatcher.sol:ScheduledMarketWatcher"
  );
  const contract = await Factory.deploy();
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log("\n✅ ScheduledMarketWatcher deployed at:", address);
  console.log("\nAdd to your .env:");
  console.log(`CONTRACT_ADDRESS=${address}`);
  console.log("\nSuggested next steps:");
  console.log("  npm run helper:inspect");
  console.log("  python agent/oracle_agent.py configure --symbol ETH --coin-id ethereum");
  console.log("  python agent/oracle_agent.py fund --amount 0.05 --lock-blocks 50000");
  console.log("  python agent/oracle_agent.py schedule --symbol ETH");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
