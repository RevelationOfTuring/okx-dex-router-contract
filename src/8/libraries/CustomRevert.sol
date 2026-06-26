// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Library for reverting with custom errors efficiently
/// @notice Contains functions for reverting with custom errors with different argument types efficiently
/// @dev To use this library, declare `using CustomRevert for bytes4;` and replace `revert CustomError()` with
/// `CustomError.selector.revertWith()`
/// @dev The functions may tamper with the free memory pointer but it is fine since the call context is exited immediately
// CustomRevert —— 用内联汇编高效抛出自定义错误的工具库
//
// 背景：Solidity 写 `revert CustomError(arg)` 时，编译器会生成一段相对臃肿的
//       ABI 编码 + revert 逻辑。本库用手写 assembly 直接拼出 revert 数据，
//       省 gas、省字节码。它是 Uniswap V4 风格的写法。
//
// 用法：
//   error MyError();                       // 定义自定义错误
//   using CustomRevert for bytes4;         // 给 bytes4 挂上扩展方法
//   MyError.selector.revertWith();         // 等价于 revert MyError()，但更省 gas
//
// 核心原理 —— 自定义错误的 revert data 长什么样：
//   revert 数据 = 4 字节 error selector  +  ABI 编码的参数
//   （和函数调用的 calldata 格式完全一致：selector(4) + args）
//   例如 revert MyError(addr) 的数据 =
//        [ 4 字节 selector ][ 32 字节左填充的 addr ]  共 0x24(36) 字节
//
// 两类内存写法：
//   1. 无参 / 单参 → 用 "scratch space"（内存 0x00~0x3f，EVM 预留的临时草稿区），
//      不动 free memory pointer(0x40)，最省。
//   2. 多参 → scratch space 装不下，改用 free memory pointer 指向的空闲内存。
//      因为写完立刻 revert 退出，污染 fmp 也无所谓（注释里 @dev 说明了这点）。
//
// revert(p, n)：从内存偏移 p 开始、取 n 字节作为 revert 返回数据，并回滚交易。
// ─────────────────────────────────────────────────────────────────────────────
library CustomRevert {
    /// @dev ERC-7751 error for wrapping bubbled up reverts
    /// @notice ERC-7751 标准错误：用于「包装」从外部调用冒泡上来的 revert 信息，
    ///         把「哪个合约、哪个函数、原始 revert 原因、附加上下文」一并打包，便于链上溯源调试。
    error WrappedError(
        address target,
        bytes4 selector,
        bytes reason,
        bytes details
    );

    /// @dev Reverts with the selector of a custom error in the scratch space
    /// @notice 抛出「无参」自定义错误：revert data 只有 4 字节 selector
    /// @param selector 自定义错误的 4 字节选择器
    function revertWith(bytes4 selector) internal pure {
        assembly ("memory-safe") {
            // 把 selector 写到 scratch space 起始处（内存 0x00）
            // 注意 bytes4 是左对齐的，占 0x00~0x03
            mstore(0, selector)
            // 从 0x00 起取 4(0x04) 字节作为 revert 数据并回滚
            revert(0, 0x04)
        }
    }

    /// @dev Reverts with a custom error with an address argument in the scratch space
    /// @notice 抛出「带一个 address 参数」的自定义错误
    /// @param selector 错误选择器
    /// @param addr     address 参数（会被 ABI 编码为 32 字节，高 12 字节清零）
    function revertWith(bytes4 selector, address addr) internal pure {
        assembly ("memory-safe") {
            // 0x00~0x03：4 字节 selector
            mstore(0, selector)
            // 0x04~0x23：32 字节参数槽。and(addr, 0xff..ff(20字节)) 是做「掩码清洗」，
            // 确保只保留低 160 位地址、清掉高位脏数据，等价于标准 ABI 的左填充编码
            mstore(0x04, and(addr, 0xffffffffffffffffffffffffffffffffffffffff))
            // 总长度 = 4(selector) + 32(arg) = 0x24(36) 字节
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with an int24 argument in the scratch space
    /// @notice 抛出「带一个 int24 参数」的自定义错误（int24 是有符号 24 位整数，常见于 tick）
    /// @param selector 错误选择器
    /// @param value    int24 参数
    function revertWith(bytes4 selector, int24 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            // signextend(b, x)：把 x 当作「b+1 字节」的有符号数，符号扩展到 256 位。
            // 这里 b=2 → 3 字节 = 24 位，正好是 int24；符号位是 bit 23。
            // 作用：若 value 为负(bit23=1)，高位补满 1；若为正，高位补 0，从而保住补码数值与符号。
            mstore(0x04, signextend(2, value))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with a uint160 argument in the scratch space
    /// @notice 抛出「带一个 uint160 参数」的自定义错误（uint160 常见于 sqrtPriceX96 等）
    /// @param selector 错误选择器
    /// @param value    uint160 参数
    function revertWith(bytes4 selector, uint160 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            // uint160 是无符号，用掩码保留低 160 位、清高位即可（无需符号扩展）
            mstore(0x04, and(value, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev Reverts with a custom error with two int24 arguments
    /// @notice 抛出「带两个 int24 参数」的自定义错误。两个参数共需 4+32+32=0x44 字节，
    ///         超出了 scratch space(0x00~0x3f) 的容量，因此改用 free memory pointer 指向的内存
    function revertWith(
        bytes4 selector,
        int24 value1,
        int24 value2
    ) internal pure {
        assembly ("memory-safe") {
            // fmp = 当前空闲内存指针(0x40 处存的值)，作为本次拼数据的起始地址
            let fmp := mload(0x40)
            // [fmp + 0x00] selector
            mstore(fmp, selector)
            // [fmp + 0x04] 第一个 int24（符号扩展为 32 字节）
            // signextend(2,...)：把低 3 字节(24 位)按符号位 bit23 扩展到 256 位，保住负号
            mstore(add(fmp, 0x04), signextend(2, value1))
            // [fmp + 0x24] 第二个 int24（同样符号扩展为 32 字节）
            mstore(add(fmp, 0x24), signextend(2, value2))
            // 总长度 = 4 + 32 + 32 = 0x44(68) 字节
            // 立即 revert 退出，所以没有更新 fmp(0x40) 也没关系
            revert(fmp, 0x44)
        }
    }

    /// @dev Reverts with a custom error with two uint160 arguments
    /// @notice 抛出「带两个 uint160 参数」的自定义错误，布局同上（用 fmp）
    function revertWith(
        bytes4 selector,
        uint160 value1,
        uint160 value2
    ) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            // 两个 uint160 各做掩码清洗后左填充为 32 字节
            mstore(
                add(fmp, 0x04),
                and(value1, 0xffffffffffffffffffffffffffffffffffffffff)
            )
            mstore(
                add(fmp, 0x24),
                and(value2, 0xffffffffffffffffffffffffffffffffffffffff)
            )
            revert(fmp, 0x44)
        }
    }

    /// @dev Reverts with a custom error with two address arguments
    /// @notice 抛出「带两个 address 参数」的自定义错误，布局同上（用 fmp）
    function revertWith(
        bytes4 selector,
        address value1,
        address value2
    ) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            // 两个地址各做 160 位掩码清洗后左填充为 32 字节
            mstore(
                add(fmp, 0x04),
                and(value1, 0xffffffffffffffffffffffffffffffffffffffff)
            )
            mstore(
                add(fmp, 0x24),
                and(value2, 0xffffffffffffffffffffffffffffffffffffffff)
            )
            revert(fmp, 0x44)
        }
    }

    /// @notice bubble up the revert message returned by a call and revert with a wrapped ERC-7751 error
    /// @dev this method can be vulnerable to revert data bombs
    /// @notice 「冒泡」机制：当本合约调用外部合约失败时，把外部返回的原始 revert 原因(returndata)
    ///         连同「出错的合约地址、函数选择器、附加上下文」一起，按 ERC-7751 的 WrappedError
    ///         格式重新打包后 revert 出去。这样上层能完整看到错误的来龙去脉。
    /// @dev ⚠️ 安全隐患：恶意被调合约可返回超大 returndata（revert data bomb / 返回数据炸弹），
    ///         这里全量拷贝会消耗大量 gas，可能被用于 gas 耗尽攻击。
    /// @param revertingContract         出错的目标合约地址
    /// @param revertingFunctionSelector 出错时调用的函数选择器
    /// @param additionalContext         调用方附加的上下文（4 字节），用于辅助定位错误
    function bubbleUpAndRevertWith(
        address revertingContract,
        bytes4 revertingFunctionSelector,
        bytes4 additionalContext
    ) internal pure {
        // WrappedError(address,bytes4,bytes,bytes) 的 4 字节选择器
        bytes4 wrappedErrorSelector = WrappedError.selector;
        assembly ("memory-safe") {
            // ── 第一步：把外部返回的 revert 数据长度(returndatasize)向上对齐到 32 的倍数 ──
            // ABI 规范要求动态类型(bytes)的数据区按 32 字节对齐。
            // 公式 ((n + 31) / 32) * 32 = 把 n 向上取整到最近的 32 倍数。
            let encodedDataSize := mul(div(add(returndatasize(), 31), 32), 32)

            // fmp = 空闲内存起始，作为整个 WrappedError 编码的起点
            let fmp := mload(0x40)

            // ── 第二步：按 WrappedError(address,bytes4,bytes,bytes) 的 ABI 规则逐字段写入 ──
            // ABI 编码 = selector(4) + 头部(每个参数 32 字节槽) + 尾部(动态数据)
            // 头部 4 个槽依次是：target、selector、reason(偏移)、details(偏移)

            // [fmp + 0x00] WrappedError 选择器（4 字节）
            mstore(fmp, wrappedErrorSelector)

            // [fmp + 0x04] 参数1 target：出错合约地址（掩码清洗为 160 位）
            mstore(
                add(fmp, 0x04),
                and(
                    revertingContract,
                    0xffffffffffffffffffffffffffffffffffffffff
                )
            )

            // [fmp + 0x24] 参数2 selector：出错函数选择器
            // bytes4 在 ABI 中右填充(左对齐)，所以用高 4 字节掩码保留高位、清低位
            mstore(
                add(fmp, 0x24),
                and(
                    revertingFunctionSelector,
                    0xffffffff00000000000000000000000000000000000000000000000000000000
                )
            )

            // [fmp + 0x44] 参数3 reason(bytes) 的数据偏移量 = 0x80
            // 偏移从「头部起始(fmp+0x04)」算起：头部共 4 个槽(0x80 字节)，故 reason 数据紧跟其后
            mstore(add(fmp, 0x44), 0x80)

            // [fmp + 0x64] 参数4 details(bytes) 的数据偏移量
            // = reason 区的起点(0xa0) + reason 数据占用大小(encodedDataSize)
            mstore(add(fmp, 0x64), add(0xa0, encodedDataSize))

            // ── reason(bytes) 的实际数据区：先写长度，再写内容 ──
            // [fmp + 0x84] reason 的真实长度 = returndatasize（未对齐的原始长度）
            mstore(add(fmp, 0x84), returndatasize())
            // [fmp + 0xa4] reason 的内容 = 把外部返回的全部 returndata 拷过来
            returndatacopy(add(fmp, 0xa4), 0, returndatasize())

            // ── details(bytes) 的实际数据区：紧跟在对齐后的 reason 数据之后 ──
            // [fmp + 0xa4 + encodedDataSize] details 的长度 = 4（只有 additionalContext 4 字节）
            mstore(add(fmp, add(0xa4, encodedDataSize)), 0x04)
            // [fmp + 0xc4 + encodedDataSize] details 的内容 = additionalContext（bytes4 右填充）
            mstore(
                add(fmp, add(0xc4, encodedDataSize)),
                and(
                    additionalContext,
                    0xffffffff00000000000000000000000000000000000000000000000000000000
                )
            )

            // ════════════════════════════════════════════════════════════════════════════════
            //  完整 ABI 编码结构总览（WrappedError 在内存中的最终布局）
            // ────────────────────────────────────────────────────────────────────────────────
            //  WrappedError(address target, bytes4 selector, bytes reason, bytes details)
            //  记号 size = encodedDataSize（reason 内容向上对齐到 32 倍数后的大小）
            //  所有「偏移量」均从偏移基准 (fmp+0x04) 算起，不包含 error selector
            //
            //  内存地址        字段              写入的值                  编码说明              区域
            //  ─────────────────────────────────────────────────────────────────────────────
            //  fmp+0x00       error selector    WrappedError.selector(4B) 左对齐,不计入偏移基准 SELECTOR
            //  ───────────────── ▼▼▼ 偏移基准点 = fmp+0x04（以下偏移从这里数起）▼▼▼ ──────────
            //  fmp+0x04       target            地址值                     静态·左填充(右对齐)
            //  fmp+0x24       selector          bytes4 值                 静态·右填充(左对齐)   HEAD
            //  fmp+0x44       reason  → offset  0x80                      动态·指向 reason 数据 (4槽
            //  fmp+0x64       details → offset  0xa0 + size               动态·指向 details数据 =0x80)
            //  ─────────────────────────────────────────────────────────────────────────────
            //  fmp+0x84       reason.length     returndatasize()          真实长度(未对齐)
            //  fmp+0xa4       reason.data       外部 returndata 内容       占 size 字节(已对齐)  TAIL
            //  fmp+0xa4+size  details.length    0x04                      真实长度(=4)         (动态
            //  fmp+0xc4+size  details.data      additionalContext         bytes4·右填充·占32B  数据)
            //  ─────────────────────────────────────────────────────────────────────────────
            //  revert 总长度 = 0xe4 + size
            //    = selector(0x04)+HEAD(0x80)+reason[len 0x20+data size]+details[len 0x20+data 0x20]
            //
            //  三段式速记：
            //    ┌──────────┐ fmp+0x00, 4B           —— "这是哪个错误"
            //    │ SELECTOR │
            //    ├──────────┤ 4个槽×32B=0x80          —— "参数清单"
            //    │   HEAD   │  静态参数放值 / 动态参数放偏移量(指针)
            //    ├──────────┤ 动态参数真实数据        —— "长内容仓库"
            //    │   TAIL   │  每段 = [长度槽][32字节对齐内容]
            //    └──────────┘
            // ════════════════════════════════════════════════════════════════════════════════

            // ── 第三步：从 fmp 起、按总长度回滚 ──
            // 总长度 = 0xe4(固定头部+两个 bytes 的长度槽+details内容起点) + encodedDataSize(reason 对齐后大小)
            revert(fmp, add(0xe4, encodedDataSize))
        }
    }
}
