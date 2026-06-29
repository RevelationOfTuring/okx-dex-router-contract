// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

/**
 * @title IUniV3
 * @notice Uniswap V3 Pool 的核心接口，供 DexRouter 的 unxswapV3 实现与 V3 类池子交互。
 * @dev 【V3 与 V2 的关键区别】
 *      - V2：流动性均匀分布在 (0, ∞) 整个价格区间，定价用恒定乘积 x*y=k、储备 reserve；
 *      - V3：流动性可【集中】在某个价格区间（ticks）内，资金效率更高；价格用 sqrtPriceX96 表示，
 *            位置用 tick 表示，手续费分多档（0.05% / 0.3% / 1% 等）。
 *      因此 V3 没有 getReserves，取而代之的是 slot0（当前价格/tick 等状态）。
 *
 * @dev 【两个核心编码概念】
 *      - sqrtPriceX96：把「价格的平方根」用 Q64.96 定点格式存储（即 sqrt(price) * 2^96）。
 *        用平方根 + 定点是为了在 tick 数学中避免溢出、提升精度。price = (sqrtPriceX96 / 2^96)^2，
 *        含义为 token1/token0 的价格。
 *      - tick：价格的离散对数刻度，每个 tick 对应价格变化 0.01%（1.0001^tick = price）。
 *        流动性区间的边界、当前价格位置都用 tick 表示。
 *
 * @dev 【方法归属】本接口的所有方法（swap / slot0 / token0 / token1 / fee）均属于
 *      【UniswapV3Pool（V3 核心池子合约）】。注意与 V2 的 IUni 不同：IUni 混入了 Router 方法，
 *      而本接口是纯粹的 Pool 接口，不含 V3 外围的 SwapRouter / PositionManager 等合约的方法。
 *      DexRouter 的 unxswapV3 直接与 Pool 交互（底层 swap + 回调付款），故这里只需 Pool 接口。
 */
