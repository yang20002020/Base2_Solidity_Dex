import { loadFixture } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre from "hardhat";

// describe：给一组测试分组。
// it：定义一个具体的测试用例。
// describe 的意思是：定义一组测试，并给这组测试起个名字。
// describe("Factory", ...)：这组测试专门测试 Factory 合约。
// it("createPool", ...)：其中一个测试，检查能否正常创建交易池。
// it("createPool with same token", ...)：另一个测试，检查相同 Token 地址是否会报错。
describe("Factory", function () {
  // 部署 Factory，并获取公共客户端
  // 相当于准备测试环境，后续测试可以重复使用
  async function deployFixture() {
    const factory = await hre.viem.deployContract("Factory");
    const publicClient = await hre.viem.getPublicClient();
    return {
      factory,
      publicClient,
    };
  }

  it("createPool", async function () {
    // 加载测试环境
    const { factory, publicClient } = await loadFixture(deployFixture);
    // 准备两个 Token 地址
    //     这两个地址代表两种 Token 对应的合约地址。
    // 你可以把它想象成开一家兑换店：
    // - Token A：兑换店收购的一种资产。
    // - Token B：兑换店提供的另一种资产。
    // - Factory：负责开设兑换店的工厂。
    // - Pool：真正进行两种资产兑换的交易池。
    const tokenA: `0x${string}` = "0xEcd0D12E21805803f70de03B72B1C162dB0898d9";
    const tokenB: `0x${string}` = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984";
    // 调用 Factory 创建交易池
    // 参数：Token A、Token B、价格下限、价格上限、手续费
    const hash = await factory.write.createPool([
      tokenA,
      tokenB,
      1,
      100000,
      3000,
    ]);
    // 等待交易上链，确保创建操作已经执行
    await publicClient.waitForTransactionReceipt({ hash });
     // 获取 Factory 发出的 PoolCreated 事件
    const createEvents = await factory.getEvents.PoolCreated();
     // 验证只创建了一次交易池
    expect(createEvents).to.have.lengthOf(1);
    // 验证事件中记录的交易池地址格式正确
    expect(createEvents[0].args.pool).to.match(/^0x[a-fA-F0-9]{40}$/);
    // Factory 会按地址大小排序 Token
    // 所以 token0 是较小的地址，token1 是较大的地址
    // 语法：expect(实际结果).to.equal(预期结果);  实际结果必须等于预期结果，否则测试报错
    expect(createEvents[0].args.token0).to.equal(tokenB);
    expect(createEvents[0].args.token1).to.equal(tokenA);
    expect(createEvents[0].args.tickLower).to.equal(1);
    expect(createEvents[0].args.tickUpper).to.equal(100000);
    expect(createEvents[0].args.fee).to.equal(3000);

    // simulate for test return address
    // 模拟调用 createPool，提前获取函数的返回值
    // simulate 只模拟执行，不会再次发送交易
    const poolAddress = await factory.simulate.createPool([
      tokenA,
      tokenB,
      1,
      100000,
      3000,
    ]);
    // 验证模拟返回的地址格式正确
    expect(poolAddress.result).to.match(/^0x[a-fA-F0-9]{40}$/);
    //  验证模拟返回的地址与实际创建的交易池地址一致
    expect(poolAddress.result).to.equal(createEvents[0].args.pool);
  });

  it("createPool with same token", async function () {
      // 加载测试环境
    const { factory } = await loadFixture(deployFixture);
      // 故意让两个 Token 地址相同，模拟错误输入
    const tokenA: `0x${string}` = "0xEcd0D12E21805803f70de03B72B1C162dB0898d9";
    const tokenB: `0x${string}` = "0xEcd0D12E21805803f70de03B72B1C162dB0898d9";
      // 验证创建交易池失败，并返回 IDENTICAL_ADDRESSES 错误
      // 因为交易池的作用是让两种不同的 Token 进行兑换。如果两个地址相同，就相当于用 USDT 兑换 USDT，没有必要建立这样的交易池。
    await expect(
      factory.write.createPool([tokenA, tokenB, 1, 100000, 3000])
    ).to.be.rejectedWith("IDENTICAL_ADDRESSES");
       // 验证查询相同 Token 的交易池时，也会触发相同地址校验错误
    await expect(factory.read.getPool([tokenA, tokenB, 3])).to.be.rejectedWith(
      "IDENTICAL_ADDRESSES"
    );
  });
});
