// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/ISwapRouter.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IPoolManager.sol";

contract SwapRouter is ISwapRouter {
    IPoolManager public poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }
     // 解析合约调用失败时返回的错误数据，区分正常报价数据和真正的错误信息
    /// @dev Parses a revert reason that should contain the numeric quote
    function parseRevertReason(
        bytes memory reason
    ) private pure returns (int256, int256) {
        // 如果返回数据长度不是 64 字节，说明它不是预期的报价数据
        if (reason.length != 64) {
             // 长度小于 68 字节，无法满足标准 Error(string) 错误数据的基本长度要求
            if (reason.length < 68) revert("Unexpected error");
            //  assembly 不是对象，而是 Solidity 的关键字，用于编写内联汇编代码
            assembly {
               // 跳过前 4 字节的错误选择器，解析后面的字符串错误信息
            //    add(reason, 0x04)：将 reason 的内存指针向后移动 4 字节。赋值给 reason
                reason := add(reason, 0x04)
            }
             // 还原原始错误信息，并重新抛出
            revert(abi.decode(reason, (string)));
        }
        // 如果长度恰好为 64 字节，则将数据解析为两个 int256 数值
        // 这两个数值分别代表 amount0Delta 和 amount1Delta
        return abi.decode(reason, (int256, int256));
    }
    // 调用指定的 Pool 执行代币交换，并处理交换结果或异常数据
    // 假设 pool.swap() 执行成功，返回：
    // return (100, -200);
    // 第二步：自动接收返回值
    // returns (int256 _amount0, int256 _amount1)
    // 相当于自动完成：
    // _amount0 = 100;
    // _amount1 = -200;
    function swapInPool(
        IPool pool,                     // 要执行交换的资金池合约
        address recipient,               // 兑换所得代币的接收地址
        bool zeroForOne,                 // true：token0 换 token1；false：token1 换 token0
        int256 amountSpecified,          // 指定交换数量：正数表示指定输入，负数表示指定输出
        uint160 sqrtPriceLimitX96,       // 交换过程中允许达到的价格边界
        bytes calldata data              // 传递给 Pool 的附加数据，供 swapCallback 使用
    ) external returns (int256 amount0, int256 amount1) {
        try
            pool.swap(
                recipient,
                zeroForOne,
                amountSpecified,
                sqrtPriceLimitX96,
                data
            )
        // returns：声明返回值。 returns 是声明，return 是返回。
        // return：真正把结果返回出去。
        returns (int256 _amount0, int256 _amount1) {
            return (_amount0, _amount1);
        } catch (bytes memory reason) {
            return parseRevertReason(reason);
        }
    }
