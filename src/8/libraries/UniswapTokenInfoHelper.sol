/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CommonUtils} from "./CommonUtils.sol";
import {IUni} from "../interfaces/IUni.sol";
import {IUniV3} from "../interfaces/IUniV3.sol";

/// @title UniswapTokenInfoHelper
/// @notice Helper functions for getting fromToken and toToken from
/// encoded pools array of unxswap and uniswapV3Swap methods.
/// @dev This contract will be used in DexRouter and DexRouterExactOut. So the
/// masks are re-defined here and keep the same as in the original contracts.
/**
 * @title UniswapTokenInfoHelper - 从编码的 pools 数组中解析「源代币/目标代币」的辅助合约
 * @notice 提供工具函数，从 unxswap(V2) 与 uniswapV3Swap(V3) 方法所用的【编码 pools 数组】中
 *         反推出整条兑换路径的 fromToken（首跳输入）与 toToken（末跳输出）。
 * @dev 背景：unxswap(V2) 与 uniswapV3Swap(V3) 的 pools 数组里，每个元素并非直接给出 token，而是把
 *      「池子地址 + 方向标志 + WETH 处理标志」按位打包进一个 bytes32/uint256（见 CommonUtils 的位掩码）。
 *      本合约通过位掩码解出池子地址与方向，再调用池子的 token0()/token1() 还原出真实代币地址。
 *      它继承 CommonUtils 以复用其中的位掩码常量：
 *        V2 用 _ADDRESS_MASK / _REVERSE_MASK / _WETH_MASK；
 *        V3 用 _ADDRESS_MASK / _ONE_FOR_ZERO_MASK / _WETH_UNWRAP_MASK。
 *      ETH/WETH 处理：路径首尾若涉及原生币，会把 _WETH 占位地址转换回 _ETH（见各函数内逻辑）。
 */
