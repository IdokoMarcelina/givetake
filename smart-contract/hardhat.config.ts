import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";
import { vars } from "hardhat/config";

dotenv.config();

const ARB_RPC = process.env.ARB_RPC || "";

const DEPLOYER_KEY = vars.get("PRIVATE_KEY");

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    arbitrum: {
      url: ARB_RPC,
      accounts: DEPLOYER_KEY ? [DEPLOYER_KEY] : [],
    },
  },
};

export default config;
