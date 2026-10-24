// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./libraries/LiquidityAmounts.sol";
import "./libraries/TickMath.sol";
import "./libraries/FixedPoint128.sol";

import "./interfaces/IPositionManager.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IPoolManager.sol";

// 这段 PositionManager 可以把它理解成一个 “LP 流动性仓库管理员 + NFT 凭证管理器”
// PositionManager 就是帮用户管理 Uniswap V3 风格 LP 仓位的“中介”：负责开仓、撤流动性、领本金和手续费，并用 NFT 代表这笔仓位。
contract PositionManager is IPositionManager, ERC721 {
    // 保存 PoolManager 合约地址
    IPoolManager public poolManager;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private _nextId = 1;

    constructor(address _poolManger) ERC721("MetaNodeSwapPosition", "MNSP") {
        poolManager = IPoolManager(_poolManger);
    }

    // 用一个 mapping 来存放所有 Position 的信息
    mapping(uint256 => PositionInfo) public positions;

    // 获取全部的 Position 信息
    function getAllPositions()
        external
        view
        override
        returns (PositionInfo[] memory positionInfo)
    {
        positionInfo = new PositionInfo[](_nextId - 1);
        for (uint32 i = 0; i < _nextId - 1; i++) {
            positionInfo[i] = positions[i + 1];
        }
        return positionInfo;
    }

    function getSender() public view returns (address) {
        return msg.sender;
    }

    function _blockTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }

    modifier checkDeadline(uint256 deadline) {
        require(_blockTimestamp() <= deadline, "Transaction too old");
        _;
    }