abstract contract UniswapTokenInfoHelper is CommonUtils {
    /**
     * @notice 从 unxswap(Uniswap V2 风格) 的编码 pools 数组解析 fromToken 与 toToken。
     * @dev 取「首个池子」推 fromToken、「末个池子」推 toToken。
     *
     *      【pools 单个元素的位布局（bytes32 = 256 位）】
     *        ┌─────────┬─────────┬──────────────────────┬───────────────────────────┐
     *        │ bit 255 │ bit 254 │     bit 253..160      │        bit 159..0          │
     *        ├─────────┼─────────┼──────────────────────┼───────────────────────────┤
     *        │ reverse │  WETH   │       (未使用)         │     Pair 池子地址(160位)    │
     *        └─────────┴─────────┴──────────────────────┴───────────────────────────┘
     *          掩码：
     *            - bit 159..0  = _ADDRESS_MASK  → 取出该跳的 V2 Pair 池子地址
     *            - bit 255     = _REVERSE_MASK  → 交易方向：0=正向(token0→token1)，1=反向(token1→token0)
     *            - bit 254     = _WETH_MASK     → 仅末个元素有意义：置 1 表示最终把输出的 WETH 解包成 ETH
     *          注：本函数只用到 _ADDRESS_MASK / _REVERSE_MASK（取地址与方向）+ 末元素的 _WETH_MASK。
     *
     * @param sendValue 调用方是否随交易发送了原生币(ETH)；为 true 且首代币是 WETH 时，把 fromToken 视为 ETH
     * @param pools     编码后的 V2 路径数组（每个元素按上方 layout 打包了池子地址+方向+WETH 标志）
     * @return fromToken 整条路径的输入代币（首跳卖出的 token）
     * @return toToken   整条路径的输出代币（末跳买入的 token）
     */
    function _getUnxswapTokenInfo(
        bool sendValue,
        bytes32[] calldata pools
    ) internal view returns (address fromToken, address toToken) {
        require(pools.length > 0, "pools must be greater than 0");

        // —— 解析 fromToken：取第一个池子 ——
        // [bit 159..0] 池子(Pair)地址：用 _ADDRESS_MASK 取低 160 位还原
        address firstPoolAddr = address(
            uint160(uint256(pools[0]) & _ADDRESS_MASK)
        );
        // default: token0 to token1; reverse: token1 to token0
        // [bit 255] 方向标志(_REVERSE_MASK)：0=正向(token0→token1)，1=反向(token1→token0)
        bool firstReversed = (uint256(pools[0]) & _REVERSE_MASK) != 0;
        // 正向时输入是 token0；反向时输入是 token1
        fromToken = firstReversed
            ? IUni(firstPoolAddr).token1()
            : IUni(firstPoolAddr).token0();
        // 若输入是 WETH 且本次随交易发了原生币 → 对外语义上视为 ETH（用 _ETH 占位）
        if (fromToken == _WETH && sendValue) {
            fromToken = _ETH;
        }

        // —— 解析 toToken：取最后一个池子 ——
        bytes32 lastPool = pools[pools.length - 1];
        // [bit 159..0] 池子地址
        address lastPoolAddr = address(
            uint160(uint256(lastPool) & _ADDRESS_MASK)
        );
        // [bit 255] 方向标志(_REVERSE_MASK)：0=正向，1=反向
        bool lastReversed = (uint256(lastPool) & _REVERSE_MASK) != 0;
        // 末跳的「输出」与方向相反：正向(0)输出 token1，反向(1)输出 token0
        toToken = lastReversed
            ? IUni(lastPoolAddr).token0()
            : IUni(lastPoolAddr).token1();
        // [bit 254] _WETH_MASK：置 1 表示最终需把 WETH 解包成 ETH 给用户
        bool isWeth = (uint256(lastPool) & _WETH_MASK) != 0; // unwrap weth to eth eventually
        if (toToken == _WETH && isWeth) {
            toToken = _ETH;
        }
    }

    /**
     * @notice 从 uniswapV3Swap(Uniswap V3 风格) 的编码 pools 数组解析 fromToken 与 toToken。
     * @dev 取「首个池子」推 fromToken、「末个池子」推 toToken。与 V2 布局类似，但方向标志改用 V3 语义的
     *      _ONE_FOR_ZERO_MASK(bit255)，且末跳解包标志用 _WETH_UNWRAP_MASK(bit253，而非 V2 的 bit254)。
     *
     *      【pools 单个元素的位布局（uint256 = 256 位）】
     *        ┌─────────┬─────────┬──────────────────────┬───────────────────────────┐
     *        │ bit 255 │ bit 253 │   其余高位(未使用)      │        bit 159..0          │
     *        ├─────────┼─────────┼──────────────────────┼───────────────────────────┤
     *        │ 1for0   │ unwrap  │       (未使用)         │     V3 Pool 池子地址(160位) │
     *        └─────────┴─────────┴──────────────────────┴───────────────────────────┘
     *          掩码：
     *            - bit 159..0  = _ADDRESS_MASK       → 取出该跳的 V3 Pool 池子地址
     *            - bit 255     = _ONE_FOR_ZERO_MASK  → 交易方向：0=zeroForOne(token0→token1)，1=oneForZero(token1→token0)
     *            - bit 253     = _WETH_UNWRAP_MASK   → 仅末个元素有意义：置 1 表示最终把输出的 WETH 解包成 ETH
     *          注：本函数只用到 _ADDRESS_MASK / _ONE_FOR_ZERO_MASK（取地址与方向）+ 末元素的 _WETH_UNWRAP_MASK。
     *          与 V2 的差异：方向位语义不同(zeroForOne vs reverse)；解包标志位 V3 在 bit253、V2 在 bit254。
     *
     * @param sendValue 是否随交易发送了原生币(ETH)；为 true 且首代币是 WETH 时，把 fromToken 视为 ETH
     * @param pools     编码后的 V3 路径数组（每个元素 uint256，按上方 layout 打包池子地址+方向+解包标志）
     * @return fromToken 整条路径的输入代币
     * @return toToken   整条路径的输出代币
     */
    function _getUniswapV3TokenInfo(
        bool sendValue,
        uint256[] calldata pools
    ) internal view returns (address fromToken, address toToken) {
        require(pools.length > 0, "pools must be greater than 0");

        // —— 解析 fromToken：取第一个池子 ——
        // [bit 159..0] 池子地址：用 _ADDRESS_MASK 取低 160 位还原
        address firstPoolAddr = address(uint160(pools[0] & _ADDRESS_MASK));
        // [bit 255] 方向标志(_ONE_FOR_ZERO_MASK)：为 0=zeroForOne(token0→token1)，为 1=oneForZero(token1→token0)
        bool firstZeroForOne = (pools[0] & _ONE_FOR_ZERO_MASK) == 0;
        fromToken = firstZeroForOne
            ? IUniV3(firstPoolAddr).token0()
            : IUniV3(firstPoolAddr).token1();
        if (fromToken == _WETH && sendValue) {
            fromToken = _ETH;
        }

        // —— 解析 toToken：取最后一个池子 ——
        uint256 lastPool = pools[pools.length - 1];
        // [bit 159..0] 池子地址
        address lastPoolAddr = address(uint160(lastPool & _ADDRESS_MASK));
        // [bit 255] 方向标志(_ONE_FOR_ZERO_MASK)：0=zeroForOne，1=oneForZero
        bool lastZeroForOne = (lastPool & _ONE_FOR_ZERO_MASK) == 0;
        // 末跳输出与方向相反：zeroForOne 输出 token1，否则输出 token0
        toToken = lastZeroForOne
            ? IUniV3(lastPoolAddr).token1()
            : IUniV3(lastPoolAddr).token0();
        // [bit 253] _WETH_UNWRAP_MASK：置 1 表示最终需把 WETH 解包成 ETH 给用户
        bool unwrapWeth = (lastPool & _WETH_UNWRAP_MASK) != 0; // unwrap weth to eth eventually
        if (toToken == _WETH && unwrapWeth) {
            toToken = _ETH;
        }
    }
}