interface IUniV3 {
    /**
     * @notice 【Pool 方法】在 V3 池子上执行兑换（底层方法）。
     * @dev 与 V2 不同，V3 的 swap 采用「回调付款」模式：池子先把输出代币发给 recipient，
     *      然后回调调用方的 uniswapV3SwapCallback()，调用方必须在回调里把输入代币转给池子，
     *      否则交易因 k/余额校验失败而 revert。data 会原样透传给回调，用于识别/校验。
     *
     *      【uniswapV3SwapCallback 由谁实现】池子回调的对象是 msg.sender（即直接调用 swap 的合约），
     *      而【不是】recipient。因此「谁调用 pool.swap()，谁就必须实现 uniswapV3SwapCallback」：
     *        - 普通用户的「正常 swap」：经官方 SwapRouter 调池子，回调由 SwapRouter 实现，用户无感；
     *        - 本项目：DexRouter（见 UnxswapV3Router.sol 的 uniswapV3SwapCallback）直接调 pool.swap，
     *          故回调由本 Router 自己实现，在回调里把输入代币转给池子；
     *        - EOA（普通钱包）无法直接调用 pool.swap，因为它没有代码、无法实现回调函数——
     *          这是 V3「回调付款」模式的硬性约束：底层 swap 只能由合约发起。
     *      安全提示：池子写死回调 msg.sender；回调实现方则必须在回调内校验 msg.sender 确为合法池子，
     *      防止他人伪造调用回调骗取代币。
     * @param recipient         兑换输出代币的接收地址
     * @param zeroForOne        交易方向：true = token0 换 token1（价格下行）；false = token1 换 token0（价格上行）
     * @param amountSpecified   指定数量；为正表示「精确输入(exact input)」，为负表示「精确输出(exact output)」
     * @param sqrtPriceLimitX96 价格限制（Q64.96 平方根价格）：swap 过程中价格不会越过此限制，用于滑点/方向保护
     * @param data              透传给 uniswapV3SwapCallback 的回调数据（用于在回调中支付输入代币）
     * @return amount0          本次 swap 池子 token0 的净变化量（带符号：正=池子收到，负=池子付出）
     * @return amount1          本次 swap 池子 token1 的净变化量（带符号，含义同上）
     */
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /**
     * @notice 【Pool 方法】返回池子的核心状态槽 slot0（V3 把多个高频读取字段打包进一个存储槽以省 gas）。
     * @dev 取代了 V2 的 getReserves，用于读取当前价格、tick 及预言机/手续费等状态。
     *
     *      【sqrtPriceX96 与 tick 的关系】二者描述【同一个当前价格】，但精度/形态不同：
     *        - sqrtPriceX96：连续、精确的当前价格（Q64.96 定点），price = (sqrtPriceX96 / 2^96)^2；
     *        - tick：离散整数刻度，是当前价格【向下取整】到的 tick（即"包含当前价格的 tick 区间的下边界"）。
     *        不变式：getSqrtRatioAtTick(tick) <= sqrtPriceX96 < getSqrtRatioAtTick(tick + 1)
     *               理论换算 tick = floor( log_{1.0001}( price ) )。
     *        因此 tick 只在价格【跨越整数 tick 边界】时才跳变，sqrtPriceX96 则随 swap 平滑变化；
     *        通常 getSqrtRatioAtTick(slot0.tick) <= slot0.sqrtPriceX96（仅价格恰落在 tick 边界时相等）。
     *        用途区分：需精确价格/算 swap 输出 → 用 sqrtPriceX96；判断流动性区间、预言机累积 → 用 tick。
     *        二者都存进 slot0 是为省 gas（避免从 sqrtPriceX96 反算 tick 的 log 运算）。
     *
     *      【内置 TWAP 预言机详解（observationIndex / Cardinality / CardinalityNext 三者配合）】
     *        V3 池子内置价格预言机，记录历史价格观测点(observations)以计算 TWAP（时间加权平均价格）。
     *        用 TWAP 而非瞬时价是为了抗操纵——平均价难被闪电贷在单区块内拉偏。
     *        观测点存在一个【环形缓冲区 observations[]】中（固定大小、写满后回绕覆盖最旧的）：
     *          - observationIndex：环形缓冲区中【最近一次写入】观测点的下标（即"当前写入位置"指针）。
     *              价格变化跨区块时写新点，index 前移并对 cardinality 取模回绕：
     *              index = (index + 1) % observationCardinality。
     *          - observationCardinality：缓冲区【当前已启用】的容量（能存几个观测点）。
     *              新建池子时为 1（只够存当前价、不足以算 TWAP），需扩容后才能回溯更久历史。
     *          - observationCardinalityNext：下次写入时将【生效的目标容量】。
     *              任何人可调 increaseObservationCardinalityNext(n) 付 gas 预扩容，缓冲区随后逐步增长到该值；
     *              容量越大 → 可回溯历史越久 → 能算越长时间窗口的 TWAP。
     *        查询 TWAP（observe）时：从 observationIndex（最新点）沿环形往回找到目标时间点，
     *        用累积值之差 / 时间差得到该区间的平均 tick，再换算成 TWAP 价格。
     *
     *        【扩容流程示例】注意 cardinality 不能直接设置，只能"被动增长、只增不减"：
     *          初始（新建池子）：observationCardinality = 1，observationCardinalityNext = 1
     *          第1步：有人调用 increaseObservationCardinalityNext(5)
     *                 → observationCardinality     = 1   ← 还没变！
     *                 → observationCardinalityNext = 5   ← 已设好
     *                 → 同时预初始化 index 1~4 的槽位（付 gas）
     *          第2步：之后发生 swap 写观测点，当 index 走到当前容量的最后一格（此处 index=0）时触发扩容
     *                 → observationCardinality     = 5   ← 此刻才真正变为 5
     *                 → 此后缓冲区可存 5 个观测点，index 在 0~4 之间回绕
     *        为何延迟到"用满一圈"才提升 cardinality：回绕/查找都依赖 cardinality 判断哪些槽有效；
     *        若在第1步立刻改成 5，而 index 3~4 尚未写入真实数据，回绕会跳到空槽、TWAP 查找会读到无效点而出错。
     *        故拆成两步：先 grow 预初始化新槽（建好房间），等 index 平滑走到新区域时才启用新容量。
     *
     *      【feeProtocol 详解】协议手续费比例：swap 手续费中归 Uniswap 协议（DAO 金库）、而非 LP 的部分。
     *        - 它是 uint8，但【打包了两个方向的设置】：高 4 位 = token1 方向，低 4 位 = token0 方向。
     *            feeProtocol0 = feeProtocol % 16（低4位，token0→token1 方向）
     *            feeProtocol1 = feeProtocol >> 4（高4位，token1→token0 方向）
     *        - 每个 4 位值 n 表示「协议拿走 swap 总手续费的 1/n」（注意是手续费的几分之一，不是交易额）；
     *          有效取值为 0 或 4~10，即「协议费关闭」或「抽成 10%~25%」，不允许更高比例。
     *        - n=0 → 协议不抽成，手续费全归 LP（V3 长期的默认状态）。
     *        例：fee=0.3% 且 feeProtocol=0x44（两方向都为 4=1/4）时，1000 token0 的 swap 手续费 3 token0 中，
     *            协议拿 3*(1/4)=0.75，LP 得 2.25。
     *        - 由治理经 setFeeProtocol 设置；协议费先累积在 protocolFees，再由 collectProtocol 批量提取给金库。
     * @return sqrtPriceX96                当前价格的平方根（Q64.96 定点），price=(sqrtPriceX96/2^96)^2
     * @return tick                        当前价格所处的 tick（离散对数价格刻度，可为负）
     * @return observationIndex            预言机环形缓冲区中最近一次观测的索引
     * @return observationCardinality      预言机当前已启用的观测槽数量（环形缓冲区大小）
     * @return observationCardinalityNext  下一个将生效的观测槽数量（扩容预言机容量时用）
     * @return feeProtocol                 协议手续费设置（高4位 token1 / 低4位 token0，每段表示拿手续费的 1/n，详见上方 @dev）
     * @return unlocked                    重入锁标志：true 表示当前未被锁定（用于防重入）
     */
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /**
     * @notice 【Pool 方法】返回池子的 token0 地址（两资产中地址较小者）。
     */
    function token0() external view returns (address);

