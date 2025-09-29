import { ethers } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with", deployer.address);

  const PromiseCard = await ethers.getContractFactory("PromiseCard");
  const platformFeeBps = Number(process.env.PLATFORM_FEE_BPS || "250");
  // faucet: 0.01 native, cooldown 1 day
  const faucetAmountNative = ethers.parseEther("0.01");
  const faucetCooldown = 86400;

  const pc = await PromiseCard.deploy(platformFeeBps, faucetAmountNative, faucetCooldown);
  await pc.waitForDeployment();
  console.log("PromiseCard deployed to:", pc.target);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