// 用户指定投入多少代币，Router 找到对应的 Pool 执行兑换，累计实际获得的代币数量，最后检查滑点是否超出限制。
// 一句话记住业务流程
// 准备输入 → 查找 Pool → 执行兑换 → 统计输入和输出 → 检查滑点 → 返回结果。
// 举个例子：用户准备投入 100 个 Token A，兑换 Token B。
// Pool 实际消耗 98 个 A，换得 195 个 B，那么 amountIn 剩余 2，amountOut 累计为 195。
    function exactInput(
        ExactInputParams calldata params
    ) external payable override returns (uint256 amountOut) {
        // 记录确定的输入 token 的 amount  
         // 1. 记录用户准备投入的代币数量
        uint256 amountIn = params.amountIn;

        // 根据 tokenIn 和 tokenOut 的大小关系，确定是从 token0 到 token1 还是从 token1 到 token0
        // 根据代币地址排序，确定交换方向：token0 → token1 或 token1 → token0
        //  在 Uniswap V3 这类设计中，创建 Pool 时会按照地址大小对两个代币进行排序：
        // - 地址较小的代币是 token0
        // - 地址较大的代币是 token1
        // 因此，只需要比较 tokenIn 和 tokenOut 的地址，就可以确定交换方向。
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // 遍历指定的每一个 pool
        // 2. 遍历指定的 Pool，逐个执行兑换
        for (uint256 i = 0; i < params.indexPath.length; i++) {
            // 根据代币对和费率索引，查找对应的 Pool
            address poolAddress = poolManager.getPool(
                params.tokenIn,
                params.tokenOut,
                params.indexPath[i]
            );

            // 如果 pool 不存在，则抛出错误
            require(poolAddress != address(0), "Pool not found");

            // 获取 pool 实例
            IPool pool = IPool(poolAddress);

            // 构造 swapCallback 函数需要的参数
            // 打包回调所需信息：代币地址、费率索引、付款人
           // recipient 为 0 表示报价模拟，此时 payer 也设为 0
            bytes memory data = abi.encode(
                params.tokenIn,
                params.tokenOut,
                params.indexPath[i],
                params.recipient == address(0) ? address(0) : msg.sender
            );

            // 调用 pool 的 swap 函数，进行交换，并拿到返回的 token0 和 token1 的数量
            // 调用 Pool 执行兑换，获取两种代币的数量变化
            // amount0 和 amount1 分别表示：这次兑换中，Token0 和 Token1 的数量变化。
            // 假设用户用 100 个 Token0 兑换 Token1，最终获得 200 个 Token1。
            // 变量	返回值	含义
            // amount0	100	 Pool 收到 100 个 Token0
            // amount1	-200	Pool 支出 200 个 Token1
            (int256 amount0, int256 amount1) = this.swapInPool(
                pool,
                params.recipient,
                zeroForOne,
                int256(amountIn),
                params.sqrtPriceLimitX96,
                data
            );

            // 更新 amountIn 和 amountOut
            // 扣除本次实际消耗的输入代币，得到剩余输入数量
            // amountIn 表示本次兑换中，输入代币还剩余多少没有被消耗。
            amountIn -= uint256(zeroForOne ? amount0 : amount1);
            // 累加本次获得的输出代币数量
            //  amountOut 表示用户通过兑换，实际获得的输出代币总数量。
            //  - 如果 zeroForOne == true，取 -amount1，因为输出的是 Token1。
            // - 如果 zeroForOne == false，取 -amount0，因为输出的是 Token0。
            // 为什么要加负号？因为 Pool 的约定是：流出 Pool 的代币数量为负数，而用户获得的数量需要用正数表示。
            amountOut += uint256(zeroForOne ? -amount1 : -amount0);

            // 如果 amountIn 为 0，表示交换完成，跳出循环
            // 返回实际获得的输出代币数量
            if (amountIn == 0) {
                break;
            }
        }

        // 如果交换到的 amountOut 小于指定的最少数量 amountOutMinimum，则抛出错误
        require(amountOut >= params.amountOutMinimum, "Slippage exceeded");

         // 4. 记录本次兑换结果
        emit Swap(msg.sender, zeroForOne, params.amountIn, amountIn, amountOut);

        // 返回实际获得的输出代币数量
        return amountOut;
    }
    //   变量	        exactInput()            	exactOutput()
    // amountIn	    剩余未消耗的输入代币数量	  累计需要支付的输入代币数量
    // amountOut	累计获得的输出代币数量	      尚未完成的目标输出数量
    // 用户指定想获得多少代币，Router 调用 Pool 执行兑换，计算需要支付多少输入代币，并检查是否超过最大限额。
    // 业务流程： 确定目标输出数量 → 查找 Pool → 执行兑换 → 累计输入成本 → 检查最大支出 → 返回所需输入量。
    function exactOutput(
        ExactOutputParams calldata params
    ) external payable override returns (uint256 amountIn) {
        // 记录确定的输出 token 的 amount
        // 记录用户想获得的输出代币数量
        uint256 amountOut = params.amountOut;

        // 根据 tokenIn 和 tokenOut 的大小关系，确定是从 token0 到 token1 还是从 token1 到 token0
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // 遍历指定的每一个 pool
        for (uint256 i = 0; i < params.indexPath.length; i++) {
            address poolAddress = poolManager.getPool(
                params.tokenIn,
                params.tokenOut,
                params.indexPath[i]
            );

            // 如果 pool 不存在，则抛出错误
            require(poolAddress != address(0), "Pool not found");

            // 获取 pool 实例
            IPool pool = IPool(poolAddress);

            // 构造 swapCallback 函数需要的参数
            bytes memory data = abi.encode(
                params.tokenIn,
                params.tokenOut,
                params.indexPath[i],
                params.recipient == address(0) ? address(0) : msg.sender
            );

            // 调用 pool 的 swap 函数，进行交换，并拿到返回的 token0 和 token1 的数量
            // amount0 和 amount1 表示：本次兑换时，Token0 和 Token1 各自的数量变化。
            // amount0 = 100：表示本次需要支付的输入代币数量。
            // amount1 = -200：表示本次获得的输出代币数量，负号表示代币从 Pool 流出。
            (int256 amount0, int256 amount1) = this.swapInPool(
                pool,
                params.recipient,
                zeroForOne,
                -int256(amountOut),
                params.sqrtPriceLimitX96,
                data
            );

            // 更新还差多少输出代币，以及累计需要支付多少输入代币。
            //amountOut 尚未完成的目标输出数量
            // 假设 zeroForOne == true，即 Token0 换 Token1。
            // Pool 返回：
            // amount0 = 100;    // Pool 收到 100 个 Token0
            // amount1 = -200;   // Pool 支出 200 个 Token1
            // 假设 zeroForOne == false，也就是 Token1 换 Token0。
            // 假设用户想获得 200 个 Token0，需要支付 100 个 Token1
            // amount0 = -200;  // Pool 支出 200 个 Token0
            // amount1 = 100;   // Pool 收到 100 个 Token1
            amountOut -= uint256(zeroForOne ? -amount1 : -amount0);
            //amountIn 累计需要支付的输入代币数量
            amountIn += uint256(zeroForOne ? amount0 : amount1);

            // 如果 amountOut 为 0，表示交换完成，跳出循环
            if (amountOut == 0) {
                break;
            }
        }

        // 如果交换到指定数量 tokenOut 消耗的 tokenIn 数量超过指定的最大值，报错
        require(amountIn <= params.amountInMaximum, "Slippage exceeded");

        // 发射 Swap 事件
        emit Swap(
            msg.sender,
            zeroForOne,
            params.amountOut,
            amountOut,
            amountIn
        );

        // 返回交换后的 amountIn
        return amountIn;
    }

