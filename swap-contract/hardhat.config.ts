import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";
import "@nomicfoundation/hardhat-verify";
import "hardhat-gas-reporter"

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
    },
    sepolia: {
      url: "",
      accounts: ["0xecd01ca33084cec9d77d0352096649095074440915c2662f25d805456861f082"], // 替换为你的钱包私钥
    },
  },
  etherscan: {
    apiKey: {
      sepolia: "",
    },
  },
};

module.exports = {
  default: config,
  gasReporter: {
    enable : true,
    currency: '$'
  }
}
