// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// ERC20 标准接口：查询余额、转账等

import "./libraries/SqrtPriceMath.sol";
// 根据价格和流动性计算 Token 数量

import "./libraries/TickMath.sol";
// Tick ↔ sqrtPrice 相互转换

import "./libraries/LiquidityMath.sol";
// 流动性加减计算

import "./libraries/LowGasSafeMath.sol";
// 安全的加减法

import "./libraries/SafeCast.sol";
// 不同整数类型之间安全转换

import "./libraries/TransferHelper.sol";
// 安全转 Token

import "./libraries/SwapMath.sol";
// 计算 Swap 每一步的结果

import "./libraries/FixedPoint128.sol";
// Q128 定点数常量

import "./interfaces/IPool.sol";
// Pool 对外接口

import "./interfaces/IFactory.sol";
// Factory 接口


contract Pool is IPool {
    // Pool 合约，实现 IPool 接口

    using SafeCast for uint256;
    // uint256 可以直接使用 SafeCast 的转换方法

    using LowGasSafeMath for int256;
    // int256 使用安全数学运算

    using LowGasSafeMath for uint256;
    // uint256 使用安全数学运算

    // @inheritdoc IPool   创建这个 Pool 的 Factory 地址
    address public immutable override factory;
    // @inheritdoc IPool    定义一个名叫 token0 的地址变量，它记录 Pool 的 token0 合约地址
    address public immutable override token0;
    //  @inheritdoc IPool   交易对中的 Token1
    address public immutable override token1;
    //  @inheritdoc IPool   手续费，例如 3000 = 0.3%
    uint24 public immutable override fee;
    //  @inheritdoc IPool  这个 Pool 的最低 Tick
    int24 public immutable override tickLower;
    //  @inheritdoc IPool  这个 Pool 的最高 Tick  
    int24 public immutable override tickUpper;
    // immutable 可以简单理解为：
    // 部署时确定，之后不能修改。
    // @inheritdoc IPool   当前价格的 sqrtPrice，使用 Q96 定点数
    // 保存当前价格的平方根，但为了让 Solidity 能精确计算，把它乘以 2^96 后作为整数保存
    uint160 public override sqrtPriceX96;
    // @inheritdoc IPool  价格所在的“刻度/位置”  它不是价格本身，而是用一个整数来表示价格位置
    int24 public override tick;
    //  @inheritdoc IPool
    uint128 public override liquidity;

    // @inheritdoc IPool  全池 token0 手续费增长“里程表”
    uint256 public override feeGrowthGlobal0X128;
    // @inheritdoc IPool  全池 token1 手续费增长“里程表”
    uint256 public override feeGrowthGlobal1X128;
    // 记录一个 LP 在这个 Pool 里的“账户信息”
    struct Position {
        // 该 Position 拥有的流动性 ； 这个 LP 当前在这个 Pool 中提供了多少流动性
        uint128 liquidity;
        // 可提取的 token0 数量  这个 LP 目前已经累计、可以领取的 Token0。记录在这里 ≠ 钱已经转到 LP 钱包。
         //tokensOwed0 → 欠 LP 的 Token0
        // tokensOwed1 → 欠 LP 的 Token1
        uint128 tokensOwed0;
        // 可提取的 token1 数量
        uint128 tokensOwed1;
        // 这个 Position 上一次结算手续费时，Token0 的手续费累计值是多少。
        // 上次结算时的里程表读数
        uint256 feeGrowthInside0LastX128;
      
        uint256 feeGrowthInside1LastX128;
    }

    // 用一个 mapping 来存放所有 Position 的信息
    // 通过用户的钱包地址，找到这个用户在当前 Pool 里的 Position（仓位）信息
    // 钱包地址  →  Position仓位
    mapping(address => Position) public positions;
    // 直接访问仓位数据
    function getPosition(
        address owner
    )
        external
        view
        override
        returns (
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        return (
            positions[owner].liquidity,
            positions[owner].feeGrowthInside0LastX128,
            positions[owner].feeGrowthInside1LastX128,
            positions[owner].tokensOwed0,
            positions[owner].tokensOwed1
        );
    }
// Pool 被 Factory 创建时，通过 msg.sender 找到 Factory，再从 Factory 的 parameters() 中把自己需要的初始化参数取出来
    constructor() {
        // constructor 中初始化 immutable 的常量
        // Factory 创建 Pool 时会通 new Pool{salt: salt}() 的方式创建 Pool 合约，通过 salt 指定 Pool 的地址，这样其他地方也可以推算出 Pool 的地址
        // 参数通过读取 Factory 合约的 parameters 获取
        // 不通过构造函数传入，因为 CREATE2 会根据 initcode 计算出新地址（new_address = hash(0xFF, sender, salt, bytecode)），带上参数就不能计算出稳定的地址了
        (factory, token0, token1, tickLower, tickUpper, fee) = IFactory(
            msg.sender
        ).parameters();
    }


    // sqrtPriceX96 = 当前具体价格的数学表示
    // tick = 当前价格所在的离散价格刻度
    // getTickAtSqrtPrice() = 根据价格反查 tick。

    function initialize(uint160 sqrtPriceX96_) external override {
        require(sqrtPriceX96 == 0, "INITIALIZED");
        // 通过价格获取 tick，判断 tick 是否在 tickLower 和 tickUpper 之间
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96_);
        require(
            tick >= tickLower && tick < tickUpper,
            "sqrtPriceX96 should be within the range of [tickLower, tickUpper)"
        );
        // 初始化 Pool 的 sqrtPriceX96
        // 保存当前价格的平方根，但为了让 Solidity 能精确计算，把它乘以 2^96 后作为整数保存
        sqrtPriceX96 = sqrtPriceX96_;
    }

    // 修改一个 LP 仓位时，需要带进去的两个参数
    struct ModifyPositionParams {
        // the address that owns the position    // 持有这个仓位的人
        address owner;
        // any change in liquidity   // 流动性要增加还是减少
        int128 liquidityDelta;
    }

   // 修改 LP 仓位的总入口：先算这次需要多少 token，再结算旧手续费，最后更新流动性。
   //token0、 token1: 这次修改 LP 仓位，需要动多少 token0、多少 token1
    function _modifyPosition(
        ModifyPositionParams memory params
    ) private returns (int256 amount0, int256 amount1) {
        //1. 通过新增的流动性计算 amount0 和 amount1
        // 参考 UniswapV3 的代码

        // 根据增加/减少的流动性，计算需要多少 token0 
        // 可以理解为：这次改仓，要动多少 token0

        amount0 = SqrtPriceMath.getAmount0Delta(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickUpper),
            params.liquidityDelta
        );
        // 根据增加/减少的流动性，计算需要多少 token1 
        // 可以理解为：这次改仓，要动多少 token1
        amount1 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceX96,
            params.liquidityDelta
        );

        //2. 找到这个 LP 自己的仓位账本
        Position storage position = positions[params.owner];

        // 提取手续费，计算从上一次提取到当前的手续费
        //tokensOwed0 是   从这个 LP 上一次记录手续费的位置，到这一次调用 _modifyPosition() 的这一刻
        //3. 计算这段时间新产生的 token0 手续费 
        // 当前手续费累计值 - 上次记录的值
        // 再 × LP 的流动性 = 这次新增的手续费
        uint128 tokensOwed0 = uint128(
            FullMath.mulDiv(
                feeGrowthGlobal0X128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );
        // 3.1同理，计算新产生的 token1 手续费
        uint128 tokensOwed1 = uint128(
            FullMath.mulDiv(
                feeGrowthGlobal1X128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        // 更新提取手续费的记录，同步到当前最新的 feeGrowthGlobal0X128，代表都提取完了
        // 更新手续费“里程表” // 记录已经结算到当前这个位置
        //feeGrowthInside0LastX128: 这个 Position 上一次结算手续费时，Token0 的手续费累计值是多少
        position.feeGrowthInside0LastX128 = feeGrowthGlobal0X128;  // feeGrowthGlobal0X128 全池 token0 手续费增长“里程表”
        position.feeGrowthInside1LastX128 = feeGrowthGlobal1X128;  // feeGrowthGlobal1X128 全池 token1 手续费增长“里程表”
        // 把可以提取的手续费记录到 tokensOwed0 和 tokensOwed1 中
        // LP 可以通过 collect 来最终提取到用户自己账户上
        // 把刚刚算出来的手续费记到账本里 
        // 注意：这里只是记账，还没有真正转 token
       // 真正把钱转给 LP，要等 collect()    //tokensOwed0 → 欠 LP 的 Token0
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            position.tokensOwed0 += tokensOwed0;
            position.tokensOwed1 += tokensOwed1;
        }

        // 修改 liquidity        // 修改整个 Pool 的流动性 // liquidityDelta > 0：增加 // liquidityDelta < 0：减少
        liquidity = LiquidityMath.addDelta(liquidity, params.liquidityDelta);

        // 修改这个 LP 自己的流动性
        position.liquidity = LiquidityMath.addDelta(
            position.liquidity,
            params.liquidityDelta
        );
    }
                                                 
    /// @dev Get the pool's balance of token0  查“这个 Pool 这个智能合约地址本身现在有多少 token0”
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance0() private view returns (uint256) {
        // token0 是 token0 这个 合约的地址； token0.staticcall 调用另一个合约的函数，但是禁止修改状态
        (bool success, bytes memory data) = token0.staticcall(
            // IERC20.balanceOf 把这个地址当成 ERC20 合约使用
            // 这句是把函数调用的数据“打包成一串二进制数据”，然后交给 staticcall 去调用
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        // 把合约返回的一串原始二进制数据 data，翻译成我们想要的 uint256 数字
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }
// LP“加仓/提供流动性”的入口
// 让一个 LP 往 Pool 里添加流动性，并检查他把应该交的 token0、token1 是否真的交进来了
// 用户
//  │
//  │ mint()
//  ▼
// Pool
//  │
//  ├─ ① _modifyPosition() 
//  │     ↓
//  │   算：需要多少 token0 / token1
//  │
//  ├─ ② 记录转账前余额
//  │
//  ├─ ③ mintCallback()
//  │     ↓
//  │   用户把 token0 / token1 转进 Pool
//  │
//  ├─ ④ 检查余额
//  │     ↓
//  │   确认钱真的进来了
//  │
//  └─ ⑤ emit Mint
//        ↓
//      记录事件
//  mint 铸造  
    function mint(
        address recipient,   // 谁获得这份 LP 流动性
        uint128 amount,       // 要增加多少流动性
        bytes calldata data     // 回调时需要传给调用方的额外数据
    ) external override returns (uint256 amount0, uint256 amount1) {
         // 流动性必须大于 0，不能添加 0 流动性
        require(amount > 0, "Mint amount must be greater than 0");
        // 基于 amount 计算出当前需要多少 amount0 和 amount1 //  这次改仓，要动多少 token0
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                liquidityDelta: int128(amount)
            })
        );
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);
        // 记录转账前 Pool 里有多少 token0
        uint256 balance0Before;
        uint256 balance1Before;
        // balance0  查“这个 Pool 这个智能合约地址本身现在有多少 token0” 
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        // 回调 mintCallback   //Pool 告诉调用 mint() 的人：你把需要的 token0、token1 转给我。
        IMintCallback(msg.sender).mintCallback(amount0, amount1, data);
        // 检查用户刚才有没有把应该支付的 token0、token1 真的转进 Pool。
        // 举例： 转账前 Pool 有 100 token0
        //本次应该支付 20 token0      
        //转账后 Pool 至少应该有 120 token0
        if (amount0 > 0)
            require(balance0Before.add(amount0) <= balance0(), "M0");
        if (amount1 > 0)
            require(balance1Before.add(amount1) <= balance1(), "M1");

        emit Mint(msg.sender, recipient, amount, amount0, amount1);
    }
        // LP 来领取自己已经赚到的手续费。
    function collect(
        address recipient,   // 手续费转给谁
        uint128 amount0Requested,  // 想领取多少 token0
        uint128 amount1Requested   // 想领取多少 token1
    ) external override returns (uint128 amount0, uint128 amount1) {
        // 获取当前用户的 position  // 找到调用者自己的 LP 仓位账本
        Position storage position = positions[msg.sender];

        //  实际领取数量 = “想领的” 和 “账上有的” 取较小值
        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
             // 从账上扣掉已经领取的 token0；position.tokensOwed0 ： 可提取的 token0 数量  这个 LP 目前已经累计、可以领取的 Token0
            // token0： 定义一个名叫 token0 的地址变量，它记录 Pool 的 token0 合约地址
            position.tokensOwed0 -= amount0;
            // 真正把 token0 转给 LP
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, amount0, amount1);
    }

    function burn(
        uint128 amount
    ) external override returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "Burn amount must be greater than 0");
        require(
            amount <= positions[msg.sender].liquidity,
            "Burn amount exceeds liquidity"
        );
        // 修改 positions 中的信息
        (int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                liquidityDelta: -int128(amount)
            })
        );
        // 获取燃烧后的 amount0 和 amount1
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (
                positions[msg.sender].tokensOwed0,
                positions[msg.sender].tokensOwed1
            ) = (
                positions[msg.sender].tokensOwed0 + uint128(amount0),
                positions[msg.sender].tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, amount, amount0, amount1);
    }

    // 交易中需要临时存储的变量
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // 该交易中用户转入的 token0 的数量
        uint256 amountIn;
        // 该交易中用户转出的 token1 的数量
        uint256 amountOut;
        // 该交易中的手续费，如果 zeroForOne 是 ture，则是用户转入 token0，单位是 token0 的数量，反正是 token1 的数量
        uint256 feeAmount;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "AS");

        // zeroForOne: 如果从 token0 交换 token1 则为 true，从 token1 交换 token0 则为 false
        // 判断当前价格是否满足交易的条件
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < sqrtPriceX96 &&
                    sqrtPriceLimitX96 > TickMath.MIN_SQRT_PRICE
                : sqrtPriceLimitX96 > sqrtPriceX96 &&
                    sqrtPriceLimitX96 < TickMath.MAX_SQRT_PRICE,
            "SPL"
        );

        // amountSpecified 大于 0 代表用户指定了 token0 的数量，小于 0 代表用户指定了 token1 的数量
        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: sqrtPriceX96,
            feeGrowthGlobalX128: zeroForOne
                ? feeGrowthGlobal0X128
                : feeGrowthGlobal1X128,
            amountIn: 0,
            amountOut: 0,
            feeAmount: 0
        });

        // 计算交易的上下限，基于 tick 计算价格
        uint160 sqrtPriceX96Lower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtPriceAtTick(tickUpper);
        // 计算用户交易价格的限制，如果是 zeroForOne 是 true，说明用户会换入 token0，会压低 token0 的价格（也就是池子的价格），所以要限制最低价格不能超过 sqrtPriceX96Lower
        uint160 sqrtPriceX96PoolLimit = zeroForOne
            ? sqrtPriceX96Lower
            : sqrtPriceX96Upper;

        // 计算交易的具体数值
        (
            state.sqrtPriceX96,
            state.amountIn,
            state.amountOut,
            state.feeAmount
        ) = SwapMath.computeSwapStep(
            sqrtPriceX96,
            (
                zeroForOne
                    ? sqrtPriceX96PoolLimit < sqrtPriceLimitX96
                    : sqrtPriceX96PoolLimit > sqrtPriceLimitX96
            )
                ? sqrtPriceLimitX96
                : sqrtPriceX96PoolLimit,
            liquidity,
            amountSpecified,
            fee
        );

        // 更新新的价格
        sqrtPriceX96 = state.sqrtPriceX96;
        tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);

        // 计算手续费
        state.feeGrowthGlobalX128 += FullMath.mulDiv(
            state.feeAmount,
            FixedPoint128.Q128,
            liquidity
        );

        // 更新手续费相关信息
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        // 计算交易后用户手里的 token0 和 token1 的数量
        if (exactInput) {
            state.amountSpecifiedRemaining -= (state.amountIn + state.feeAmount)
                .toInt256();
            state.amountCalculated = state.amountCalculated.sub(
                state.amountOut.toInt256()
            );
        } else {
            state.amountSpecifiedRemaining += state.amountOut.toInt256();
            state.amountCalculated = state.amountCalculated.add(
                (state.amountIn + state.feeAmount).toInt256()
            );
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (
                amountSpecified - state.amountSpecifiedRemaining,
                state.amountCalculated
            )
            : (
                state.amountCalculated,
                amountSpecified - state.amountSpecifiedRemaining
            );

        if (zeroForOne) {
            // callback 中需要给 Pool 转入 token
            uint256 balance0Before = balance0();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");

            // 转 Token 给用户
            if (amount1 < 0)
                TransferHelper.safeTransfer(
                    token1,
                    recipient,
                    uint256(-amount1)
                );
        } else {
            // callback 中需要给 Pool 转入 token
            uint256 balance1Before = balance1();
            ISwapCallback(msg.sender).swapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");

            // 转 Token 给用户
            if (amount0 < 0)
                TransferHelper.safeTransfer(
                    token0,
                    recipient,
                    uint256(-amount0)
                );
        }


        //         谁交易
        // ↓
        // 谁收 Token
        // ↓
        // Token0 变化多少
        // ↓
        // Token1 变化多少
        // ↓
        // 交易后价格
        // ↓
        // 交易后流动性
        // ↓
        // 交易后 Tick

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            sqrtPriceX96,
            liquidity,
            tick
        );
    }
}
