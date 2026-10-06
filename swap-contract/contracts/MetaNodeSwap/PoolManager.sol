// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
pragma abicoder v2;

import "./interfaces/IPoolManager.sol";
import "./Factory.sol";
import "./interfaces/IPool.sol";

contract PoolManager is Factory, IPoolManager {
    // 定义一个 Pair 类型的动态数组，用来记录所有已经存在的交易对（token0 + token1）。
    Pair[] public pairs;

    function getPairs() external view override returns (Pair[] memory) {
        return pairs;
    }
    // 把 Factory 里记录的所有交易对的所有 Pool 全部遍历出来，然后整理成一个 PoolInfo[] 数组一次性返回。
    function getAllPools()
        external
        view
        override
        returns (PoolInfo[] memory poolsInfo)
    {
        uint32 length = 0;
        // 先算一下大小
        //         假设现在：

        // pairs[i] = ETH / USDC

        // 那么：

        // pools[pairs[i].token0][pairs[i].token1]

        // 就是：

        // pools[ETH][USDC]

        // 可能得到：

        // [
        //     PoolA地址,
        //     PoolB地址,
        //     PoolC地址
        // ]

        // 所以 addresses 就是：

        // 当前交易对下面所有 Pool 的地址数组。
        for (uint32 i = 0; i < pairs.length; i++) {
            length += uint32(pools[pairs[i].token0][pairs[i].token1].length);
        }

        // 再填充数据
        poolsInfo = new PoolInfo[](length);
        uint256 index;
        // i 找“哪个交易对”，j 找“这个交易对里的第几个 Pool”，然后把 Pool 的信息收集到 poolsInfo。
        for (uint32 i = 0; i < pairs.length; i++) {
                // 第一个循环   pairs  i 就是在一个个遍历这些交易对。
                // ├── 0：ETH / USDC
                // ├── 1：ETH / USDT
                // └── 2：WBTC / USDC
            address[] memory addresses = pools[pairs[i].token0][pairs[i].token1];
            for (uint32 j = 0; j < addresses.length; j++) {
                //   假设现在：

                // pairs[i] = ETH / USDC

                // 那么：

                // pools[pairs[i].token0][pairs[i].token1]

                // 就是：

                // pools[ETH][USDC]

                // 可能得到：

                // [
                //     PoolA地址,
                //     PoolB地址,
                //     PoolC地址
                // ]
                //  addresses[j]  是一个地址
                IPool pool = IPool(addresses[j]);
                poolsInfo[index] = PoolInfo({
                    pool: addresses[j],
                    token0: pool.token0(),
                    token1: pool.token1(),
                    index: j,
                    fee: pool.fee(),
                    feeProtocol: 0,
                    tickLower: pool.tickLower(),
                    tickUpper: pool.tickUpper(),
                    tick: pool.tick(),
                    sqrtPriceX96: pool.sqrtPriceX96(),
                    liquidity: pool.liquidity()
                });
                index++;
            }
        }
        return poolsInfo;
    }
    // 创建一个 Pool；如果 Pool 还没有价格，就初始化价格；
    // 如果这是这个 token 交易对第一次出现，就把交易对记录到 pairs。
    function createAndInitializePoolIfNecessary(
        CreateAndInitializeParams calldata params
    ) external payable override returns (address poolAddress) {
        require(
            params.token0 < params.token1,
            "token0 must be less than token1"
        );

        poolAddress = this.createPool(
            params.token0,
            params.token1,
            params.tickLower,
            params.tickUpper,
            params.fee
        );

        IPool pool = IPool(poolAddress);
        //  假设现在有：

        // ETH / USDC

        // 已经创建了 2 个 Pool：

        // pools[ETH][USDC]

        // [
        //     Pool0,
        //     Pool1
        // ]

        // 那么：

        // pools[pool.token0()][pool.token1()].length

        // 就是：

        // 2

        uint256 index = pools[pool.token0()][pool.token1()].length;

        // 新创建的池子，没有初始化价格，需要初始化价格
        if (pool.sqrtPriceX96() == 0) {
            pool.initialize(params.sqrtPriceX96);

        // struct Pair {
        //     address token0;
        //     address token1;
        // }
        //         所以这里index == 1的本质就是：
        // Pool 创建完成后，如果这个交易对的 Pool 数量刚好是 1，说明这是它第一次出现。
        //         第一次创建 ETH/USDC

        // 原来：

        // pools[ETH][USDC] = []

        // 创建 Pool 后：

        // pools[ETH][USDC] = [Pool0]

        // 所以：

        // index = 1

        // 因此：

        // if (index == 1)

        // 成立。

        // → 说明这是 ETH/USDC 第一个 Pool
        // → 所以把 ETH/USDC 加入 pairs。
            if (index == 1) {
                // 如果是第一次添加该交易对，需要记录
                pairs.push(
                    Pair({token0: pool.token0(), token1: pool.token1()})
                );
            }
        }
    }
}
