// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

/**
 * @title IUni
 * @notice Uniswap V2 风格的接口集合，供 DexRouter 与 V2 类 DEX（Uniswap V2 / PancakeSwap / SushiSwap 等）交互。
 * @dev 注意：本接口混合了【Router】与【Pair（交易对池子）】两类方法：
 *        - swapExactTokensForTokens 属于 Router（高层入口，自动按 path 多跳）；
 *        - swap / getReserves / token0 / token1 / sync 属于 Pair（单个池子的底层方法）。
 *      本仓库的 unxswap（对接 Uniswap V2 类 DEX 的 gas 优化兑换实现，见 UnxswapRouter.sol）
 *      直接与 Pair 池子交互：其 pools[] 中编码的是 Pair 池子地址，绕过高层 Router，
 *      通过 token0 / token1 / getReserves 等底层方法读取池子信息，故这些方法是关键。
 *      （"unxswap" 是本项目对 "Uniswap V2 类兑换" 的内部命名；对应还有处理 V3 集中流动性池的 unxswapV3。）
 *      约定：每个 V2 Pair 按 token 地址大小排序两种资产，地址较小者为 token0，较大者为 token1。
 */
interface IUni {
    /**
     * @notice 【Router 方法】用「精确输入数量」沿 path 兑换，要求最终输出不少于 amountOutMin。
     * @param amountIn     输入代币的精确数量
     * @param amountOutMin 可接受的最小输出数量（滑点保护下限），实际不足则整笔回滚
     * @param path         兑换路径（token 地址数组，如 [A, B, C] 表示 A→B→C 多跳）
     * @param to           输出代币的接收地址
     * @param deadline     交易截止时间戳，超时回滚
     * @return amounts     路径上每一跳的数量数组（amounts[0] 为输入量，末位为最终输出量）
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /**
     * @notice 【Pair 底层方法】对单个交易对池子执行兑换，把指定数量的 token0/token1 发给 to。
     * @dev 这是 V2 的低层接口：调用前需先把输入代币转入该 Pair，函数内部按「恒定乘积 x*y=k」校验。
     *      amount0Out / amount1Out 中通常只有一个非 0（表示希望从池子取出哪种 token、取多少）。
     *      若 data 非空，会触发对 to 的回调（flash swap 闪电兑换）；data 为空则为普通兑换。
     *
     *      【调用流程】swap 不会主动来拉款，它假设输入代币已在池子里：
     *        1. 先把「输入代币」transfer 到本 Pair 地址；
     *        2. 再调用 swap 取出「输出代币」；
     *        3. 池子读取转账后的实际余额，扣除 0.3% 手续费后校验
     *           balance0*balance1 >= reserve0*reserve1（即 k 不减少），不满足则 revert "K"。
     *
     *      【参数规律】取哪种 token 就给对应 amountXOut 填输出量，另一个填 0：
     *        - 卖 token0、买 token1 → amount0Out = 0，amount1Out = 输出量；
     *        - 卖 token1、买 token0 → amount0Out = 输出量，amount1Out = 0。
     *
     *      【两个都非 0 的边界情况】V2 源码仅要求「至少一个 > 0」，并不禁止两个都 > 0：
     *        - 池子会同时把两种代币都发给 to，再用上面的 k 校验把关；
     *        - 若未投入足够代币弥补 → 直接 revert "K"（想白拿被拦住，最常见）；
     *        - 若投入足够多使 k 不减少 → 可成功，但你付出 >= 取出（还含手续费），自己净亏、无正常兑换意义；
     *        - 该灵活性主要服务于 flash swap / 复杂套利（同时借出两种币），普通兑换永远是「一个非 0、另一个为 0」。
     * @param amount0Out 期望从池子取出的 token0 数量
     * @param amount1Out 期望从池子取出的 token1 数量
     * @param to         取出代币的接收地址（也是 flash swap 回调对象）
     * @param data       回调数据；非空则启用闪电兑换回调，空则普通兑换
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * @notice 【Pair 方法】查询池子当前两种资产的储备量及最近更新时间。
     * @dev 储备量用 uint112 存储（V2 把两个储备 + 时间戳打包进一个存储槽以省 gas）。
     *      可用于按恒定乘积公式估算兑换价格/输出量。
     * @return reserve0           token0 的储备量
     * @return reserve1           token1 的储备量
     * @return blockTimestampLast 上次储备更新所在区块的时间戳（用于 TWAP 预言机累积）
     */
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /**
     * @notice 【Pair 方法】返回池子的 token0 地址（两资产中地址较小者）。
     */
    function token0() external view returns (address);

    /**
     * @notice 【Pair 方法】返回池子的 token1 地址（两资产中地址较大者）。
     */
    function token1() external view returns (address);

    /**
     * @notice 【Pair 方法】强制把池子的储备量(reserve)同步为当前实际代币余额(balanceOf)。
     * @dev 【reserve vs balance】V2 用 reserve（合约内记录、定价 x*y=k 所依据）而非真实 balance 来定价；
     *      正常 swap / mint / burn 内部都会自动更新 reserve，故二者平时一致。
     *      sync() 的作用就是把 reserve 强制校准成当前真实 balance（即把多出的余额纳入储备）。
     *
     *      【什么时候才需要调用 sync（实践）】正常兑换/加减流动性/DexRouter 路由都【不需要】调用它，
     *      仅当「绕过正常流程改变了池子真实余额」时才用得到，主要场景：
     *        1. rebase / 弹性供应型 token 余额自动变化，导致 balance 偏离 reserve（最实际，由套利者/keeper/项目方调用）；
     *        2. 有人直接向池子转账后，想把这笔「游离资金」纳入储备（或改用 skim 取走）；
     *        3. 专业套利/攻击场景下对储备做精细调整（V2 用 reserve 作价格预言机的风险点之一）。
     *      对照：skim(to) 是把「balance 超出 reserve 的多余部分」转走，与 sync（收编多余部分）互为反操作。
     *      注意：sync 为 public，任何人可调；涉及 rebase / fee-on-transfer 等非标准 token 时需警惕被用于价格操纵。
     */
    function sync() external;
}
