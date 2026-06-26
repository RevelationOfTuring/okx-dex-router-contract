/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./SafeMath.sol";
import "./Address.sol";
import "./RevertReasonForwarder.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Permit.sol";
import "../interfaces/IDaiLikePermit.sol";

// File @1inch/solidity-utils/contracts/libraries/SafeERC20.sol@v2.1.1

/**
 * @title SafeERC20
 * @notice 安全调用 ERC20 方法的工具库（移植自 1inch solidity-utils v2.1.1）。
 * @dev 【为什么需要它】ERC20 标准在「返回值」上历史实现混乱，主要有三类 token：
 *        1. 标准 token：transfer/approve 等返回 bool（true 成功）；
 *        2. 不返回值的 token（如早期 USDT）：调用成功但 returndata 为空，按标准会被误判失败；
 *        3. 失败时直接 revert 的 token。
 *      直接 `token.transfer(...)` 无法兼容上述所有情况。本库用底层 call 统一处理返回值：
 *        - 调用 revert            → 视为失败
 *        - 返回空(returndata 为空) → 只要目标是合约(extcodesize>0)就视为成功（兼容无返回值 token）
 *        - 返回数据              → 必须是 32 字节且值为 1(true) 才算成功
 *      这样无论哪类 token 都能正确判断成败。
 * @dev 本库还用内联汇编手工拼 calldata 调用，省去高层 ABI 编码开销、更省 gas。
 */
