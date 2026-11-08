import { loadFixture } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre from "hardhat";
import { TickMath, encodeSqrtRatioX96 } from "@uniswap/v3-sdk";

describe("PoolManager", function () {
// 部署测试环境，并获取公共客户端
async function deployFixture() {
    // 部署 PoolManager 合约，获取合约实例
    const manager = await hre.viem.deployContract("PoolManager");

    // 获取公共客户端，用于查询区块链数据、读取合约状态等
    const publicClient = await hre.viem.getPublicClient();
    // 返回合约实例和公共客户端，供测试用例使用
    return {
      manager,
      publicClient,
    };
}

 // 测试获取所有交易对和所有交易池的功能
//  getPairs()：能否正确获取所有交易对。
// getAllPools()：能否正确获取所有交易池，以及交易池中的代币地址、初始价格等信息。
// 这个测试用例要验证 getPairs 和 getAllPools 两个函数是否正常工作
it("getPairs & getAllPools", async function () {
    // 加载测试环境；如果已经执行过该 Fixture，则复用其快照
    const { manager } = await loadFixture(deployFixture);

    // 定义四个代币地址，用于创建两个不同的交易池
    const tokenA: `0x${string}` = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984";
    const tokenB: `0x${string}` = "0xEcd0D12E21805803f70de03B72B1C162dB0898d9";
    const tokenC: `0x${string}` = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599";
    const tokenD: `0x${string}` = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
                                                                        
    // 创建并初始化 tokenA-tokenB 交易池
    // 如果交易池不存在，就创建并初始化；如果已经存在，就复用已有交易池
    // createAndInitializePoolIfNecessary() 中的 IfNecessary 就体现了这个设计思想：只有必要时才创建。
    await manager.write.createAndInitializePoolIfNecessary([
      {
        // 指定交易池中的两种代币。
        token0: tokenA,
        token1: tokenB,

        // 设置交易手续费率参数
        fee: 3000,

        // 设置允许的最低 Tick，对应价格比例 1/1
        tickLower: TickMath.getTickAtSqrtRatio(
          // 计算价格比例为 1:1 时对应的平方根价格，并转换成 Q64.96 定点数。
          encodeSqrtRatioX96(1, 1)
        ),                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    

        // 设置允许的最高 Tick，对应价格比例 10000/1
        tickUpper: TickMath.getTickAtSqrtRatio(
          encodeSqrtRatioX96(10000, 1)
        ),

        // 设置初始价格：价格比例为 100/1
        // 将计算结果转换为 BigInt，以匹配合约的整数类型
        sqrtPriceX96: BigInt(
          encodeSqrtRatioX96(100, 1).toString()
        ),
      },
    ]);

    // 使用相同的代币、手续费、Tick 范围和初始价格再次创建
    // 预期复用已有交易池，不会重复创建同一个池子
    // createAndInitializePoolIfNecessary() 中的 IfNecessary 就体现了这个设计思想：只有必要时才创建。
    await manager.write.createAndInitializePoolIfNecessary([
      {
        token0: tokenA,
        token1: tokenB,
        fee: 3000,
        tickLower: TickMath.getTickAtSqrtRatio(
          encodeSqrtRatioX96(1, 1)
        ),
        tickUpper: TickMath.getTickAtSqrtRatio(
          encodeSqrtRatioX96(10000, 1)
        ),
        sqrtPriceX96: BigInt(
          encodeSqrtRatioX96(100, 1).toString()
        ),
      },
    ]);

    // 创建并初始化第二个交易池：tokenC-tokenD
    await manager.write.createAndInitializePoolIfNecessary([
      {
        token0: tokenC,
        token1: tokenD,

        // 设置第二个交易池的手续费率参数
        fee: 2000,

        // 设置允许的最低 Tick，对应价格比例 100/1
        tickLower: TickMath.getTickAtSqrtRatio(
          encodeSqrtRatioX96(100, 1)
        ),

        // 设置允许的最高 Tick，对应价格比例 5000/1
        tickUpper: TickMath.getTickAtSqrtRatio(
          encodeSqrtRatioX96(5000, 1)
        ),

        // 设置初始价格：价格比例为 200/1
        sqrtPriceX96: BigInt(
          encodeSqrtRatioX96(200, 1).toString()
        ),
      },
    ]);

    // 查询所有交易对，验证重复创建没有导致交易对数量增加
    const pairs = await manager.read.getPairs();
    expect(pairs.length).to.equal(2);

    // 查询所有交易池，验证交易池总数为 2
    const pools = await manager.read.getAllPools();
    expect(pools.length).to.equal(2);

    // 验证第一个交易池的代币地址
    expect(pools[0].token0).to.equal(tokenA);
    expect(pools[0].token1).to.equal(tokenB);

    // 验证第一个交易池的初始价格
    expect(pools[0].sqrtPriceX96).to.equal(
      BigInt(encodeSqrtRatioX96(100, 1).toString())
    );

    // 验证第二个交易池的代币地址
    expect(pools[1].token0).to.equal(tokenC);
    expect(pools[1].token1).to.equal(tokenD);

    // 验证第二个交易池的初始价格
    expect(pools[1].sqrtPriceX96).to.equal(
      BigInt(encodeSqrtRatioX96(200, 1).toString())
    );
});
  it("require token0 < token1", async function () {
    const { manager } = await loadFixture(deployFixture);
    const tokenA: `0x${string}` = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984";
    const tokenB: `0x${string}` = "0xEcd0D12E21805803f70de03B72B1C162dB0898d9";

    await expect(
      manager.write.createAndInitializePoolIfNecessary([
        {
          token0: tokenB,
          token1: tokenA,
          fee: 3000,
          tickLower: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1)),
          tickUpper: TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(10000, 1)),
          sqrtPriceX96: BigInt(encodeSqrtRatioX96(100, 1).toString()),
        },
      ])
    ).to.be.rejected;
  });
});