// 对比	          exactInput()	                   quoteExactInput()
// 目的	         实际执行代币兑换	                查询预计能兑换多少代币
// 输入参数	      ExactInputParams              	QuoteExactInputParams
// 接收地址	      指定实际接收者	                 设置为 address(0)
// 最低输出限制	  可以设置实际的最低输出数量        	设置为 0
// 返回值	      实际兑换得到的输出数量	          设计上用于返回报价数量
 // 报价，指定 tokenIn 的数量和 tokenOut 的最小值，返回 tokenOut 的实际数量
// 给定输入代币数量，模拟兑换过程，计算大约能得到多少输出代币 amountOut。
    function quoteExactInput(
        QuoteExactInputParams calldata params
    ) external override returns (uint256 amountOut) {
        // 因为没有实际 approve，所以这里交易会报错，我们捕获错误信息，解析需要多少 token

        return
            this.exactInput(
                ExactInputParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    indexPath: params.indexPath,
                    recipient: address(0),
                    deadline: block.timestamp + 1 hours,
                    amountIn: params.amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            );
    }

    // 报价，指定 tokenOut 的数量和 tokenIn 的最大值，返回 tokenIn 的实际数量
    function quoteExactOutput(
        QuoteExactOutputParams calldata params
    ) external override returns (uint256 amountIn) {
        return
            this.exactOutput(
                ExactOutputParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    indexPath: params.indexPath,
                    recipient: address(0),
                    deadline: block.timestamp + 1 hours,
                    amountOut: params.amountOut,
                    amountInMaximum: type(uint256).max,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            );
    }

    function swapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        // transfer token
        (address tokenIn, address tokenOut, uint32 index, address payer) = abi
            .decode(data, (address, address, uint32, address));
        address _pool = poolManager.getPool(tokenIn, tokenOut, index);

        // 检查 callback 的合约地址是否是 Pool
        require(_pool == msg.sender, "Invalid callback caller");

        uint256 amountToPay = amount0Delta > 0
            ? uint256(amount0Delta)
            : uint256(amount1Delta);
        // payer 是 address(0)，这是一个用于预估 token 的请求（quoteExactInput or quoteExactOutput）
        // 参考代码 https://github.com/Uniswap/v3-periphery/blob/main/contracts/lens/Quoter.sol#L38
        if (payer == address(0)) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amount0Delta)
                mstore(add(ptr, 0x20), amount1Delta)
                revert(ptr, 64)
            }
        }

        // 正常交易，转账给交易池
        if (amountToPay > 0) {
            IERC20(tokenIn).transferFrom(payer, _pool, amountToPay);
        }
    }
}
