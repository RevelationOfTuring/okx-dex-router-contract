// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Callback for IUniswapV3PoolActions#swap
/// @notice Any contract that calls IUniswapV3PoolActions#swap must implement this interface
/**
 * @title IUniswapV3SwapCallback - V3 swap 回调接口
 * @notice V3 的 swap 采用「回调付款」模式：【任何调用 IUniswapV3Pool.swap 的合约都必须实现本接口】。
 *         池子会在转出输出代币后回调本接口，调用方需在回调里把欠池子的输入代币补上。
 * @dev 关联机制详见 IUniV3.swap 的注释：池子回调的对象是 msg.sender（即调用 swap 的合约），
 *      而非 swap 的 recipient。本项目中由 UnxswapV3Router 实现该回调。
 *      EOA 无法实现接口、故无法直接调用 V3 swap——这是回调付款模式的硬性约束。
 */
interface IUniswapV3SwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
    /**
     * @notice 在 IUniswapV3Pool.swap 执行兑换后，由池子回调到 msg.sender（调用 swap 的合约）。
     * @dev 实现要点：
     *      1. 【必须支付】在回调内，把本次 swap 欠池子的输入代币转给池子（即 delta 为正的那一侧）；
     *         若回调结束时池子没收到足额输入代币，swap 会因余额校验失败而 revert。
     *      2. 【必须校验调用者】实现中【务必】验证 msg.sender 确为「由官方 UniswapV3Factory 部署的合法池子」，
     *         否则任何人都能伪造调用此回调、诱使本合约向其转账（典型安全漏洞）。
     *         常见校验：用 token0/token1/fee 通过 factory 推导出预期池子地址，与 msg.sender 比对。
     *      3. amount0Delta 与 amount1Delta 可能【同时为 0】（当本次没有实际兑换任何代币时）。
     *      delta 的符号约定：
     *        - 正值(positive)：池子【应收】这么多该 token —— 回调必须把这笔输入代币转给池子；
     *        - 负值(negative)：池子【已付出】这么多该 token —— 即转给 recipient 的输出代币。
     *      正常单向 swap 中，通常一侧为正（你要支付的输入）、另一侧为负（你收到的输出）。
     * @param amount0Delta swap 结束时池子在 token0 上的净变化：正=需向池子支付的 token0，负=池子已付出的 token0
     * @param amount1Delta swap 结束时池子在 token1 上的净变化：正=需向池子支付的 token1，负=池子已付出的 token1
     * @param data         由调用方在 IUniswapV3Pool.swap 调用时透传进来的任意数据（用于回调中识别/取参/校验）
     */
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}
