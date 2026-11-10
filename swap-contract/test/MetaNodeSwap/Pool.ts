import { loadFixture } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre from "hardhat";
import { TickMath, encodeSqrtRatioX96 } from "@uniswap/v3-sdk";

describe("Pool", function () {
  // deployFixture()：先把交易池搭起来
  //  Factory
  //   ↓
  // 创建两个 Token
  //   ↓
  // 确定 token0 < token1
  //   ↓
  // 创建 Pool
  //   ↓
  // 初始化价格 = 10000
  //   ↓
  // 得到一个可以交易的 Pool
  async function deployFixture() {
    // 初始化一个池子，价格上限是 40000，下限是 1，初始化价格是 10000，费率是 0.3%
    const factory = await hre.viem.deployContract("Factory");
    const tokenA = await hre.viem.deployContract("TestToken");
    const tokenB = await hre.viem.deployContract("TestToken");
    const token0 = tokenA.address < tokenB.address ? tokenA : tokenB;
    const token1 = tokenA.address < tokenB.address ? tokenB : tokenA;
    const tickLower = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(1, 1));
    const tickUpper = TickMath.getTickAtSqrtRatio(encodeSqrtRatioX96(40000, 1));
    // 以 1,000,000 为基底的手续费费率，Uniswap v3 前端界面支持四种手续费费率（0.01%，0.05%、0.30%、1.00%），对于一般的交易对推荐 0.30%，fee 取值即 3000；
    const fee = 3000;
    const publicClient = await hre.viem.getPublicClient();
    await factory.write.createPool([
      token0.address,
      token1.address,
      tickLower,
      tickUpper,
      fee,
    ]);
    // 从 Factory 合约中读取 PoolCreated 事件
    const createEvents = await factory.getEvents.PoolCreated();
    //createEvents[0]  第一条创建池子的事件
    // createEvents[0].args.pool，从这条事件里取出 pool 参数，也就是 Pool 合约地址
    // || "0x"，如果 pool 没有值，就使用 "0x" 作为默认值。
    const poolAddress: `0x${string}` = createEvents[0].args.pool || "0x";
    // 根据 Pool 合约的 ABI + poolAddress，获取这个已经部署好的 Pool 合约实例
    // "Pool" as string，指定要使用的合约类型，也就是 Pool 合约
    // poolAddress 指定这个 Pool 合约实际部署在哪个地址
    // Pool 合约
    // getContractAt() = 拿着“合约类型 + 合约地址”，把已经部署在链上的那个合约接进来操作。
    const pool = await hre.viem.getContractAt("Pool" as string, poolAddress);

    // 计算一个初始化的价格，按照 1 个 token0 换 10000 个 token1 来算，其实就是 10000
    const sqrtPriceX96 = encodeSqrtRatioX96(10000, 1);
    await pool.write.initialize([sqrtPriceX96]);
    // deployFixture() 最后把前面创建好的这一整套测试环境，打包成一个对象返回出去
    return {
      token0,
      token1,
      factory,
      pool,
      publicClient,
      tickLower,
      tickUpper,
      fee,
      sqrtPriceX96: BigInt(sqrtPriceX96.toString()),
    };
  }

  it("pool info", async function () {
   // 加载 deployFixture 创建好的测试环境
   // 从返回对象中取出 Pool、两个 Token、Tick 范围、手续费和初始化价格
   //  这里不要求个数和顺序一致。因为这不是按位置接收返回值，而是在对一个 对象进行解构。
    //    你的 deployFixture() 返回的是：
    // return {
    //   token0,
    //   token1,
    //   factory,
    //   pool,
    //   publicClient,
    //   tickLower,
    //   tickUpper,
    //   fee,
    //   sqrtPriceX96
    // };

    // 而这里：
    // const {
    //   pool,
    //   token0,
    //   token1,
    //   tickLower,
    //   tickUpper,
    //   fee,
    //   sqrtPriceX96
    // } = await loadFixture(deployFixture);
    // 是根据 属性名 找值。
    const { pool, token0, token1, tickLower, tickUpper, fee, sqrtPriceX96 } =
      await loadFixture(deployFixture);
    // as 是 TypeScript 的类型断言（type assertion）
    ((await pool.read.token0()) as string)
    // 意思是：
    // 告诉 TypeScript：我认为 pool.read.token0() 返回的这个值是一个 string。
    expect(((await pool.read.token0()) as string).toLocaleLowerCase()).to.equal(
      token0.address
    );
    expect(((await pool.read.token1()) as string).toLocaleLowerCase()).to.equal(
      token1.address
    );
    expect(await pool.read.tickLower()).to.equal(tickLower);
    expect(await pool.read.tickUpper()).to.equal(tickUpper);
    expect(await pool.read.fee()).to.equal(fee);
    expect(await pool.read.sqrtPriceX96()).to.equal(sqrtPriceX96);
  });

  it("mint and burn and collect", async function () {
    const { pool, token0, token1, sqrtPriceX96 } = await loadFixture(
      deployFixture
    );
    const testLP = await hre.viem.deployContract("TestLP");

    const initBalanceValue = 1000n * 10n ** 18n;
    await token0.write.mint([testLP.address, initBalanceValue]);
    await token1.write.mint([testLP.address, initBalanceValue]);

    // mint 20000000 份流动性
    await testLP.write.mint([
      testLP.address,
      20000000n,
      pool.address,
      token0.address,
      token1.address,
    ]);

    expect(await token0.read.balanceOf([pool.address])).to.equal(
      initBalanceValue - (await token0.read.balanceOf([testLP.address]))
    );
    expect(await token1.read.balanceOf([pool.address])).to.equal(
      initBalanceValue - (await token1.read.balanceOf([testLP.address]))
    );

    const position = await pool.read.positions([testLP.address]);
    expect(position).to.deep.equal([20000000n, 0n, 0n, 0n, 0n]);
    expect(await pool.read.liquidity()).to.equal(20000000n);

    // 继续 mint 50000
    await testLP.write.mint([
      testLP.address,
      50000n,
      pool.address,
      token0.address,
      token1.address,
    ]);
    expect(await pool.read.liquidity()).to.equal(20050000n);
    expect(await token0.read.balanceOf([pool.address])).to.equal(
      initBalanceValue - (await token0.read.balanceOf([testLP.address]))
    );
    expect(await token1.read.balanceOf([pool.address])).to.equal(
      initBalanceValue - (await token1.read.balanceOf([testLP.address]))
    );

    // burn 10000
    await testLP.write.burn([10000n, pool.address]);
    expect(await pool.read.liquidity()).to.equal(20040000n);

    // create new LP
    const testLP2 = await hre.viem.deployContract("TestLP");
    await token0.write.mint([testLP2.address, initBalanceValue]);
    await token1.write.mint([testLP2.address, initBalanceValue]);
    await testLP2.write.mint([
      testLP2.address,
      3000n,
      pool.address,
      token0.address,
      token1.address,
    ]);
    expect(await pool.read.liquidity()).to.equal(20043000n);

    const totalToken0 =
      initBalanceValue -
      (await token0.read.balanceOf([testLP.address])) +
      (initBalanceValue - (await token0.read.balanceOf([testLP2.address])));
    // 判断池子里面的 token0 是否等于 LP1 和 LP2 减少的 token0 之和
    expect(await token0.read.balanceOf([pool.address])).to.equal(totalToken0);

    // burn all liquidity for LP
    await testLP.write.burn([20040000n, pool.address]);
    expect(await pool.read.liquidity()).to.equal(3000n);

    // 判断池子里面的 token0 是否等于 LP1 和 LP2 减少的 token0 之和，burn 只是把流动性返回给 LP，不会把 token 返回给 LP
    expect(await token0.read.balanceOf([pool.address])).to.equal(totalToken0);
    // collect, all balance return to testLP
    await testLP.write.collect([testLP.address, pool.address]);

    // 因为取整的原因，提取流动性之后获得的 token 可能会比之前少一点
    expect(
      Number(initBalanceValue - (await token0.read.balanceOf([testLP.address])))
    ).to.lessThan(10);
    expect(
      Number(initBalanceValue - (await token1.read.balanceOf([testLP.address])))
    ).to.lessThan(10);
  });

  it("swap", async function () {
    const { pool, token0, token1, sqrtPriceX96 } = await loadFixture(
      deployFixture
    );
    const testLP = await hre.viem.deployContract("TestLP");

    const initBalanceValue = 100000000000n * 10n ** 18n;
    await token0.write.mint([testLP.address, initBalanceValue]);
    await token1.write.mint([testLP.address, initBalanceValue]);

    // mint 多一些流动性，确保交易可以完全完成
    const liquidityDelta = 1000000000000000000000000000n;
    // mint 多一些流动性，确保交易可以完全完成
    await testLP.write.mint([
      testLP.address,
      liquidityDelta,
      pool.address,
      token0.address,
      token1.address,
    ]);

    const lptoken0 = await token0.read.balanceOf([testLP.address]);
    expect(lptoken0).to.equal(99995000161384542080378486215n);

    const lptoken1 = await token1.read.balanceOf([testLP.address]);
    expect(lptoken1).to.equal(1000000000000000000000000000n);

    // 通过 TestSwap 合约交易
    const testSwap = await hre.viem.deployContract("TestSwap");
    const minPrice = 1000;
    const minSqrtPriceX96: bigint = BigInt(
      encodeSqrtRatioX96(minPrice, 1).toString()
    );

    // 给 testSwap 合约中打入 token0 用于交易
    await token0.write.mint([testSwap.address, 300n * 10n ** 18n]);

    expect(await token0.read.balanceOf([testSwap.address])).to.equal(
      300n * 10n ** 18n
    );
    expect(await token1.read.balanceOf([testSwap.address])).to.equal(0n);
    const result = await testSwap.simulate.testSwap([
      testSwap.address,
      100n * 10n ** 18n, // 卖出 100 个 token0
      minSqrtPriceX96,
      pool.address,
      token0.address,
      token1.address,
    ]);
    expect(result.result[0]).to.equal(100000000000000000000n); // 需要 100个 token0
    expect(result.result[1]).to.equal(-996990060009101709255958n); // 大概需要 100 * 10000 个 token1

    await testSwap.write.testSwap([
      testSwap.address,
      100n * 10n ** 18n,
      minSqrtPriceX96,
      pool.address,
      token0.address,
      token1.address,
    ]);
    const costToken0 =
      300n * 10n ** 18n - (await token0.read.balanceOf([testSwap.address]));
    const receivedToken1 = await token1.read.balanceOf([testSwap.address]);
    const newPrice = (await pool.read.sqrtPriceX96()) as bigint;
    const liquidity = await pool.read.liquidity();
    expect(newPrice).to.equal(7922737261735934252089901697281n);
    expect(sqrtPriceX96 - newPrice).to.equal(78989690499507264493336319n); // 价格下跌
    expect(liquidity).to.equal(liquidityDelta); // 流动性不变

    // 用户消耗了 100 个 token0
    expect(costToken0).to.equal(100n * 10n ** 18n);
    // 用户获得了大约 100 * 10000 个 token1
    expect(receivedToken1).to.equal(996990060009101709255958n);

    // 提取流动性，调用 burn 方法
    await testLP.write.burn([liquidityDelta, pool.address]);
    // 查看当前 token 数量
    expect(await token0.read.balanceOf([testLP.address])).to.equal(
      99995000161384542080378486215n
    );
    // 提取 token
    await testLP.write.collect([testLP.address, pool.address]);
    // 判断 token 是否返回给 testLP，并且大于原来的数量，因为收到了手续费，并且有交易换入了 token0
    // 初始的 token0 是 const initBalanceValue = 100000000000n * 10n ** 18n;
    expect(await token0.read.balanceOf([testLP.address])).to.equal(
      100000000099999999999999999998n
    );
  });
});