    /**
     * @notice 【Pool 方法】返回池子的 token1 地址（两资产中地址较大者）。
     */
    function token1() external view returns (address);

    /// @notice The pool's fee in hundredths of a bip, i.e. 1e-6
    /**
     * @notice 【Pool 方法】返回池子的手续费率，单位为「百分之一个 bip」即 1e-6（百万分之一）。
     * @dev 【单位换算】实际费率 = fee / 1_000_000（亦即 fee / 10000 = 百分比）。
     *      常见档位（标注初始/后增）：
     *        - fee=100   → 0.01%（极稳定对，如稳定币 USDC/USDT）【非初始：V3 上线时没有此档，
     *                      由 Uniswap 治理后来通过 Factory.enableFeeAmount(100, 1) 新增】
     *        - fee=500   → 0.05%（低波动对）【初始档，Factory 构造函数中写死】
     *        - fee=3000  → 0.3% （标准档，多数普通币对，等同 V2 费率）【初始档】
     *        - fee=10000 → 1%   （高波动/长尾资产对）【初始档】
     *
     *      【费率档可否自定义】不能由普通用户任意自定义：建池子时 fee 必须是【已被 Factory 启用的档位】，
     *      否则 createPool 因 feeAmountTickSpacing[fee]==0 而 revert。
     *      费率档由治理统一扩展——只有 Factory owner（治理）能调 enableFeeAmount(fee, tickSpacing) 新增全局档位
     *      （0.01% 档即如此新增），而非为单个池子定制。如此限制是为避免流动性碎片化、统一管理 tickSpacing。
     *      故代码不应硬编码"只有这 4 档"：治理可能再加新档，且不同链/不同 V3 fork 的启用档位也可能不同，
     *      应始终从池子的 fee() 读取实际值。
     *
     *      【多池子设计】这是 V3 与 V2 的关键区别：同一对 token 可同时存在【多个不同 fee 档】的独立池子
     *      （各自独立的合约、流动性与价格）。因此池子由 token0 + token1 + fee 三元组唯一确定，
     *      fee 是区分它们的关键；查池子需指定 fee，如 factory.getPool(USDC, WETH, 3000)。
     *      不同费率服务不同风险：稳定对用低费率引流，高波动对用高费率补偿 LP 的无常损失风险。
     *
     *      【其他特性】
     *        - fee 为 immutable：池子创建时确定、永不可变（想要别的费率即是另一个独立池子）；
     *        - 类型 uint24：足以容纳上限 1_000_000(=100%) 且省存储；
     *        - 每个 fee 档绑定一个 tickSpacing（费率越高间距越大）：100→1, 500→10, 3000→60, 10000→200；
     *        - swap 时按 fee/1e6 从输入额扣手续费分给 LP（及协议，见 feeProtocol）。
     *          例：fee=3000 的池子 swap 1000 USDC，手续费 = 1000*3000/1e6 = 3 USDC。
     * @return The fee 手续费率（单位 1e-6）
     */
    function fee() external view returns (uint24);
}