//  mint()：创建 LP 仓位
// 用户提供两种 Token，合约计算能提供多少流动性，调用 Pool 登记仓位，再给用户铸造一个 NFT 作为凭证。
    function mint(
        MintParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (
            uint256 positionId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        // mint 一个 NFT 作为 position 发给 LP
        // NFT 的 tokenId 就是 positionId
        // 通过 MintParams 里面的 token0 和 token1 以及 index 获取对应的 Pool
        // 调用 poolManager 的 getPool 方法获取 Pool 地址
          // 第一步：获取对应的 Pool 合约地址。
        address _pool = poolManager.getPool(
            params.token0,
            params.token1,
            params.index
        );
        // 将 Pool 合约地址转换为 IPool 接口类型，
        // 后续就可以通过 pool 调用 Pool 合约的方法。
        IPool pool = IPool(_pool);

        // 通过获取 pool 相关信息，结合 params.amount0Desired 和 params.amount1Desired 计算这次要注入的流动性

       // 第二步：获取 Pool 当前的价格和流动性价格区间。
       // sqrtPriceX96：当前价格的平方根，采用 Q96 定点数格式。
        uint160 sqrtPriceX96 = pool.sqrtPriceX96();
        // 获取流动性区间下限对应的平方根价格。
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(pool.tickLower());
          // 获取流动性区间上限对应的平方根价格。
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(pool.tickUpper());
        // 第三步：根据当前价格、价格区间以及用户希望投入的两种 Token 数量，
            // 计算本次可以提供多少流动性。
            //
            // 注意：amount0Desired 和 amount1Desired 是用户愿意投入的最大数量，
            // 不一定会全部使用。
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            params.amount0Desired,
            params.amount1Desired
        );

        // data 是 mint 后回调 PositionManager 会额外带的数据
        // 需要 PoistionManger 实现回调，在回调中给 Pool 打钱

        // 第四步：准备回调所需的数据。
        // Pool 在执行 mint 时，会回调 PositionManager 的 mintCallback()。
        // 这里把 Token 地址、Pool 索引和付款人地址编码起来，
        // 供回调函数解码使用。
        bytes memory data = abi.encode(
            params.token0,
            params.token1,
            params.index,
            msg.sender
        );
        // 告诉 Pool：“我要在这个价格区间增加一笔流动性，请给我登记这笔 LP 仓位，并告诉我需要交多少 Token。”
        // 第五步：向 Pool 注册这笔流动性。
        //
        // 第一个参数 address(this)：将底层 Pool 仓位记在 PositionManager 名下，
        // 而不是直接记在最终用户名下。
        //
        // 第二个参数 liquidity：本次要添加的流动性数量。
        //
        // 第三个参数 data：传递给 mintCallback() 的付款信息。
        //
        // 返回值 amount0、amount1：本次实际需要支付的 Token 数量。
        (amount0, amount1) = pool.mint(address(this), liquidity, data);
        // 第六步：给用户铸造 NFT 仓位凭证。
            //
            // positionId 就是这张 NFT 的 tokenId。
            // _nextId 从 1 开始，每创建一笔仓位就递增一次。
            // NFT 发送给 params.recipient 指定的地址。
        _mint(params.recipient, (positionId = _nextId++));
        // 从 Pool 里把 PositionManager 这笔 LP 仓位的“手续费累计值”读出来，保存下来。
        // feeGrowthInside0LastX128 → Token0 的手续费累计值
        // feeGrowthInside1LastX128 → Token1 的手续费累计值
        // 第七步：读取 PositionManager 在该 Pool 中的仓位信息，
        // 获取当前已经记录的区间手续费累计值。
        // 后续可以通过“最新累计值 - 上次记录值”，
        // 计算这笔仓位新增的手续费。
        // - feeGrowthInside0LastX128：价格区间内，每单位流动性对应的 Token0 手续费累计增长值。
        // - feeGrowthInside1LastX128：价格区间内，每单位流动性对应的 Token1 手续费累计增长值。
        // 这里有三个关键点：
        // - Inside：只关注当前仓位价格区间内的手续费。
        // - Growth：累计增长值，不是实际收到的手续费数量。
        // - X128：采用 Q128 定点数格式，即用 \(2^{128}\) 作为缩放因子。
        (
            ,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            ,

        ) = pool.getPosition(address(this));
        // 把刚刚创建的这笔 LP 仓位，完整登记到 positions 账本里。
        positions[positionId] = PositionInfo({
            id: positionId,
            owner: params.recipient,
            token0: params.token0,
            token1: params.token1,
            index: params.index,
            fee: pool.fee(),
            liquidity: liquidity,
            tickLower: pool.tickLower(),
            tickUpper: pool.tickUpper(),
            tokensOwed0: 0,
            tokensOwed1: 0,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128
        });
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        address owner = ERC721.ownerOf(tokenId);
        require(_isAuthorized(owner, msg.sender, tokenId), "Not approved");
        _;
    }


   // 通过 isAuthorizedForToken 检查 positionId 是否有权限
    // 移除流动性，但是 token 还是保留在 pool 中，需要再调用 collect 方法才能取回 token
    function burn(
        uint256 positionId
    )
        external
        override
        isAuthorizedForToken(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
         // 第一步：根据 positionId 获取对应的 LP 仓位信息。
         // storage 表示直接引用链上存储中的数据，修改 position 会直接更新状态。
        PositionInfo storage position = positions[positionId];
     
        // 第二步：读取这笔仓位当前提供的流动性数量。
        uint128 _liquidity = position.liquidity;
        // 第三步：根据 Token 地址和 Pool 索引，找到对应的资金池。
        address _pool = poolManager.getPool(
            position.token0,
            position.token1,
            position.index
        );
        IPool pool = IPool(_pool);
        // 第四步：调用 Pool 移除这笔流动性。
        // amount0、amount1 表示移除流动性后应返还的两种 Token 本金。
        // 注意：这里返回数量，但 Token 尚未转给用户。
        // ● amount0：本次 burn()退回的 Token0 本金数量。
        // ● position.tokensOwed0：这笔仓位累计待领取的 Token0 总额，包含本金和手续费。
        (amount0, amount1) = pool.burn(_liquidity);

        // 计算这部分流动性产生的手续费
        // 第五步：读取 Pool 中 PositionManager 仓位的最新手续费累计值。
        // 用于计算自上次记录以来，这笔流动性产生的手续费。
        (
            ,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            ,

        ) = pool.getPosition(address(this));
        // 第六步：计算 Token0 的待领取总额。
        // 原有待领取金额 + 本次返还的本金 + 本次新增的手续费。
        //
        // 最新手续费累计值 - 上次记录的累计值 = 手续费累计增长量。
        // 乘以仓位流动性，再除以 Q128 缩放因子，得到新增手续费。
        position.tokensOwed0 +=
            uint128(amount0) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 -
                        position.feeGrowthInside0LastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );
        // 第七步：计算 Token1 的待领取总额。
        // 计算方式与 Token0 相同。
        position.tokensOwed1 +=
            uint128(amount1) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 -
                        position.feeGrowthInside1LastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );

        // 第八步：更新两种 Token 的手续费累计值快照。
        // 为后续手续费结算保存最新的基准值。
        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        // 第九步：将本仓位的流动性设置为 0，表示已移除全部流动性。
        // 本金和手续费仍记录在 tokensOwed0、tokensOwed1 中，
        // 后续需要调用 collect() 才能领取。
        position.liquidity = 0;
    }

    function collect(
        uint256 positionId,
        address recipient
    )
        external
        override
        isAuthorizedForToken(positionId)
        returns (uint256 amount0, uint256 amount1)
    {
        // 通过 isAuthorizedForToken 检查 positionId 是否有权限
        // 调用 Pool 的方法给 LP 退流动性
        PositionInfo storage position = positions[positionId];
        address _pool = poolManager.getPool(
            position.token0,
            position.token1,
            position.index
        );
        IPool pool = IPool(_pool);
        (amount0, amount1) = pool.collect(
            recipient,
            position.tokensOwed0,
            position.tokensOwed1
        );

        // position 已经彻底没用了，销毁
        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        if (position.liquidity == 0) {
            _burn(positionId);
        }
    }

    function mintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        // 检查 callback 的合约地址是否是 Pool
        (address token0, address token1, uint32 index, address payer) = abi
            .decode(data, (address, address, uint32, address));
        address _pool = poolManager.getPool(token0, token1, index);
        require(_pool == msg.sender, "Invalid callback caller");

        // 在这里给 Pool 打钱，需要用户先 approve 足够的金额，这里才会成功
        if (amount0 > 0) {
            IERC20(token0).transferFrom(payer, msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).transferFrom(payer, msg.sender, amount1);
        }
    }
}
