/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./CommonUtils.sol";
import "./SafeERC20.sol";
import "./UniversalERC20.sol";
import "../interfaces/IAdapter.sol";
import "../interfaces/IApproveProxy.sol";
import "../interfaces/IWNativeRelayer.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IERC20.sol";

/// @title Base contract with common permit handling logics
/**
 * @title CommonLib - DexRouter 的公共逻辑基类
 * @notice 在 CommonUtils（常量集合）之上，提供路由执行所需的公共内部函数：
 *         调用 adapter 执行兑换、内部转账（多种付款模式）、把代币/ETH 发还用户、错误冒泡等。
 * @dev 继承链：CommonUtils → CommonLib → UnxswapRouter / UnxswapV3Router → DexRouter。
 *      大量使用 CommonUtils 中定义的位掩码与常量（_ADDRESS_MASK、_TRANSFER_MODE_MASK、各 _MODE_、
 *      ORIGIN_PAYER、_WETH、_APPROVE_PROXY、_WNATIVE_RELAY 等），建议配合 CommonUtils 注释阅读。
 */
abstract contract CommonLib is CommonUtils {
    using UniversalERC20 for IERC20;

    /**
     * @notice 调用 adapter 执行一段兑换（adapter 是对接具体 DEX 的适配器合约）。
     * @dev 按 reverse 选择调用 adapter 的 sellQuote（反向）或 sellBase（正向）。
     *      关键：在标准 ABI 编码后【追加 32 字节】= ORIGIN_PAYER 魔数前缀(高12字节) + refundTo 地址(低20字节)，
     *      用作"协议握手"——adapter 从 calldata 末尾读出这 32 字节，校验魔数后才信任 refundTo（见 CommonUtils.ORIGIN_PAYER）。
     *      调用失败时用 _revert 把 adapter 返回的原始错误原因冒泡抛出。
     * @param reverse     交易方向：true=调用 sellQuote(反向)，false=调用 sellBase(正向)
     * @param adapter     适配器合约地址
     * @param to          兑换输出代币的接收地址（通常是下一跳或最终收款方）
     * @param poolAddress 本次兑换使用的池子地址
     * @param moreinfo    传给 adapter 的额外编码信息（池子参数等）
     * @param refundTo    退款地址（追加进 calldata 末尾，供 adapter 退还多余资金）
     */
    function _exeAdapter(
        bool reverse,
        address adapter,
        address to,
        address poolAddress,
        bytes memory moreinfo,
        address refundTo
    ) internal {
        if (reverse) {
            // 反向：调用 adapter.sellQuote，并在编码末尾追加 [ORIGIN_PAYER | refundTo]
            (bool s, bytes memory res) = address(adapter).call(
                abi.encodePacked(
                    abi.encodeWithSelector(
                        IAdapter.sellQuote.selector,
                        to,
                        poolAddress,
                        moreinfo
                    ),
                    ORIGIN_PAYER + uint(uint160(refundTo)) // 魔数前缀 + refundTo 拼成 32 字节后缀
                )
            );
            if (!s) {
                _revert(res); // 失败则冒泡 adapter 的原始错误
            }
        } else {
            // 正向：调用 adapter.sellBase，编码方式同上
            (bool s, bytes memory res) = address(adapter).call(
                abi.encodePacked(
                    abi.encodeWithSelector(
                        IAdapter.sellBase.selector,
                        to,
                        poolAddress,
                        moreinfo
                    ),
                    ORIGIN_PAYER + uint(uint160(refundTo))
                )
            );
            if (!s) {
                _revert(res);
            }
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with "FailedCall".
     * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/c64a1edb67b6e3f4a15cca8909c9482ad33a02b0/contracts/utils/Address.sol#L135-L149
     */
    /**
     * @notice 把一次外部调用返回的原始 revert 原因原样抛出（冒泡）；若无返回数据则抛默认错误。
     * @dev 若 returndata 非空 → 用 assembly 原样 revert 其内容（保留对方真实错误）；
     *      若为空 → revert("adaptor call failed")。逻辑参考 OpenZeppelin Address.sol。
     *      （注：上方英文注释中的 "FailedCall" 沿用自 OZ 原文，本实现实际抛出的是 "adaptor call failed"。）
     * @param returndata 外部调用返回的原始数据（失败时即对方的 revert 原因）
     */
    function _revert(bytes memory returndata) internal pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            // returndata 内存布局：前 32 字节是长度，数据从 +0x20 开始；
            // 故从 add(returndata,0x20) 起、按 mload(returndata)（即长度）回滚
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        } else {
            revert("adaptor call failed");
        }
    }

    /// @notice Transfers tokens internally within the contract.
    /// @param payer The address of the payer.
    /// @param to The address of the receiver.
    /// @param fromTokenWithMode FromToken with mode encoded in high bits
    /// @param amount The amount of tokens to be transferred.
    /// @dev Handles the transfer of ERC20 tokens or native tokens within the contract.
    /**
     * @notice 内部转账：根据 fromToken 高位编码的「转账模式」，决定资金从哪来、怎么转。
     * @dev fromTokenWithMode 把 token 地址与转账模式打包在一个 uint256：
     *        - [bit 159..0]  = token 地址（_ADDRESS_MASK 取出）
     *        - [bit 251..249] = 转账模式（_TRANSFER_MODE_MASK 取出，见 CommonUtils 的 _MODE_* 常量）
     *      模式分支：
     *        - _MODE_NO_TRANSFER ：免转账（上一跳输出已直接落到目标，跳过），直接 return；
     *        - _MODE_BY_INVEST   ：资金已在本合约（如 smartSwapByInvest 由外部先把钱打到 Router），
     *                              无视 payer 直接 safeTransfer 转给 to；
     *        - _MODE_PERMIT2     ：预留未实现，直接 return；
     *        - 默认(_MODE_LEGACY)：payer 是本合约 → safeTransfer；payer 是用户 → 经 ApproveProxy.claimTokens 拉款。
     * @param payer            付款方地址（本合约 或 用户）
     * @param to               收款方地址
     * @param fromTokenWithMode token 地址 + 高位转账模式的打包值
     * @param amount           转账数量
     */
    function _transferInternal(
        address payer,
        address to,
        uint256 fromTokenWithMode,
        uint256 amount
    ) internal {
        address token = address(uint160(fromTokenWithMode & _ADDRESS_MASK)); // [bit 159..0] 取 token 地址
        uint256 mode = fromTokenWithMode & _TRANSFER_MODE_MASK; // [bit 251..249] 取转账模式

        if (mode == _MODE_NO_TRANSFER) {
            // 免转账：hop-to-hop 优化，资金已就位，无需再转
            return;
        } else if (mode == _MODE_BY_INVEST) {
            // 投资模式：资金已在本合约，直接转出
            SafeERC20.safeTransfer(IERC20(token), to, amount);
            return;
        } else if (mode == _MODE_PERMIT2) {
            // Permit2 mode - reserved for future implementation
            // Permit2 模式：预留，当前不做任何处理
            return;
        } else {
            // 默认模式
            if (payer == address(this)) {
                // 付款方是本合约 → 直接从合约余额安全转出
                SafeERC20.safeTransfer(IERC20(token), to, amount);
            } else {
                // 付款方是用户 → 经 ApproveProxy 从用户钱包拉款（用户只需 approve 给 ApproveProxy）
                IApproveProxy(_APPROVE_PROXY).claimTokens(
                    token,
                    payer,
                    to,
                    amount
                );
            }
        }
    }

    /// @notice Transfers the specified token to the user.
    /// @param token The address of the token to be transferred.
    /// @param to The address of the receiver.
    /// @dev Handles the withdrawal of tokens to the user, converting WETH to ETH if necessary.
    /**
     * @notice 把本合约持有的 token 的全部余额发还给用户；若 token 是 ETH，则先把 WETH 解包成 ETH 再发。
     * @dev ETH 分支：本合约内部统一用 WETH 处理兑换，给用户原生 ETH 前需先解包：
     *        1. 把本合约持有的 WETH 转给 WNativeRelayer（无状态中介）；
     *        2. 调 Relayer.withdraw 解包，解包出的 ETH 会【回到本合约】（使 address(this).balance 增加；
     *           Relayer 实现不在本仓库，此点由下方"读自身余额并转出"的逻辑反推，详见 CommonUtils._WNATIVE_RELAY）；
     *        3. 若 to 不是本合约，把本合约的 ETH 余额用底层 call 发给 to。
     *      关于"Router 不持有 ETH"：这里 ETH 只是【同一笔交易内】短暂经手（即收即付），转给用户后余额归 0，
     *        不会跨交易沉淀；真正避免的是"本合约自己调 WETH.withdraw 而长期留存 ETH 余额"。
     *      ERC20 分支：若 to 不是本合约，把本合约持有的该 token 全部 safeTransfer 给 to。
     *      注：均按"当前余额"转出（bal>0 才转），适配"先把钱汇到本合约再统一结算"的路由模式。
     * @param token 要发还的代币（ETH 用占位地址，经 isETH 判断）
     * @param to    最终接收地址
     */
    function _transferTokenToUser(address token, address to) internal {
        if ((IERC20(token).isETH())) {
            // —— ETH 分支：把本合约持有的 WETH 解包成 ETH，再发给用户 ——
            uint256 wethBal = IERC20(address(uint160(_WETH))).balanceOf(
                address(this)
            );
            if (wethBal > 0) {
                // 不自己调 WETH.withdraw（那会让本合约凭空多出 ETH 余额、难以受控），
                // 而是委托无状态中介 Relayer 解包：先把 WETH 转给 Relayer，再让它 withdraw。
                IWETH(address(uint160(_WETH))).transfer(
                    _WNATIVE_RELAY,
                    wethBal
                );
                // 调 Relayer.withdraw 后，解包得到的 ETH 会【回到本合约】——下方读取
                // address(this).balance 即依赖这一点（注：Relayer 实现不在本仓库，但由其后
                // "读自身 ETH 余额并转出"的逻辑可反推：withdraw 执行后本合约确实收到了 ETH）。
                IWNativeRelayer(_WNATIVE_RELAY).withdraw(wethBal);
            }
            if (to != address(this)) {
                // 此处的 ETH 即上一步 withdraw 后回到本合约的那笔——「即收即付」：
                // 本合约只是同一笔交易内短暂经手，立刻转给最终接收者，转完余额归 0（不沉淀）。
                uint256 ethBal = address(this).balance;
                if (ethBal > 0) {
                    (bool success, ) = payable(to).call{value: ethBal}("");
                    require(success, "transfer native token failed");
                }
            }
        } else {
            // —— ERC20 分支：把合约持有的该 token 全部转给用户 ——
            if (to != address(this)) {
                uint256 bal = IERC20(token).balanceOf(address(this));
                if (bal > 0) {
                    SafeERC20.safeTransfer(IERC20(token), to, bal);
                }
            }
        }
    }

    /// @notice Converts a uint256 value into an address.
    /// @param param The uint256 value to be converted.
    /// @return result The address obtained from the conversion.
    /// @dev This function is used to extract an address from a uint256,
    /// typically used when dealing with low-level data operations or when addresses are packed into larger data types.
    /**
     * @notice 从 uint256 中提取出 address（取低 160 位）。
     * @dev 常用于"地址被打包进更大数据类型"的场景：用 _ADDRESS_MASK 与运算取出低 160 位即地址。
     * @param param 含打包地址的 uint256
     * @return result 取出的地址（低 160 位）
     */
    function _bytes32ToAddress(
        uint256 param
    ) internal pure returns (address result) {
        assembly {
            result := and(param, _ADDRESS_MASK)
        }
    }
}
