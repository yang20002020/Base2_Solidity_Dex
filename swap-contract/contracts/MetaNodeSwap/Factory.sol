// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./interfaces/IFactory.sol";
import "./Pool.sol";

// Factory 负责按照 token0、token1、tick 范围和 fee，创建、查找并记录对应的 Pool。
// Factory 本身并不负责运行 swap、计算价格、管理流动性。
// 它主要负责 “按照一组参数找到/创建正确的 Pool”。
contract Factory is IFactory {
    // pools[token0][token1] = 这个 token 对应创建过的所有 Pool
    //
    // 为什么是 address[]？
    // 因为同一对 token 可以存在多个 Pool，
    // 例如 tick 范围、手续费 fee 不同，就可以是不同的 Pool。
    mapping(address => mapping(address => address[])) public pools;
    // 创建 Pool 时，Factory 临时把 Pool 的初始化参数放到这里。
    // Pool 构造函数会从 Factory 读取这些参数。
    Parameters public override parameters;
    // 把两个 token 按地址大小排序。
    function sortToken(
        address tokenA,
        address tokenB
    ) private pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
    // 查询某一对 token 的第 index 个 Pool
    function getPool(
        address tokenA,
        address tokenB,
        uint32 index
    ) external view override returns (address) {
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "ZERO_ADDRESS");

        // Declare token0 and token1
        address token0;
        address token1;

        (token0, token1) = sortToken(tokenA, tokenB);

        return pools[token0][token1][index];
    }

    function createPool(
        address tokenA,
        address tokenB,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee
    ) external override returns (address pool) {
        // validate token's individuality
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");

        // Declare token0 and token1
        address token0;
        address token1;

        // sort token, avoid the mistake of the order
        (token0, token1) = sortToken(tokenA, tokenB);

        // get current all pools
        address[] memory existingPools = pools[token0][token1];

        // check if the pool already exists
        //  已有 Pool 的配置
        //         ↓
        // tickLower 一样吗？
        //         +
        // tickUpper 一样吗？
        //         +
        // fee 一样吗？
        //         ↓
        // 三个都一样
        for (uint256 i = 0; i < existingPools.length; i++) {
            IPool currentPool = IPool(existingPools[i]);

            if (
                currentPool.tickLower() == tickLower &&
                currentPool.tickUpper() == tickUpper &&
                currentPool.fee() == fee
            ) {
                return existingPools[i]; //  返回Pool 的地址
            }
        }

        // save pool info
        // 先把创建 Pool 所需要的参数保存到 Factory 的 parameters。
        parameters = Parameters(
            address(this),
            token0,
            token1,
            tickLower,
            tickUpper,
            fee
        );

        // generate create2 salt
        // 因此相同参数会得到相同的 CREATE2 地址。
        bytes32 salt = keccak256(
            abi.encode(token0, token1, tickLower, tickUpper, fee)
        );

        // create pool
        // 使用 CREATE2 创建 Pool。
        pool = address(new Pool{salt: salt}());

        // save created pool
        pools[token0][token1].push(pool);

        // delete pool info
        // Pool 已经创建完成，
        // Factory 中临时保存的 parameters 不再需要。
        delete parameters;

        emit PoolCreated(
            token0,
            token1,
            uint32(existingPools.length),
            tickLower,
            tickUpper,
            fee,
            pool
        );
    }
}