library SafeERC20 {
    // ───────── 自定义错误：各操作失败时抛出，便于精确定位 ─────────
    error SafeTransferFailed(); // safeTransfer 失败
    error SafeTransferFromFailed(); // safeTransferFrom 失败
    error ForceApproveFailed(); // forceApprove 失败
    error SafeIncreaseAllowanceFailed(); // safeIncreaseAllowance 失败（含溢出）
    error SafeDecreaseAllowanceFailed(); // safeDecreaseAllowance 失败（含下溢）
    error SafePermitBadLength(); // permit 数据长度非法

    /**
     * @notice 安全调用 token.transferFrom(from, to, amount)：成功要求「不 revert 且（返回 true 或无返回值）」。
     * @dev 单独手写汇编（不复用 _makeCall）是因为 transferFrom 有 3 个参数、calldata 长度为 100 字节。
     * @param token  ERC20 代币合约
     * @param from   付款方
     * @param to     收款方
     * @param amount 转账数量
     */
    // Ensures method do not revert or return boolean `true`, admits call to non-smart-contract
    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        bytes4 selector = token.transferFrom.selector; // transferFrom(address,address,uint256) 的选择器
        bool success;
        /// @solidity memory-safe-assembly
        assembly {
            // solhint-disable-line no-inline-assembly
            let data := mload(0x40) // 取空闲内存作为 calldata 缓冲区

            // 手工拼 calldata：selector(4) + from(32) + to(32) + amount(32) = 100 字节
            mstore(data, selector) // [0x00] 选择器
            mstore(add(data, 0x04), from) // [0x04] from
            mstore(add(data, 0x24), to) // [0x24] to
            mstore(add(data, 0x44), amount) // [0x44] amount
            // call(gas, addr, value, in, insize, out, outsize)：转发全部 gas，发送 100 字节，接收 32 字节到 0x00
            success := call(gas(), token, 0, data, 100, 0x0, 0x20)
            if success {
                switch returndatasize()
                // 无返回值：兼容不返回 bool 的 token，但要确保目标确实是合约（否则对 EOA 调用也会"成功"）
                case 0 {
                    success := gt(extcodesize(token), 0)
                }
                // 有返回值：必须 ≥32 字节且首个 word == 1(true) 才算成功
                default {
                    success := and(gt(returndatasize(), 31), eq(mload(0), 1))
                }
            }
        }
        if (!success) revert SafeTransferFromFailed();
    }

    /**
     * @notice 安全调用 token.transfer(to, value)。
     * @param token ERC20 代币合约
     * @param to    收款方
     * @param value 转账数量
     */
    // Ensures method do not revert or return boolean `true`, admits call to non-smart-contract
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        if (!_makeCall(token, token.transfer.selector, to, value)) {
            revert SafeTransferFailed();
        }
    }

    /**
     * @notice 安全设置授权额度（兼容老接口名）。内部直接走 forceApprove 逻辑。
     * @param token   ERC20 代币合约
     * @param spender 被授权方
     * @param value   授权额度
     */
    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        forceApprove(token, spender, value);
    }

    /**
     * @notice 强制设置授权额度：若直接 approve(spender, value) 失败，先 approve(spender, 0) 再重试。
     * @dev 处理某些 token（如 USDT）的「安全限制」：当现有 allowance 非 0 时，不允许直接改成另一个非 0 值，
     *      必须先清零再设置。此函数自动完成「清零 → 重设」的兼容流程。
     * @param token   ERC20 代币合约
     * @param spender 被授权方
     * @param value   目标授权额度
     */
    // If `approve(from, to, amount)` fails, try to `approve(from, to, 0)` before retry
    function forceApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        if (!_makeCall(token, token.approve.selector, spender, value)) {
            // 第一次 approve 失败 → 先清零，再重设；任一步失败则整体失败
            if (
                !_makeCall(token, token.approve.selector, spender, 0) ||
                !_makeCall(token, token.approve.selector, spender, value)
            ) {
                revert ForceApproveFailed();
            }
        }
    }

    /**
     * @notice 在当前授权额度基础上「增加」value。
     * @dev 先读现有 allowance，做溢出检查后用 forceApprove 设为新值。
     * @param token   ERC20 代币合约
     * @param spender 被授权方
     * @param value   要增加的额度
     */
    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 allowance = token.allowance(address(this), spender);
        // 溢出保护：allowance + value 不能超过 uint256 上限
        if (value > type(uint256).max - allowance)
            revert SafeIncreaseAllowanceFailed();
        forceApprove(token, spender, allowance + value);
    }

    /**
     * @notice 在当前授权额度基础上「减少」value。
     * @dev 先读现有 allowance，做下溢检查后用 forceApprove 设为新值。
     * @param token   ERC20 代币合约
     * @param spender 被授权方
     * @param value   要减少的额度
     */
    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 allowance = token.allowance(address(this), spender);
        // 下溢保护：要减少的额度不能超过现有额度
        if (value > allowance) revert SafeDecreaseAllowanceFailed();
        forceApprove(token, spender, allowance - value);
    }

    /**
     * @notice 安全调用 token 的 permit（链下签名授权），自动兼容「标准 EIP-2612」与「DAI 风格」两种 permit。
     * @dev permit 机制：用户用一个链下签名代替一笔 approve 交易，省 gas、改善体验。
     *      但历史上存在两套【互不兼容】的 permit 接口，本函数通过 calldata 字节长度自动区分并分发：
     *        - 32*7 = 224 字节 → 标准 EIP-2612 permit(owner,  spender, value,  deadline, v, r, s)  —— 7 个参数
     *        - 32*8 = 256 字节 → DAI 风格   permit(holder, spender, nonce,  expiry,   allowed, v, r, s) —— 8 个参数
     *      （每个参数 ABI 编码后占 32 字节，故参数个数差异直接体现为长度差异；此处长度不含 4 字节 selector。）
     *
     *      两者核心区别对比：
     *        ┌────────────┬──────────────────────────┬──────────────────────────────┐
     *        │ 维度        │ 标准 EIP-2612 (224B/7参数)│ DAI 风格 (256B/8参数)          │
     *        ├────────────┼──────────────────────────┼──────────────────────────────┤
     *        │ 授权额度    │ value：可授权【精确数额】    │ allowed(bool)：只能【无限额或取消│
     *        │ nonce      │ 合约内部自动管理，无需传入    │ 需调用方【显式作为参数传入】      │
     *        │ 过期字段    │ deadline                  │ expiry（仅命名不同）            │
     *        │ 授权人字段   │ owner                    │ holder（仅命名不同）            │
     *        │ 标准化      │ 正式标准 EIP-2612          │ DAI 早于标准的自创版本          │
     *        │ 代表 token  │ USDC、UNI 等多数现代 token  │ DAI 等少数早期 token          │
     *        └────────────┴──────────────────────────┴──────────────────────────────┘
     *      最关键的两点：(1) EIP-2612 能授权任意具体额度，DAI 只能 all-or-nothing；
     *                  (2) EIP-2612 的 nonce 由合约自管，DAI 需调用方显式带上 nonce（这也是它多 1 个参数的原因）。
     *      之所以并存：DAI 上线早于 EIP-2612 标准化，故采用了前标准的自定义接口。
     *
     *      长度不匹配（既非 224 也非 256）则抛 SafePermitBadLength；调用失败则用 RevertReasonForwarder 冒泡原始原因。
     * @param token  支持 permit 的 ERC20 代币
     * @param permit 打包好的 permit 调用参数（calldata，不含 selector）
     */
    function safePermit(IERC20 token, bytes calldata permit) internal {
        bool success;
        if (permit.length == 32 * 7) {
            success = _makeCalldataCall(
                token,
                IERC20Permit.permit.selector,
                permit
            );
        } else if (permit.length == 32 * 8) {
            success = _makeCalldataCall(
                token,
                IDaiLikePermit.permit.selector,
                permit
            );
        } else {
            revert SafePermitBadLength();
        }
        // 失败时把 token 返回的原始 revert 原因原样冒泡抛出（便于定位 permit 失败的真实原因）
        if (!success) RevertReasonForwarder.reRevert();
    }

    /**
     * @notice 内部辅助：调用「单地址 + 单金额」参数的 ERC20 方法（transfer / approve）。
     * @dev calldata = selector(4) + to(32) + amount(32) = 0x44(68) 字节。返回值判定逻辑同 safeTransferFrom。
     * @return success 调用是否「成功」（不 revert 且 返回 true 或无返回值且目标为合约）
     */
    function _makeCall(
        IERC20 token,
        bytes4 selector,
        address to,
        uint256 amount
    ) private returns (bool success) {
        /// @solidity memory-safe-assembly
        assembly {
            // solhint-disable-line no-inline-assembly
            let data := mload(0x40) // 空闲内存作 calldata 缓冲区

            mstore(data, selector) // [0x00] 选择器
            mstore(add(data, 0x04), to) // [0x04] to / spender
            mstore(add(data, 0x24), amount) // [0x24] amount / value
            // 发送 0x44(68) 字节 calldata，接收 32 字节返回值
            success := call(gas(), token, 0, data, 0x44, 0x0, 0x20)
            if success {
                switch returndatasize()
                // 无返回值 → 只要目标是合约就算成功（兼容不返回 bool 的 token）
                case 0 {
                    success := gt(extcodesize(token), 0)
                }
                // 有返回值 → 必须 ≥32 字节且首 word == 1(true)
                default {
                    success := and(gt(returndatasize(), 31), eq(mload(0), 1))
                }
            }
        }
    }

    /**
     * @notice 内部辅助：用「调用方直接传入的 calldata 参数」调用 token 方法。
     * @dev 与 _makeCall 的区别：_makeCall 适用于参数固定（to + amount）的简单方法，逐字段 mstore；
     *      本函数适用于参数复杂/变长的方法（如 permit 的 7~8 个参数），直接用 calldatacopy 把整段
     *      args 原样拼到 selector 之后，无需逐字段编码，更通用也更省 gas。
     * @param token    目标 ERC20 代币合约
     * @param selector 目标方法的 4 字节选择器
     * @param args     已 ABI 编码好的参数（不含 selector），由调用方以 calldata 传入
     * @return success 调用是否「成功」：不 revert，且（返回 true 或 无返回值但目标是合约）
     */
    function _makeCalldataCall(
        IERC20 token,
        bytes4 selector,
        bytes calldata args
    ) private returns (bool success) {
        /// @solidity memory-safe-assembly
        assembly {
            // solhint-disable-line no-inline-assembly
            // 待发送的 calldata 总长度 = selector(4 字节) + args 本身的长度
            let len := add(4, args.length)
            // 取空闲内存指针作为 calldata 拼装缓冲区（只读不更新 fmp：用完即 call，无需归还）
            let data := mload(0x40)

            // [data + 0x00] 写入 4 字节选择器（左对齐占 32 字节槽，低位会被下一步的 args 覆盖）
            mstore(data, selector)
            // [data + 0x04 起] 把调用方传入的 args 从 calldata 原样拷贝到 selector 之后
            calldatacopy(add(data, 0x04), args.offset, args.length)
            // 发起调用：转发全部 gas、value=0、入参 [data, len]、把返回值前 32 字节写到内存 0x00
            success := call(gas(), token, 0, data, len, 0x0, 0x20)
            // 仅当底层 call 未 revert(success==1) 时，再按返回值进一步判定语义上的成功
            if success {
                switch returndatasize()
                // 返回 0 字节：兼容不返回 bool 的 token；但需确保目标确有代码，否则对 EOA 也会"成功"
                case 0 {
                    success := gt(extcodesize(token), 0)
                }
                // 返回有数据：要求至少 32 字节且首个 word == 1(true) 才算成功
                default {
                    success := and(gt(returndatasize(), 31), eq(mload(0), 1))
                }
            }
        }
    }
}
