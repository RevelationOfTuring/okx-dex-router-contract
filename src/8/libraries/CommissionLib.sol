/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./CommonUtils.sol";
import "../interfaces/AbstractCommissionLib.sol";

/// @title Base contract with common permit handling logics

/**
 * @title CommissionLib - 佣金返佣 + 正滑点回收（Trim）逻辑库
 * @notice 在一笔兑换的「输入端」或「输出端」抽取一部分资金，分给推荐人(referrer)作为佣金；
 *         并可对「正滑点」(实际输出 > 预期输出 的超出部分)按规则回收/分配(Trim)。
 *         相关参数不走显式函数参数，而是【编码在 calldata 末尾的若干 32 字节槽】里，
 *         由 _getCommissionAndTrimInfo 反向扫描解析。
 * @dev 为节省字节码与 gas，核心逻辑全部用内联汇编实现；事件也用 log1 在汇编里手动 emit
 *      （对应的 event 定义在下方以注释形式保留，便于查阅 topic/参数）。
 *
 *      【两大功能】
 *        1. Commission（佣金）：从 fromToken（输入端）或 toToken（输出端）按 rate 抽成给 referrer。
 *           支持三种规模：单个(1 人) / DUAL(2 人) / MULTIPLE(3~8 人)。
 *        2. Trim（正滑点回收）：当实际兑换所得超过用户预期(expectAmountOut)时，
 *           把这部分"正滑点"按 trimRate 上限回收，再按 chargeRate 在 trim/charge 两个地址间分配。
 *
 *      【calldata 编码约定】每个 commission/trim 槽是一个 bytes32，高位放 flag 魔数(识别类型)，
 *        其余位放 rate / 地址 / 长度等（见各 *_MASK 常量）。toB 标志位区分面向 C 端/商户端。
 *        flag 魔数前缀 0x3ca20afc.../0x2222.../0x8888... 等用于"协议握手"式识别，避免误判普通 calldata。
 */
abstract contract CommissionLib is AbstractCommissionLib, CommonUtils {
    // ===== 佣金(Commission)相关位掩码与 flag 魔数 =====
    /// @dev 佣金费率掩码：取出 commission 槽中编码的 rate（位于 bit 207..160 区间，提取后需 >>160）
    uint256 internal constant _COMMISSION_RATE_MASK =
        0x000000000000ffffffffffff0000000000000000000000000000000000000000;
    /// @dev 佣金 flag 掩码：取出高 48 位的 flag 魔数，用于识别 commission/trim 的类型
    uint256 internal constant _COMMISSION_FLAG_MASK =
        0xffffffffffff0000000000000000000000000000000000000000000000000000;
    /// @dev flag 魔数：从【输入端 fromToken】抽佣，单个推荐人
    uint256 internal constant FROM_TOKEN_COMMISSION =
        0x3ca20afc2aaa0000000000000000000000000000000000000000000000000000;
    /// @dev flag 魔数：从【输出端 toToken】抽佣，单个推荐人
    uint256 internal constant TO_TOKEN_COMMISSION =
        0x3ca20afc2bbb0000000000000000000000000000000000000000000000000000;
    /// @dev flag 魔数：从 fromToken 抽佣，DUAL（2 个推荐人）
    uint256 internal constant FROM_TOKEN_COMMISSION_DUAL =
        0x22220afc2aaa0000000000000000000000000000000000000000000000000000;
    /// @dev flag 魔数：从 toToken 抽佣，DUAL（2 个推荐人）
    uint256 internal constant TO_TOKEN_COMMISSION_DUAL =
        0x22220afc2bbb0000000000000000000000000000000000000000000000000000;
    /// @dev flag 魔数：从 fromToken 抽佣，MULTIPLE（3~8 个推荐人，真实人数另在 length 字段编码）
    uint256 internal constant FROM_TOKEN_COMMISSION_MULTIPLE =
        0x88880afc2aaa0000000000000000000000000000000000000000000000000000;
    /// @dev flag 魔数：从 toToken 抽佣，MULTIPLE（3~8 个推荐人）
    uint256 internal constant TO_TOKEN_COMMISSION_MULTIPLE =
        0x88880afc2bbb0000000000000000000000000000000000000000000000000000;
    /// @dev 佣金人数(length)掩码：MULTIPLE 模式下编码真实推荐人数（位于 bit 247..240，提取后需 >>240）
    uint256 internal constant _COMMISSION_LENGTH_MASK =
        0x00ff000000000000000000000000000000000000000000000000000000000000;
    /// @dev toB 佣金标志位（bit 255）：置 1 表示面向商户(toB)模式，影响佣金的收取/结算方式
    uint256 internal constant _TO_B_COMMISSION_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    // ===== 正滑点回收(Trim)相关位掩码与 flag 魔数 =====
    /// @dev Trim flag 掩码：取高 48 位 flag（与 _COMMISSION_FLAG_MASK 数值相同，复用同一区间）
    uint256 internal constant _TRIM_FLAG_MASK =
        0xffffffffffff0000000000000000000000000000000000000000000000000000;
    /// @dev Trim 槽低 160 位：复用为「预期输出额 expectAmountOut」或「地址」(trim/charge 地址)
    uint256 internal constant _TRIM_EXPECT_AMOUNT_OUT_OR_ADDRESS_MASK =
        0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;
    /// @dev Trim 费率掩码：取出 trimRate / chargeRate（bit 207..160，提取后需 >>160）
    uint256 internal constant _TRIM_RATE_MASK =
        0x000000000000ffffffffffff0000000000000000000000000000000000000000;
    /// @dev toB Trim 标志位（bit 191）：置 1 表示面向商户(toB)的 trim 模式
    uint256 internal constant _TO_B_TRIM_MASK =
        0x0000000000008000000000000000000000000000000000000000000000000000;
    /// @dev flag 魔数：单组 Trim（正滑点回收）
    uint256 internal constant TRIM_FLAG =
        0x7777777711110000000000000000000000000000000000000000000000000000;
    /// @dev flag 魔数：DUAL Trim（含额外的 charge 分配，需 3 个 trim 槽）
    uint256 internal constant TRIM_DUAL_FLAG =
        0x7777777722220000000000000000000000000000000000000000000000000000;

    // @notice CommissionAndTrimInfo is emitted in assembly, commentted out for contract size saving
    // event CommissionAndTrimInfo(
    //     uint256 toBCommission, // 0 for no commission, 1 for no-toB commission, 2 for toB commission
    //     uint256 toBTrim, // 0 for no trim, 1 for no-toB trim, 2 for toB trim
    //     uint256 trimRate,
    //     uint256 chargeRate
    // );

    // @notice CommissionFromTokenRecord is emitted in assembly, commentted out for contract size saving
    // event CommissionFromTokenRecord(
    //     address fromTokenAddress,
    //     uint256 commissionAmount,
    //     address referrerAddress,
    //     uint256 commissionRate
    // );

    // @notice CommissionToTokenRecord is emitted in assembly, commentted out for contract size saving
    // event CommissionToTokenRecord(
    //     address toTokenAddress,
    //     uint256 commissionAmount,
    //     address referrerAddress,
    //     uint256 commissionRate
    // );

    // @notice PositiveSlippageTrimRecord is emitted in assembly, commentted out for contract size saving
    // event PositiveSlippageTrimRecord(
    //     address toTokenAddress,
    //     uint256 trimAmount,
    //     address trimAddress
    // );

    // @notice PositiveSlippageChargeRecord is emitted in assembly, commentted out for contract size saving
    // event PositiveSlippageChargeRecord(
    //     address toTokenAddress,
    //     uint256 chargeAmount,
    //     address chargeAddress
    // );

    // set default value can change when need.
    // ===== 数值参数（可按需调整）=====
    /// @dev MULTIPLE 模式允许的最少推荐人数
    uint256 internal constant MIN_COMMISSION_MULTIPLE_NUM = 3; // min referrer num for multiple commission
    /// @dev MULTIPLE 模式允许的最多推荐人数
    uint256 internal constant MAX_COMMISSION_MULTIPLE_NUM = 8; // max referrer num for multiple commission
    /// @dev 佣金总费率上限：30000000 / DENOMINATOR(1e9) = 3%（所有推荐人 rate 之和不得超过）
    uint256 internal constant commissionRateLimit = 30000000;
    /// @dev 佣金费率分母：rate 以 1e9 为基准（如 rate=1e7 表示 1%）
    uint256 internal constant DENOMINATOR = 10 ** 9;
    /// @dev 非 toB 模式标识（当对应 calldata 存在时，toBCommission/toBTrim 取此值=1）
    uint256 internal constant NO_TO_B_MODE = 1; // value for no-toB commission and no-toB trim when related calldata exists
    /// @dev toB 模式标识（=2）
    uint256 internal constant TO_B_MODE = 2; // value for toB commission and toB trim when related calldata exists
    /// @dev 1e18，用于 MULTIPLE 模式按比例缩放金额时的中间精度基准
    uint256 internal constant WAD = 1 ether;
    /// @dev Trim 回收比例上限：trimRate 不得超过 100/TRIM_DENOMINATOR(1000) = 10%
    uint256 internal constant TRIM_RATE_LIMIT = 100;
    /// @dev Trim 费率分母：trimRate / chargeRate 以 1000 为基准
    uint256 internal constant TRIM_DENOMINATOR = 1000;

    /**
     * @notice 从 calldata 末尾【反向扫描】解析出佣金信息(CommissionInfo)与正滑点回收信息(TrimInfo)。
     * @dev 佣金/Trim 参数不走显式函数参数，而是编码在 calldata 尾部的若干 32 字节槽里。流程：
     *      1. 定位真实边界 effectiveEnd：
     *         - 先剥离非 32 字节对齐的尾部字节(calldata 应为 4字节selector + N*32字节)；
     *         - 再从右往左按 32 字节对齐扫描，找到最右一个"已知 flag 魔数"的位置作为 effectiveEnd
     *           （兼容尾部可能追加了 ERC-8021 等外部后缀，故 calldatasize 不一定是真正边界）。
     *      2. 解析佣金：读最后一个槽的 flag，判定方向(from/to token)与规模(单个/DUAL/MULTIPLE)，
     *         得到 referrerNum；再依次读取 rate/referrer/token/toBCommission；
     *         MULTIPLE 模式额外读取真实人数并校验在 [MIN, MAX] 之间；无佣金时擦除相关内存槽。
     *      3. 解析 Trim：按佣金占用的槽数计算 offset，继续向前读取 trim 槽，
     *         得到 hasTrim/trimRate/trimAddress/toBTrim/expectAmountOut；DUAL Trim 再读 chargeRate/chargeAddress。
     *      4. 若存在任一佣金或 Trim，用 log1 手动 emit CommissionAndTrimInfo 事件（省字节码）。
     *      解析结果按固定偏移逐字段 mstore 写入 memory 的 commissionInfo / trimInfo 结构体
     *      （偏移定义见 AbstractCommissionLib 的结构体注释）。
     * @return commissionInfo 解析出的佣金信息
     * @return trimInfo        解析出的正滑点回收信息
     */
    function _getCommissionAndTrimInfo()
        internal
        override
        returns (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo)
    {
        assembly ("memory-safe") {
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }

            // Backward scan to find the true ExtraData boundary (effectiveEnd).
            // External suffixes (e.g. ERC-8021) may be appended after ExtraData,
            // so calldatasize() may no longer be the right edge.
            // 反向扫描定位真实的 ExtraData 边界 effectiveEnd。
            // 因为 ExtraData 之后可能被追加外部后缀(如 ERC-8021)，calldatasize() 不一定是右边界。
            let calldataEnd := calldatasize()

            // 剥离非 32 字节对齐的尾部：calldata 应为 4字节selector + N*32字节
            // remainder = (calldataEnd - 4) % 32，effectiveEnd 回退到对齐位置
            // Strip non-aligned suffix bytes: calldata should be 4B selector + N*32B
            let remainder := mod(sub(calldataEnd, 4), 0x20)
            let effectiveEnd := sub(calldataEnd, remainder)

            // 从右往左按 32 字节对齐扫描，找最右一个"已知 flag 魔数"的位置。
            // 直接与全部 8 个已知 flag 值精确比对(6 个佣金 flag + 2 个 trim flag)。
            // Scan backward through 32-byte aligned positions to find the rightmost known flag.
            let scanPos := effectiveEnd
            // 0x23=35：保证 scanPos >= 0x24，使 calldataload 读取的偏移 >= 4(跳过 selector)
            for {

            } gt(scanPos, 0x23) {
                scanPos := sub(scanPos, 0x20)
            } {
                // 取当前槽的高 48 位 flag。_COMMISSION_FLAG_MASK 与 _TRIM_FLAG_MASK 相同，一个掩码即可覆盖所有 flag
                let flagMasked := and(
                    calldataload(sub(scanPos, 0x20)),
                    _COMMISSION_FLAG_MASK
                )
                // 与 8 个已知 flag 精确匹配（6 个佣金 + 2 个 trim 中的某一个）。命中则把 effectiveEnd 定到此处并结束扫描
                if or(
                    or(
                        or(
                            eq(flagMasked, FROM_TOKEN_COMMISSION),
                            eq(flagMasked, TO_TOKEN_COMMISSION)
                        ),
                        or(
                            eq(flagMasked, FROM_TOKEN_COMMISSION_DUAL),
                            eq(flagMasked, TO_TOKEN_COMMISSION_DUAL)
                        )
                    ),
                    or(
                        or(
                            eq(flagMasked, FROM_TOKEN_COMMISSION_MULTIPLE),
                            eq(flagMasked, TO_TOKEN_COMMISSION_MULTIPLE)
                        ),
                        or(
                            eq(flagMasked, TRIM_FLAG),
                            eq(flagMasked, TRIM_DUAL_FLAG)
                        )
                    )
                ) {
                    effectiveEnd := scanPos
                    break
                }
            }

            // 读最后一个槽作为佣金数据，取其 flag 判定佣金规模
            let commissionData := calldataload(sub(effectiveEnd, 0x20))
            let flag := and(commissionData, _COMMISSION_FLAG_MASK)
            let referrerNum := 0
            // 单个佣金 flag → 1 个推荐人
            if or(
                eq(flag, FROM_TOKEN_COMMISSION),
                eq(flag, TO_TOKEN_COMMISSION)
            ) {
                referrerNum := 1
            }
            // DUAL flag → 2 个推荐人
            if or(
                eq(flag, FROM_TOKEN_COMMISSION_DUAL),
                eq(flag, TO_TOKEN_COMMISSION_DUAL)
            ) {
                referrerNum := 2
            }
            // MULTIPLE flag → 先暂置 3，后面再读取真实编码的人数
            if or(
                eq(flag, FROM_TOKEN_COMMISSION_MULTIPLE),
                eq(flag, TO_TOKEN_COMMISSION_MULTIPLE)
            ) {
                referrerNum := 3 // default referrer num to load real encoded referrer num
            }
            // 写 isFromTokenCommission(偏移 0x00)：flag 是三种 from 佣金之一则为 true
            mstore(
                commissionInfo,
                or(
                    or(
                        eq(flag, FROM_TOKEN_COMMISSION),
                        eq(flag, FROM_TOKEN_COMMISSION_DUAL)
                    ),
                    eq(flag, FROM_TOKEN_COMMISSION_MULTIPLE)
                )
            ) // isFromTokenCommission
            // 写 isToTokenCommission(偏移 0x20)：flag 是三种 to 佣金之一则为 true
            mstore(
                add(0x20, commissionInfo),
                or(
                    or(
                        eq(flag, TO_TOKEN_COMMISSION),
                        eq(flag, TO_TOKEN_COMMISSION_DUAL)
                    ),
                    eq(flag, TO_TOKEN_COMMISSION_MULTIPLE)
                )
            ) // isToTokenCommission
            // 有佣金(referrerNum>0)才解析具体字段，否则走 default 擦除内存
            switch gt(referrerNum, 0)
            case 1 {
                // 第 1 个推荐人的 rate(偏移 0xa0)：取 commissionData 的 rate 位段后右移 160
                mstore(
                    add(0xa0, commissionInfo),
                    shr(160, and(commissionData, _COMMISSION_RATE_MASK))
                ) // 1st commissionRate
                // 第 1 个推荐人地址(偏移 0xc0)：取低 160 位
                mstore(
                    add(0xc0, commissionInfo),
                    and(commissionData, _ADDRESS_MASK)
                ) // 1st referrerAddress
                // 再往前读一个槽：含 token 地址与 toB 标志
                commissionData := calldataload(sub(effectiveEnd, 0x40))
                // toBCommission 默认 1(非 toB)；若 bit255 置位则为 2(toB)
                let toBCommission := NO_TO_B_MODE // default toBCommission is 1 for no-toB commission when commissionData exists
                if gt(and(commissionData, _TO_B_COMMISSION_MASK), 0) {
                    toBCommission := TO_B_MODE // toB commission value when commissionData exists
                }
                // 写 toBCommission(偏移 0x60)
                mstore(
                    add(0x60, commissionInfo),
                    toBCommission //toBCommission
                )
                // 写佣金币种 token(偏移 0x40)：取低 160 位
                mstore(
                    add(0x40, commissionInfo),
                    and(commissionData, _ADDRESS_MASK) //token
                )
                // MULTIPLE 模式(referrerNum 暂置为 3)：从该槽读出真实编码的推荐人数并校验
                // For multiple commission mode, load the encoded commission length and validate
                if gt(referrerNum, 2) {
                    // 真实人数 = 取 length 位段后右移 240
                    referrerNum := shr(
                        240,
                        and(commissionData, _COMMISSION_LENGTH_MASK)
                    )
                    // 校验人数在 [MIN_COMMISSION_MULTIPLE_NUM, MAX_COMMISSION_MULTIPLE_NUM] 即 [3,8] 之间
                    // require(referrerNum >= MIN_COMMISSION_MULTIPLE_NUM && referrerNum <= MAX_COMMISSION_MULTIPLE_NUM, "invalid referrer num")
                    if or(
                        lt(referrerNum, MIN_COMMISSION_MULTIPLE_NUM),
                        gt(referrerNum, MAX_COMMISSION_MULTIPLE_NUM)
                    ) {
                        _revertWithReason(
                            0x00000014696e76616c6964207265666572726572206e756d0000000000000000,
                            0x58
                        ) // "invalid referrer num"
                    }
                }
                // 写推荐人个数 commissionLength(偏移 0x80)
                mstore(add(0x80, commissionInfo), referrerNum) //commissionLength
            }
            default {
                // 无佣金：把 token ~ 所有佣金对 的内存槽清零，避免脏数据
                // eraseNum = 2*MAX + 3 = token + toBCommission + commissionLength + 8 个(rate,addr)对
                let eraseNum := add(mul(MAX_COMMISSION_MULTIPLE_NUM, 2), 3) // 2 * MAX_COMMISSION_MULTIPLE_NUM + 3: token, toBCommission, commissionLength and all commission pairs
                for {
                    let i := 0
                } lt(i, eraseNum) {
                    i := add(i, 1)
                } {
                    // 从偏移 0x40 起逐个 32 字节槽清零
                    mstore(add(add(commissionInfo, 0x40), mul(i, 0x20)), 0) // erase commissionInfo.token ~ all commission pairs
                }
            }
            // 多于 1 个推荐人时，循环解析第 2~N 个佣金对(第 1 个已在上面处理)
            if gt(referrerNum, 1) {
                // 固定遍历到 MAX(8)：i < referrerNum 的是有效对、否则擦除，保证内存干净
                for {
                    let i := 1
                } lt(i, MAX_COMMISSION_MULTIPLE_NUM) {
                    i := add(i, 1)
                } {
                    switch lt(i, referrerNum) // if i < referrerNum, the i-th commission pair is valid
                    case 1 {
                        // 读第 i 个佣金对所在的槽
                        commissionData := calldataload(
                            sub(effectiveEnd, add(0x40, mul(i, 0x20)))
                        )
                        // 校验每个佣金对的 flag 必须与首个一致，防止混入不同类型
                        let flag2 := and(commissionData, _COMMISSION_FLAG_MASK)
                        if iszero(eq(flag, flag2)) {
                            _revertWithReason(
                                0x00000017696e76616c696420636f6d6d697373696f6e20666c61670000000000,
                                0x5b
                            ) // "invalid commission flag"
                        }
                        mstore(
                            add(add(0xa0, commissionInfo), mul(i, 0x40)), // 0xa0: commissionRate0, 0xa0 + 0x40 * i: i-th commissionRate
                            shr(160, and(commissionData, _COMMISSION_RATE_MASK))
                        ) //i-th commissionRate
                        mstore(
                            add(add(0xc0, commissionInfo), mul(i, 0x40)), // 0xc0: referrerAddress0, 0xc0 + 0x40 * i: i-th referrerAddress
                            and(commissionData, _ADDRESS_MASK)
                        ) //i-th referrerAddress
                    }
                    default {
                        // if i >= referrerNum, the i-th commission pair is invalid, and erase it
                        mstore(add(add(0xa0, commissionInfo), mul(i, 0x40)), 0) // erase i-th commissionRate
                        mstore(add(add(0xc0, commissionInfo), mul(i, 0x40)), 0) // erase i-th referrerAddress
                    }
                }
            }
            // 计算佣金部分占用的 calldata 槽数，得到 Trim 数据的起始偏移 offset
            // offset = (referrerNum + 1) * 32：referrerNum 个佣金对 + 1 个 token/标志槽；无佣金则 offset=0
            // calculate offset based on referrerNum
            let offset := 0
            if gt(referrerNum, 0) {
                offset := mul(add(referrerNum, 1), 0x20)
            }
            // 读 Trim 的第一个槽(跳过佣金占用的 offset)
            // get first bytes32 of trim data
            let trimData := calldataload(sub(effectiveEnd, add(offset, 0x20)))
            // 取 flag 判断是否有 Trim(单组 TRIM_FLAG 或 DUAL TRIM_DUAL_FLAG)
            flag := and(trimData, _TRIM_FLAG_MASK)
            let hasTrim := or(eq(flag, TRIM_FLAG), eq(flag, TRIM_DUAL_FLAG))
            // 写 hasTrim(偏移 0x00)
            mstore(trimInfo, hasTrim) // hasTrim
            // 有 Trim 才解析其字段，否则走 default 把相关槽清零
            switch eq(hasTrim, 1)
            case 1 {
                // trimRate(偏移 0x20)：取 rate 位段右移 160
                mstore(
                    add(0x20, trimInfo),
                    shr(160, and(trimData, _TRIM_RATE_MASK))
                ) // trimRate
                // trimAddress(偏移 0x40)：取低 160 位
                mstore(
                    add(0x40, trimInfo),
                    and(trimData, _TRIM_EXPECT_AMOUNT_OUT_OR_ADDRESS_MASK)
                ) // trimAddress
                // 读 Trim 的第二个槽(含 toB 标志与 expectAmountOut)
                // get second bytes32 of trim data
                trimData := calldataload(sub(effectiveEnd, add(offset, 0x40)))
                // 校验第二槽的 flag 与第一槽一致
                let flag2 := and(trimData, _TRIM_FLAG_MASK)
                if iszero(eq(flag, flag2)) {
                    _revertWithReason(
                        0x00000011696e76616c6964207472696d20666c61670000000000000000000000,
                        0x55
                    ) // "invalid trim flag"
                }
                // toBTrim 默认 1(非 toB)；bit191 置位则为 2(toB)
                let toBTrim := NO_TO_B_MODE // default toBTrim is 1 for no-toB trim when trimData exists
                if gt(and(trimData, _TO_B_TRIM_MASK), 0) {
                    toBTrim := TO_B_MODE // toB trim value when trimData exists
                }
                // 写 toBTrim(偏移 0x60)
                mstore(
                    add(0x60, trimInfo),
                    toBTrim //toBTrim
                )
                // 写 expectAmountOut(偏移 0x80)：取该槽低 160 位
                mstore(
                    add(0x80, trimInfo),
                    and(trimData, _TRIM_EXPECT_AMOUNT_OUT_OR_ADDRESS_MASK)
                ) // expectAmountOut
            }
            default {
                // 无 Trim：清零 trimRate/trimAddress/toBTrim/expectAmountOut
                mstore(add(0x20, trimInfo), 0) // trimRate
                mstore(add(0x40, trimInfo), 0) // trimAddress
                mstore(add(0x60, trimInfo), 0) // toBTrim
                mstore(add(0x80, trimInfo), 0) // expectAmountOut
            }
            // 仅 DUAL Trim 才有第三个槽(charge 相关)；普通 Trim 走 default 清零
            switch eq(flag, TRIM_DUAL_FLAG)
            case 1 {
                // 读 Trim 的第三个槽(含 chargeRate 与 chargeAddress)
                // get third bytes32 of trim data
                trimData := calldataload(sub(effectiveEnd, add(offset, 0x60)))
                // 校验 flag 一致
                let flag2 := and(trimData, _TRIM_FLAG_MASK)
                if iszero(eq(flag, flag2)) {
                    _revertWithReason(
                        0x00000011696e76616c6964207472696d20666c61670000000000000000000000,
                        0x55
                    ) // "invalid trim flag"
                }
                // chargeRate(偏移 0xa0)：取 rate 位段右移 160
                mstore(
                    add(0xa0, trimInfo),
                    shr(160, and(trimData, _TRIM_RATE_MASK))
                ) // chargeRate
                // chargeAddress(偏移 0xc0)：取低 160 位
                mstore(
                    add(0xc0, trimInfo),
                    and(trimData, _TRIM_EXPECT_AMOUNT_OUT_OR_ADDRESS_MASK)
                ) // chargeAddress
            }
            default {
                // 非 DUAL：清零 chargeRate/chargeAddress
                mstore(add(0xa0, trimInfo), 0) // chargeRate
                mstore(add(0xc0, trimInfo), 0) // chargeAddress
            }
        }

        // if (commissionInfo.isFromTokenCommission || commissionInfo.isToTokenCommission || trimInfo.hasTrim) {
        //     emit CommissionAndTrimInfo(
        //         commissionInfo.toBCommission,
        //         trimInfo.toBTrim,
        //         trimInfo.trimRate,
        //         trimInfo.chargeRate
        //     );
        // }
        // 若存在任一佣金或 Trim，则手动 emit CommissionAndTrimInfo 事件(log1，省字节码)
        assembly ("memory-safe") {
            // 条件：isFromTokenCommission || isToTokenCommission || hasTrim
            if or(
                or(mload(commissionInfo), mload(add(commissionInfo, 0x20))),
                mload(trimInfo)
            ) {
                // 在空闲内存依次写入 4 个事件参数
                let ptr := mload(0x40)
                mstore(ptr, mload(add(commissionInfo, 0x60))) // toBCommission
                mstore(add(ptr, 0x20), mload(add(trimInfo, 0x60))) // toBTrim
                mstore(add(ptr, 0x40), mload(add(trimInfo, 0x20))) // trimRate
                mstore(add(ptr, 0x60), mload(add(trimInfo, 0xa0))) // chargeRate
                // log1：1 个 topic(事件签名哈希) + 0x80 字节数据
                log1(
                    ptr,
                    0x80,
                    0x7970b0744fdb6cf0b120e5e0a5f4da3ab8cbec6d5d9ec8a4f327ccc1d8a5eb8b
                )
                // 推进 free memory pointer
                mstore(0x40, add(ptr, 0x80))
            }
        }
    }

    /**
     * @notice 查询 user 持有 token 的余额，自动区分原生 ETH 与 ERC20。
     * @dev token == _ETH 时返回 balance(user)（原生余额）；否则 staticcall balanceOf(user)，失败则 revert。
     * @param token 代币地址（ETH 用占位地址 _ETH）
     * @param user  被查询地址
     * @return amount 余额
     */
    function _getBalanceOf(
        address token,
        address user
    ) internal returns (uint256 amount) {
        assembly {
            // 手工模拟 revert("xxx") / require(_,"xxx")：按内置 Error(string) 的 ABI 布局写入
            // 选择器(0x08c379a0) / 数据偏移(0x20) / 字符串(长度+内容打包在 m) 后 revert，省 gas。
            //
            // 注意这里按 32 字节对齐写(0/0x20/0x40)，但 selector 只占前 4 字节，会把后续字段整体右移 4 字节。
            // 从 0x00 连续读取的最终字节流为：
            //   [0x00..0x03] 08c379a0                      ← Error(string) 选择器(4字节)
            //   [0x04..0x23] 00..00 + 00 00 00 20          ← string 数据偏移量 offset = 32(0x20)
            //   [0x24..]     m 提供的 [长度 + 内容]          ← string 实际数据
            // 故第二个 mstore 的值要写成 0x00000020_00..00：把 0x20 放在该 word 的【高位第4字节】，
            // 正是为了抵消 selector 占用的前 4 字节，使其在字节流中落到 offset 字段处、被解码为 32。
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }
            switch eq(token, _ETH)
            case 1 {
                // token 是原生 ETH：直接取 user 的链上原生余额
                amount := balance(user)
            }
            default {
                // token 是 ERC20：手工拼 calldata 调用 balanceOf(user)
                let freePtr := mload(0x40)
                // 预留 0x24=36 字节缓冲(selector4 + 参数32)
                mstore(0x40, add(freePtr, 0x24))
                mstore(
                    freePtr,
                    0x70a0823100000000000000000000000000000000000000000000000000000000
                ) //balanceOf  选择器 0x70a08231 写在 [freePtr]
                // [freePtr+0x04] 参数 user
                mstore(add(freePtr, 0x04), user)
                // staticcall 只读调用：发送 0x24 字节，返回的 32 字节写到内存 0x00
                let success := staticcall(gas(), token, freePtr, 0x24, 0, 0x20)
                if eq(success, 0) {
                    // 入参为 "get balanceOf failed" 的 Error(string) 编码：
                    //   0x00000014 = 长度 20；后续是该字符串的 ASCII；末尾补 0
                    //   0x58 = 88 = revert 总长度(selector4 + offset32 + 长度32 + 内容20)
                    _revertWithReason(
                        0x000000146765742062616c616e63654f66206661696c65640000000000000000,
                        0x58
                    ) // "get balanceOf failed"
                }
                // 读取返回值即余额
                amount := mload(0x00)
            }
        }
    }

    /**
     * @notice 处理「输入端(fromToken)」佣金，并确定后续兑换的中间接收地址。
     * @dev 若需要在输出端再做佣金/Trim（isToTokenCommission 或 hasTrim），则把兑换产物先收到本合约
     *      （middleReceiver=address(this)）并记录兑换前余额 balanceBefore，供之后 _doCommissionAndTrimToToken 计算；
     *      否则 middleReceiver 直接设为最终 receiver。
     *      若是 fromToken 佣金，则调用 _doCommissionFromTokenInternal 从输入资金中抽佣给推荐人。
     * @param commissionInfo 佣金信息
     * @param payer          付款方（fromToken 佣金从这里拉款）
     * @param receiver       最终接收者
     * @param inputAmount    输入金额
     * @param hasTrim        是否需要做正滑点回收
     * @param toToken        输出代币
     * @return middleReceiver 兑换产物的中间接收地址（本合约或最终 receiver）
     * @return balanceBefore  若收到本合约，记录兑换前的 toToken 余额（用于后续差额计算）
     */
    function _doCommissionFromToken(
        CommissionInfo memory commissionInfo,
        address payer,
        address receiver,
        uint256 inputAmount,
        bool hasTrim,
        address toToken
    )
        internal
        override
        returns (address middleReceiver, uint256 balanceBefore)
    {
        // 若需要在输出端做佣金或正滑点回收(Trim)，则让兑换产物先收到本合约，
        // 以便事后用 (balanceAfter - balanceBefore) 算出实际产出再处理；故此处先记录兑换前余额。
        if (commissionInfo.isToTokenCommission || hasTrim) {
            middleReceiver = address(this);
            balanceBefore = _getBalanceOf(toToken, address(this));
        } else {
            // 无输出端佣金/Trim：兑换产物直接发给最终 receiver，无需经本合约中转
            middleReceiver = receiver;
        }

        // 输入端(fromToken)佣金：从输入资金中抽佣分给推荐人（实际执行在 internal 里）
        if (commissionInfo.isFromTokenCommission) {
            _doCommissionFromTokenInternal(commissionInfo, payer, inputAmount);
        }
    }

    /**
     * @notice 从输入端资金中抽取佣金并分发给各推荐人（fromToken 佣金的实际执行）。
     * @dev 全 assembly 实现，内部定义了 _mulDiv/_safeSub/_sendETH/_claimToken/_sendToken 等辅助。
     *      先累加所有推荐人 rate 得 totalRate 并校验 <= commissionRateLimit(3%)。按 token 与模式分三类：
     *        - token 是 ETH：逐个按 rate 计算并 _sendETH 给 referrer；
     *        - ERC20 且非 toB：逐个经 ApproveProxy.claimTokens 从 payer 拉款给 referrer；
     *        - ERC20 且 toB：先把总佣金 claim 到本合约，再按各 rate 占比缩放后分发(_sendTokenWithinBalanceAndEmitEvents)，
     *          最后一个推荐人拿剩余余额以消除取整误差。
     *      每笔分发用 log1 emit CommissionFromTokenRecord 事件。
     *      佣金额公式：amount = inputAmount * rate / (DENOMINATOR - totalRate)（佣金外加在输入额之上）。
     * @param commissionInfo 佣金信息（含 token、toBCommission、各 rate/referrer）
     * @param payer          付款方
     * @param inputAmount    输入金额（佣金计算基数）
     */
    function _doCommissionFromTokenInternal(
        CommissionInfo memory commissionInfo,
        address payer,
        uint256 inputAmount
    ) private {
        assembly ("memory-safe") {
            // ===== 内联辅助函数 =====
            // 安全的 x*y/d（防溢出），实现取自 Solady FixedPointMathLib
            // https://github.com/Vectorized/solady/blob/701406e8126cfed931645727b274df303fbcd94d/src/utils/FixedPointMathLib.sol#L595
            function _mulDiv(x, y, d) -> z {
                z := mul(x, y)
                // 等价于 require(d != 0 && (y == 0 || x <= type(uint256).max / y))：
                // 即 d 不为 0，且 x*y 未溢出（用 z/x==y 反验）；否则抛 MulDivFailed()
                if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                    mstore(0x00, 0xad251c27) // `MulDivFailed()`.
                    revert(0x1c, 0x04)
                }
                z := div(z, d)
            }
            // 安全减法：x < y 则抛 SafeSubFailed()，避免下溢回绕
            function _safeSub(x, y) -> z {
                if lt(x, y) {
                    mstore(0x00, 0x46e72d03) // `SafeSubFailed()`.
                    revert(0x1c, 0x04)
                }
                z := sub(x, y)
            }
            // 手工模拟 revert("xxx") / require(_,"xxx")：按内置 Error(string) 的 ABI 布局写入
            // 选择器(0x08c379a0) / 数据偏移(0x20) / 字符串(长度+内容打包在 m) 后 revert，省 gas。
            //
            // 注意这里按 32 字节对齐写(0/0x20/0x40)，但 selector 只占前 4 字节，会把后续字段整体右移 4 字节。
            // 从 0x00 连续读取的最终字节流为：
            //   [0x00..0x03] 08c379a0                      ← Error(string) 选择器(4字节)
            //   [0x04..0x23] 00..00 + 00 00 00 20          ← string 数据偏移量 offset = 32(0x20)
            //   [0x24..]     m 提供的 [长度 + 内容]          ← string 实际数据
            // 故第二个 mstore 的值要写成 0x00000020_00..00：把 0x20 放在该 word 的【高位第4字节】，
            // 正是为了抵消 selector 占用的前 4 字节，使其在字节流中落到 offset 字段处、被解码为 32。
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }
            // 给 to 转 amount 数量的原生 ETH（amount=0 时跳过）；失败则 revert
            function _sendETH(to, amount) {
                if gt(amount, 0) {
                    // call 转账：value=amount，无 calldata；转发全部 gas
                    let success := call(gas(), to, amount, 0, 0, 0, 0)
                    if eq(success, 0) {
                        _revertWithReason(
                            0x0000001b636f6d6d697373696f6e2077697468206574686572206572726f7200,
                            0x5f
                        ) // "commission with ether error"
                    }
                }
            }
            // 经 ApproveProxy 从 _payer 拉取 amount 数量的 token 给 to（用户只需对 ApproveProxy 授权）
            function _claimToken(token, _payer, to, amount) {
                if gt(amount, 0) {
                    let freePtr := mload(0x40)
                    // 预留 0x84=132 字节(selector4 + 4个参数*32)
                    mstore(0x40, add(freePtr, 0x84))
                    mstore(
                        freePtr,
                        0x0a5ea46600000000000000000000000000000000000000000000000000000000
                    ) // claimTokens(address,address,address,uint256) 选择器 0x0a5ea466
                    // 参数1 token
                    mstore(add(freePtr, 0x04), token)
                    // 参数2 from(付款方)
                    mstore(add(freePtr, 0x24), _payer)
                    // 参数3 to(收款方)
                    mstore(add(freePtr, 0x44), to)
                    // 参数4 amount
                    mstore(add(freePtr, 0x64), amount)
                    // 调用 ApproveProxy.claimTokens（它内部对 from 做 transferFrom）
                    let success := call(
                        gas(),
                        _APPROVE_PROXY,
                        0,
                        freePtr,
                        0x84,
                        0,
                        0
                    )
                    if eq(success, 0) {
                        _revertWithReason(
                            0x00000013636c61696d20746f6b656e73206661696c6564000000000000000000,
                            0x57
                        ) // "claim tokens failed"
                    }
                }
            }
            // 给 to 转 amount 数量的 ERC20 token（amount=0 时跳过）；兼容"不返回 bool"的 token；失败则 revert
            function _sendToken(token, to, amount) {
                if gt(amount, 0) {
                    let freePtr := mload(0x40)
                    // 预留 0x44=68 字节(selector4 + to32 + amount32)
                    mstore(0x40, add(freePtr, 0x44))
                    mstore(
                        freePtr,
                        0xa9059cbb00000000000000000000000000000000000000000000000000000000
                    ) // transfer(address,uint256) 选择器 0xa9059cbb
                    // 参数1 to
                    mstore(add(freePtr, 0x04), to)
                    // 参数2 amount
                    mstore(add(freePtr, 0x24), amount)
                    let success := call(gas(), token, 0, freePtr, 0x44, 0, 0x20)
                    // 返回值判定：若不是"返回了 true(32字节且==1)"，进一步用兼容规则判定
                    if and(
                        iszero(and(eq(mload(0), 1), gt(returndatasize(), 31))),
                        success
                    ) {
                        // 兼容无返回值 token：要求 目标是合约(extcodesize>0) 且 returndata 为空
                        success := iszero(
                            or(iszero(extcodesize(token)), returndatasize())
                        )
                    }
                    if eq(success, 0) {
                        _revertWithReason(
                            0x0000001b7472616e7366657220746f6b656e2072656665726572206661696c00,
                            0x5f
                        ) // "transfer token referer fail"
                    }
                }
            }
            // toB 模式专用：读取本合约【实际收到】的 token 余额，按各 referrer 的 rate 占比缩放后逐笔分发。
            // 按"实际余额"而非原始金额缩放，可适配转账扣费(fee-on-transfer)代币；最后一人拿剩余以消除取整误差。
            // 入参：
            //   token         —— 佣金代币地址（要分发的 ERC20）
            //   totalRate     —— 所有 referrer 的费率之和（作为占比缩放的分母）
            //   referrerNum   —— 推荐人个数（循环次数）
            //   commissionInfo_ —— CommissionInfo 结构体的内存指针；
            //                      第 i 个 rate 在偏移 0xa0 + i*0x40，第 i 个 referrer 地址在偏移 0xc0 + i*0x40
            function _sendTokenWithinBalanceAndEmitEvents(
                token,
                totalRate,
                referrerNum,
                commissionInfo_
            ) {
                // —— 查询本合约当前持有的 token 余额 balanceAfter ——
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x24))
                mstore(
                    freePtr,
                    0x70a0823100000000000000000000000000000000000000000000000000000000
                ) // balanceOf(address) 选择器
                // 参数 = 本合约地址
                mstore(add(freePtr, 0x4), address())
                let success := staticcall(gas(), token, freePtr, 0x24, 0, 0x20)
                if eq(success, 0) {
                    // 入参为 "get balanceOf failed" 的 Error(string) 编码：
                    //   0x00000014 = 长度 20；后续是该字符串的 ASCII；末尾补 0
                    //   0x58 = 88 = revert 总长度(selector4 + offset32 + 长度32 + 内容20)
                    _revertWithReason(
                        0x000000146765742062616c616e63654f66206661696c65640000000000000000,
                        0x58
                    ) // "get balanceOf failed"
                }
                // balanceAfter = 本合约该 token 的当前余额，即"待分给所有 referrer 的佣金总额"。
                // 注意是【实际到账额】(balanceOf 实测)，而非名义 totalAmount：
                //   - 对转账扣费(fee-on-transfer)代币，实际到账可能少于名义额，按真实余额分配才不会超分；
                //   - 严格说是本合约该 token 的全部余额，正常佣金流程下即等于本次拉入的总佣金。
                // 后续按各 referrer 占比从中切分，最后一人拿剩余，分完精确归零。
                let balanceAfter := mload(0x00)
                // 已分发出去的累计额
                let sendAmount := 0
                // —— 逐个 referrer 缩放分发 ——
                for {
                    let i := 0
                } lt(i, referrerNum) {
                    i := add(i, 1)
                } {
                    let rate := mload(
                        // 第 i 个 referrer 的 rate(偏移 0xa0 + i*0x40)
                        add(commissionInfo_, add(0xa0, mul(i, 0x40)))
                    )
                    // amountScaled = 本轮实际要转给第 i 个 referrer 的 token 数量
                    // （从 balanceAfter 总额中按其 rate 占比"缩放"切分得到，故名 scaled）
                    let amountScaled
                    switch eq(i, sub(referrerNum, 1))
                    case 1 {
                        // 最后一个 referrer：直接拿"剩余全部"= balanceAfter - sendAmount，消除整除余数、精确清零
                        amountScaled := _safeSub(balanceAfter, sendAmount)
                    }
                    default {
                        // 非最后一个：按占比缩放 amountScaled = (rate/totalRate) * balanceAfter
                        // 拆成两次 _mulDiv 并以 WAD 为中间精度，减少精度损失
                        amountScaled := _mulDiv(
                            _mulDiv(rate, WAD, totalRate),
                            balanceAfter,
                            WAD
                        )
                        if gt(amountScaled, balanceAfter) {
                            _revertWithReason(
                                0x00000014696e76616c696420616d6f756e745363616c65640000000000000000,
                                0x58
                            ) // "invalid amountScaled"
                        }
                        // 累计已分发
                        sendAmount := add(sendAmount, amountScaled)
                    }
                    let referrer := mload(
                        // 第 i 个 referrer 地址(偏移 0xc0 + i*0x40)
                        add(commissionInfo_, add(0xc0, mul(i, 0x40)))
                    )
                    // 从本合约转给该 referrer
                    _sendToken(token, referrer, amountScaled)
                    _emitCommissionFromToken(
                        token,
                        amountScaled,
                        referrer,
                        rate
                    ) // 记录事件
                }
            }
            // 手动 emit CommissionFromTokenRecord 事件(log1)：把 4 个参数依次写入内存再发日志
            function _emitCommissionFromToken(token, amount, referrer, rate) {
                let freePtr := mload(0x40)
                // 4 个参数 * 32 字节 = 0x80
                mstore(0x40, add(freePtr, 0x80))
                // 参数1 token
                mstore(freePtr, token)
                // 参数2 commissionAmount
                mstore(add(freePtr, 0x20), amount)
                // 参数3 referrer
                mstore(add(freePtr, 0x40), referrer)
                // 参数4 rate
                mstore(add(freePtr, 0x60), rate)
                // log1：1 个 topic(事件签名哈希) + 0x80 字节数据
                log1(
                    freePtr,
                    0x80,
                    0xcd5eae9d9d0b96532bd1b7dbf6628ce436b2af735829087a03c548439f8bf850
                ) //emit CommissionFromTokenRecord(address,uint256,address,uint256)
            }

            // ===== 主流程：读取佣金参数并校验 =====
            // 偏移 0x40: 佣金币种 token
            let token := mload(add(commissionInfo, 0x40))
            // 偏移 0x60: toB 模式标记(1=非toB, 2=toB)
            let toBCommission := mload(add(commissionInfo, 0x60))
            let totalRate := 0
            // 偏移 0x80: 推荐人个数
            let referrerNum := mload(add(commissionInfo, 0x80))
            // 累加所有推荐人的 rate 得到总费率 totalRate
            for {
                let i := 0
            } lt(i, referrerNum) {
                i := add(i, 1)
            } {
                // 第 i 个 rate
                let rate := mload(add(commissionInfo, add(0xa0, mul(i, 0x40))))
                totalRate := add(totalRate, rate)
            }
            // 校验总费率不超过上限(commissionRateLimit = 3%)
            if gt(totalRate, commissionRateLimit) {
                _revertWithReason(
                    0x000000156572726f7220636f6d6d697373696f6e207261746500000000000000,
                    0x59
                ) // "error commission rate"
            }
            // 分支1：佣金币种是原生 ETH —— toB / 非 toB 处理相同(都直接从本合约余额转)
            if eq(token, _ETH) {
                // commission token is ETH, the process is same between no toB mode and toB mode
                for {
                    let i := 0
                } lt(i, referrerNum) {
                    i := add(i, 1)
                } {
                    let rate := mload(
                        // 第 i 个 rate
                        add(commissionInfo, add(0xa0, mul(i, 0x40)))
                    )
                    let referrer := mload(
                        // 第 i 个 referrer
                        add(commissionInfo, add(0xc0, mul(i, 0x40)))
                    )
                    // 佣金额 = inputAmount * rate / (DENOMINATOR - totalRate)
                    // 【佣金外加】语义：用户的 inputAmount 全部用于兑换，佣金额外加在其上；
                    //   且 rate 表示佣金占"总额"的比例(而非占 inputAmount 的比例)。
                    // 推导：令 X = 用户总支付额 = inputAmount(用于兑换) + 总佣金(付给推荐人)。
                    //   约定 总佣金 = X*totalRate/DENOMINATOR（佣金按占 X 的比例算）。
                    //   因 X 同时出现在等式两边(X 含佣金、佣金又依赖 X)，解方程：
                    //     X = inputAmount + X*totalRate/DENOMINATOR
                    //     → X = inputAmount*DENOMINATOR/(DENOMINATOR - totalRate)
                    //   代入单个佣金 = X*rate/DENOMINATOR = inputAmount*rate/(DENOMINATOR - totalRate)。
                    // 数学结构同"不含税价反推税额"：分母用 (DENOMINATOR - totalRate) 而非 DENOMINATOR。
                    // 例：inputAmount=1000、totalRate=10% → X=1111.1，总佣金=111.1(=X 的10%)，兑换仍用 1000。
                    let amount := div(
                        mul(inputAmount, rate),
                        sub(DENOMINATOR, totalRate)
                    )
                    // 直接转 ETH 给 referrer
                    _sendETH(referrer, amount)
                    // 记录 CommissionFromTokenRecord 事件
                    _emitCommissionFromToken(_ETH, amount, referrer, rate)
                }
            }
            // 分支2：佣金币种是 ERC20 且【非 toB】模式 —— 逐笔直接从 payer 拉款给每个 referrer
            if and(iszero(eq(token, _ETH)), eq(toBCommission, NO_TO_B_MODE)) {
                // commission token is ERC20 with no toB mode
                // 遍历每个 referrer，各自独立从 payer 拉佣金（无归集步骤，与 toB 模式相对）
                for {
                    let i := 0
                } lt(i, referrerNum) {
                    i := add(i, 1)
                } {
                    // 第 i 个 referrer 的 rate(偏移 0xa0 + i*0x40)
                    let rate := mload(
                        add(commissionInfo, add(0xa0, mul(i, 0x40)))
                    )
                    // 第 i 个 referrer 地址(偏移 0xc0 + i*0x40)
                    let referrer := mload(
                        add(commissionInfo, add(0xc0, mul(i, 0x40)))
                    )
                    // 单个佣金额(佣金外加，推导见上方分支1注释) = inputAmount*rate/(DENOMINATOR - totalRate)
                    let amount := div(
                        mul(inputAmount, rate),
                        sub(DENOMINATOR, totalRate)
                    )
                    // 经 ApproveProxy 从 payer 直接拉款给该 referrer
                    _claimToken(token, payer, referrer, amount)
                    // 记录 CommissionFromTokenRecord 事件
                    _emitCommissionFromToken(token, amount, referrer, rate)
                }
            }
            // 分支3：佣金币种是 ERC20 且【toB】模式 —— 先把总佣金一次性归集到本合约，再按比例缩放分发
            if and(iszero(eq(token, _ETH)), eq(toBCommission, TO_B_MODE)) {
                // commission token is ERC20 with toB mode
                // 总佣金 = inputAmount * totalRate / (DENOMINATOR - totalRate)
                // 同样是"佣金外加"(推导见上方分支1注释)，只是这里用 totalRate 一次性算出所有人的佣金总和
                let totalAmount := div(
                    mul(inputAmount, totalRate),
                    sub(DENOMINATOR, totalRate)
                )
                // 经 ApproveProxy 把总佣金一次性从 payer 拉到本合约(address())
                _claimToken(token, payer, address(), totalAmount)
                // 读本合约实际到账余额，按各 referrer 的 rate 占比缩放后逐笔分发并 emit 事件
                _sendTokenWithinBalanceAndEmitEvents(
                    token,
                    totalRate,
                    referrerNum,
                    commissionInfo
                )
            }
        }
    }

    /**
     * @notice 处理「输出端(toToken)」佣金 + 正滑点回收(Trim)，并把净额转给最终接收者。
     * @dev 仅当 isToTokenCommission 或 hasTrim 时执行（否则直接返回 0）。流程（全 assembly）：
     *        1. 用 balanceAfter - balanceBefore 得到本次兑换实际产出 inputAmount（要求 after > before）；
     *        2. 若 toToken 佣金：_processCommission 按各 rate 从产出中抽佣给推荐人，扣减 inputAmount；
     *        3. 若 hasTrim 且 inputAmount > expectAmountOut：_processTrim 回收正滑点——
     *           trimAmount = min(inputAmount - expectAmountOut, inputAmount*trimRate/1000)，
     *           再按 chargeRate 拆成 trim 部分与 charge 部分，分别转给 trimAddress / chargeAddress；
     *        4. 把剩余净额转给 receiver（ETH 用 _sendETH，ERC20 用 _sendToken）。
     *      各步用 log1 emit 对应事件。
     * @param commissionInfo 佣金信息
     * @param receiver       最终接收者（低 160 位有效）
     * @param balanceBefore  兑换前本合约的 toToken 余额（来自 _doCommissionFromToken）
     * @param toToken        输出代币
     * @param trimInfo       正滑点回收信息
     * @return totalAmount   被抽走的总额（佣金 + trim），其余净额已发给 receiver
     */
    function _doCommissionAndTrimToToken(
        CommissionInfo memory commissionInfo,
        address receiver,
        uint256 balanceBefore,
        address toToken,
        TrimInfo memory trimInfo
    ) internal override returns (uint256 totalAmount) {
        if (!commissionInfo.isToTokenCommission && !trimInfo.hasTrim) {
            return 0;
        }
        uint256 balanceAfter = _getBalanceOf(toToken, address(this));
        assembly ("memory-safe") {
            // ===== 内联辅助函数 =====
            // 安全的 x*y/d（防溢出），实现取自 Solady FixedPointMathLib
            // https://github.com/Vectorized/solady/blob/701406e8126cfed931645727b274df303fbcd94d/src/utils/FixedPointMathLib.sol#L595
            function _mulDiv(x, y, d) -> z {
                z := mul(x, y)
                // 等价于 require(d != 0 && (y == 0 || x <= type(uint256).max / y))：
                // 即 d 不为 0，且 x*y 未溢出（用 z/x==y 反验）；否则抛 MulDivFailed()
                if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                    mstore(0x00, 0xad251c27) // `MulDivFailed()`.
                    revert(0x1c, 0x04)
                }
                z := div(z, d)
            }
            // 安全减法：x < y 则抛 SafeSubFailed()，避免下溢回绕
            function _safeSub(x, y) -> z {
                if lt(x, y) {
                    mstore(0x00, 0x46e72d03) // `SafeSubFailed()`.
                    revert(0x1c, 0x04)
                }
                z := sub(x, y)
            }
            // 手工模拟 revert("xxx") / require(_,"xxx")：按内置 Error(string) 的 ABI 布局写入
            // 选择器(0x08c379a0) / 数据偏移(0x20) / 字符串(长度+内容打包在 m) 后 revert，省 gas。
            //
            // 注意这里按 32 字节对齐写(0/0x20/0x40)，但 selector 只占前 4 字节，会把后续字段整体右移 4 字节。
            // 从 0x00 连续读取的最终字节流为：
            //   [0x00..0x03] 08c379a0                      ← Error(string) 选择器(4字节)
            //   [0x04..0x23] 00..00 + 00 00 00 20          ← string 数据偏移量 offset = 32(0x20)
            //   [0x24..]     m 提供的 [长度 + 内容]          ← string 实际数据
            // 故第二个 mstore 的值要写成 0x00000020_00..00：把 0x20 放在该 word 的【高位第4字节】，
            // 正是为了抵消 selector 占用的前 4 字节，使其在字节流中落到 offset 字段处、被解码为 32。
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }
            // 给 to 转 amount 数量的原生 ETH（amount=0 时跳过）；call 转发全部 gas，失败则 revert
            function _sendETH(to, amount) {
                if gt(amount, 0) {
                    let success := call(gas(), to, amount, 0, 0, 0, 0)
                    if eq(success, 0) {
                        _revertWithReason(
                            0x0000001173656e64206574686572206661696c65640000000000000000000000,
                            0x55
                        ) // "send ether failed"
                    }
                }
            }
            // 给 to 转 amount 数量的 ERC20 token（amount=0 时跳过）；兼容"不返回 bool"的 token；失败则 revert
            function _sendToken(token, to, amount) {
                if gt(amount, 0) {
                    let freePtr := mload(0x40)
                    // 预留 0x44=68 字节(selector4 + to32 + amount32)
                    mstore(0x40, add(freePtr, 0x44))
                    mstore(
                        freePtr,
                        0xa9059cbb00000000000000000000000000000000000000000000000000000000
                    ) // transfer(address,uint256) 选择器 0xa9059cbb
                    // 参数1 to
                    mstore(add(freePtr, 0x04), to)
                    // 参数2 amount
                    mstore(add(freePtr, 0x24), amount)
                    let success := call(gas(), token, 0, freePtr, 0x44, 0, 0x20)
                    // 若不是"返回了 true(32字节且==1)"，再用兼容规则判定
                    if and(
                        iszero(and(eq(mload(0), 1), gt(returndatasize(), 31))),
                        success
                    ) {
                        // 兼容无返回值 token：要求 目标是合约(extcodesize>0) 且 returndata 为空
                        success := iszero(
                            or(iszero(extcodesize(token)), returndatasize())
                        )
                    }
                    if eq(success, 0) {
                        _revertWithReason(
                            0x000000157472616e7366657220746f6b656e206661696c656400000000000000,
                            0x59
                        ) // "transfer token failed"
                    }
                }
            }
            // 手动 emit CommissionToTokenRecord 事件(log1)：4 个参数(token/amount/referrer/rate)依次写内存再发日志
            function _emitCommissionToToken(token, amount, referrer, rate) {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x80))
                mstore(freePtr, token)
                mstore(add(freePtr, 0x20), amount)
                mstore(add(freePtr, 0x40), referrer)
                mstore(add(freePtr, 0x60), rate)
                log1(
                    freePtr,
                    0x80,
                    0x3cfb523a4c38d88561dd3bf04805a31715c8b5fc468a03b8d684356f360dea99
                ) //emit CommissionToTokenRecord(address,uint256,address,uint256)
            }
            // 手动 emit PositiveSlippageTrimRecord 事件(log1)：3 个参数(token/trimAmount/trimAddress)
            function _emitPositiveSlippageTrimRecord(
                token,
                trimAmount,
                trimAddress
            ) {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x60))
                mstore(freePtr, token)
                mstore(add(freePtr, 0x20), trimAmount)
                mstore(add(freePtr, 0x40), trimAddress)
                log1(
                    freePtr,
                    0x60,
                    0x7bec7d55a62a7a7b8068f1533e2a3bbf727b3e2e57f30c576fe159da60e09a65
                ) // emit PositiveSlippageTrimRecord(address,uint256,address)
            }
            // 手动 emit PositiveSlippageChargeRecord 事件(log1)：3 个参数(token/chargeAmount/chargeAddress)
            function _emitPositiveSlippageChargeRecord(
                token,
                chargeAmount,
                chargeAddress
            ) {
                let freePtr := mload(0x40)
                mstore(0x40, add(freePtr, 0x60))
                mstore(freePtr, token)
                mstore(add(freePtr, 0x20), chargeAmount)
                mstore(add(freePtr, 0x40), chargeAddress)
                log1(
                    freePtr,
                    0x60,
                    0xfd08115c8e43d2a49d95ee18d7f69b8bbac60bd368c73cf22d30664a22a0626d
                ) // emit PositiveSlippageChargeRecord(address,uint256,address)
            }
            // 输出端佣金处理：从兑换产出 inputAmount 中按各 referrer 的 rate【内扣】佣金并分发，返回抽走的佣金总额。
            // 注意与输入端不同：这里用 _mulDiv(inputAmount, rate, DENOMINATOR)【内扣】(分母 DENOMINATOR)，
            // 而非输入端的"佣金外加"(分母 DENOMINATOR - totalRate)。因为这里是从已得到的产物里直接切，故内扣。
            // 入参：
            //   commissionInfo_ —— CommissionInfo 结构体内存指针（rate 在偏移 0xa0+i*0x40，referrer 在 0xc0+i*0x40）
            //   toToken_        —— 输出代币（_ETH 表示原生币）
            //   inputAmount     —— 本次兑换的产出额（佣金计算基数）
            // 返回：
            //   commissionAmount —— 实际抽走的佣金总额（供主流程从产出中扣减）
            function _processCommission(commissionInfo_, toToken_, inputAmount)
                -> commissionAmount
            {
                // —— 先累加所有 referrer 的 rate 得到 totalRate（仅用于校验上限）——
                // 推荐人个数(偏移 0x80)
                let referrerNum := mload(add(commissionInfo_, 0x80))
                let totalRate := 0
                for {
                    let i := 0
                } lt(i, referrerNum) {
                    i := add(i, 1)
                } {
                    // 第 i 个 referrer 的 rate(偏移 0xa0 + i*0x40)
                    let rate := mload(
                        add(commissionInfo_, add(0xa0, mul(i, 0x40)))
                    )
                    totalRate := add(totalRate, rate)
                }
                // 校验总费率不超过上限(commissionRateLimit = 3%)
                if gt(totalRate, commissionRateLimit) {
                    _revertWithReason(
                        0x000000156572726f7220636f6d6d697373696f6e207261746500000000000000,
                        0x59
                    ) // "error commission rate"
                }
                // 累计已抽走的佣金
                commissionAmount := 0
                // 按输出币种是否为 ETH 分两支处理（仅转账方式不同：_sendETH vs _sendToken）
                switch eq(toToken_, _ETH)
                case 1 {
                    // —— 分支A：输出币是原生 ETH ——
                    for {
                        let i := 0
                    } lt(i, referrerNum) {
                        i := add(i, 1)
                    } {
                        // 第 i 个 referrer 的 rate
                        let rate := mload(
                            add(commissionInfo_, add(0xa0, mul(i, 0x40)))
                        )
                        // 该 referrer 的佣金额(内扣) = inputAmount * rate / DENOMINATOR
                        let amount := _mulDiv(inputAmount, rate, DENOMINATOR)
                        // 第 i 个 referrer 地址(偏移 0xc0 + i*0x40)
                        let referrer := mload(
                            add(commissionInfo_, add(0xc0, mul(i, 0x40)))
                        )
                        // 转 ETH 给该 referrer
                        _sendETH(referrer, amount)
                        // 记录 CommissionToTokenRecord 事件
                        _emitCommissionToToken(_ETH, amount, referrer, rate)
                        // 累加进已抽走的佣金总额
                        commissionAmount := add(commissionAmount, amount)
                    }
                }
                default {
                    // —— 分支B：输出币是 ERC20 ——
                    for {
                        let i := 0
                    } lt(i, referrerNum) {
                        i := add(i, 1)
                    } {
                        // 第 i 个 referrer 的 rate
                        let rate := mload(
                            add(commissionInfo_, add(0xa0, mul(i, 0x40)))
                        )
                        // 该 referrer 的佣金额(内扣) = inputAmount * rate / DENOMINATOR
                        let amount := _mulDiv(inputAmount, rate, DENOMINATOR)
                        // 第 i 个 referrer 地址(偏移 0xc0 + i*0x40)
                        let referrer := mload(
                            add(commissionInfo_, add(0xc0, mul(i, 0x40)))
                        )
                        // 转 ERC20 给该 referrer
                        _sendToken(toToken_, referrer, amount)
                        // 记录 CommissionToTokenRecord 事件
                        _emitCommissionToToken(toToken_, amount, referrer, rate)
                        // 累加进已抽走的佣金总额
                        commissionAmount := add(commissionAmount, amount)
                    }
                }
            }
            // 正滑点回收(Trim)处理：兑换实际产出 inputAmount 超过用户预期 expectAmountOut 的部分称为"正滑点"，
            // 本函数把这部分（受 trimRate 上限约束）回收，并按 chargeRate 拆成"trim"与"charge"两份分别转给两个地址。
            //
            // 重要：回收额被 trimRate 封顶——实际回收 = min(名义正滑点, inputAmount*trimRate/1000)。
            // 当名义正滑点(inputAmount - expectAmountOut)超过该上限时，【超出上限的部分不回收】，
            // 它会留在 inputAmount 中、由主流程最终转给【用户 receiver】。即 trimRate 是平台回收正滑点的封顶比例，
            // 超过封顶的正滑点全部让利给用户（用户不仅拿到预期输出，还能分到大部分超额的正滑点收益）。
            // 入参：
            //   trimInfo_   —— TrimInfo 结构体内存指针（trimRate@0x20, trimAddress@0x40, expectAmountOut@0x80,
            //                  chargeRate@0xa0, chargeAddress@0xc0）
            //   toToken_    —— 输出代币（_ETH 表示原生币）
            //   inputAmount —— 本次兑换的实际产出（已扣除输出端佣金后的余额）
            // 返回：
            //   trimAmount  —— 实际回收的正滑点总额（= 转给 trimAddress 的部分 + 转给 chargeAddress 的部分），
            //                  供主流程从产出中扣减
            function _processTrim(trimInfo_, toToken_, inputAmount)
                -> trimAmount
            {
                // trimRate：回收比例上限标尺(偏移 0x20)，以 TRIM_DENOMINATOR=1000 为基准
                let trimRate := mload(add(trimInfo_, 0x20))
                // chargeRate：回收额中划给 charge 地址的占比(偏移 0xa0)，以 TRIM_DENOMINATOR=1000 为基准
                let chargeRate := mload(add(trimInfo_, 0xa0))
                // 校验 trimRate <= TRIM_RATE_LIMIT(=100，即回收上限不超过本金的 10%)
                if gt(trimRate, TRIM_RATE_LIMIT) {
                    _revertWithReason(
                        0x0000000f6572726f72207472696d207261746500000000000000000000000000,
                        0x53
                    ) // "error trim rate"
                }
                // 校验 chargeRate <= TRIM_DENOMINATOR(=1000，即 charge 占比不超过 100%)
                if gt(chargeRate, TRIM_DENOMINATOR) {
                    _revertWithReason(
                        0x000000116572726f722063686172676520726174650000000000000000000000,
                        0x55
                    ) // "error charge rate"
                }
                // 预期输出额 expectAmountOut(偏移 0x80)
                let expectAmountOut := mload(add(trimInfo_, 0x80))
                // 名义正滑点 = 实际产出 - 预期输出（调用前主流程已确保 inputAmount > expectAmountOut，不会下溢）
                trimAmount := sub(inputAmount, expectAmountOut)
                // 允许回收的上限 = inputAmount * trimRate / 1000（防止把过多产出当滑点回收）
                let allowedMaxTrimAmount := _mulDiv(
                    inputAmount,
                    trimRate,
                    TRIM_DENOMINATOR
                )
                // 实际回收额 = min(名义正滑点, 允许上限)
                if gt(trimAmount, allowedMaxTrimAmount) {
                    trimAmount := allowedMaxTrimAmount
                }

                // —— 把回收额 trimAmount 拆成 charge 部分与 trim 部分 ——
                // charge 部分 = trimAmount * chargeRate / 1000（划给 chargeAddress）
                let actualChargeAmount := _mulDiv(
                    trimAmount,
                    chargeRate,
                    TRIM_DENOMINATOR
                )
                // trim 部分 = 回收额剩余（划给 trimAddress）
                let actualTrimAmount := sub(trimAmount, actualChargeAmount)
                // 按输出币种是否为 ETH 分两支（仅转账方式不同：_sendETH vs _sendToken）
                switch eq(toToken_, _ETH)
                case 1 {
                    // —— 分支A：输出币是原生 ETH ——
                    // trim 接收地址(偏移 0x40)
                    let trimAddress := mload(add(trimInfo_, 0x40))
                    // 转 trim 部分给 trimAddress 并 emit 事件
                    _sendETH(trimAddress, actualTrimAmount)
                    _emitPositiveSlippageTrimRecord(
                        _ETH,
                        actualTrimAmount,
                        trimAddress
                    )

                    // charge 接收地址(偏移 0xc0)
                    let chargeAddress := mload(add(trimInfo_, 0xc0))
                    // 转 charge 部分给 chargeAddress 并 emit 事件
                    _sendETH(chargeAddress, actualChargeAmount)
                    _emitPositiveSlippageChargeRecord(
                        _ETH,
                        actualChargeAmount,
                        chargeAddress
                    )
                }
                case 0 {
                    // —— 分支B：输出币是 ERC20 ——
                    // trim 接收地址(偏移 0x40)
                    let trimAddress := mload(add(trimInfo_, 0x40))
                    // 转 trim 部分给 trimAddress 并 emit 事件
                    _sendToken(toToken_, trimAddress, actualTrimAmount)
                    _emitPositiveSlippageTrimRecord(
                        toToken_,
                        actualTrimAmount,
                        trimAddress
                    )

                    // charge 接收地址(偏移 0xc0)
                    let chargeAddress := mload(add(trimInfo_, 0xc0))
                    // 转 charge 部分给 chargeAddress 并 emit 事件
                    _sendToken(toToken_, chargeAddress, actualChargeAmount)
                    _emitPositiveSlippageChargeRecord(
                        toToken_,
                        actualChargeAmount,
                        chargeAddress
                    )
                }
            }

            // ===== 主流程 =====
            // 校验兑换后余额必须严格大于兑换前(即确有产出)，否则 revert
            // require(balanceAfter > balanceBefore, "invalid balance after");
            if or(
                gt(balanceBefore, balanceAfter),
                eq(balanceAfter, balanceBefore)
            ) {
                _revertWithReason(
                    0x00000015696e76616c69642062616c616e636520616674657200000000000000,
                    0x59
                ) // "invalid balance after"
            }
            // 本次兑换实际产出 = 兑换后余额 - 兑换前余额(balanceBefore 由 _doCommissionFromToken 记录)
            let inputAmount := sub(balanceAfter, balanceBefore)

            // —— 步骤1：处理输出端佣金（若启用），从产出中抽佣，扣减 inputAmount ——
            // commissionInfo.isToTokenCommission(偏移 0x20)
            let flag := mload(add(commissionInfo, 0x20))
            if gt(flag, 0) {
                // commissionInfo.isToTokenCommission == True
                let commissionAmount := _processCommission(
                    commissionInfo,
                    toToken,
                    inputAmount
                )
                // 佣金从产出中扣除
                inputAmount := sub(inputAmount, commissionAmount)
                // 计入被抽走的总额
                totalAmount := commissionAmount
            }

            // —— 步骤2：处理正滑点回收（启用且产出 > 预期才回收），回收额从 inputAmount 再扣减 ——
            // trimInfo.hasTrim(偏移 0x00)
            flag := mload(add(trimInfo, 0x00))
            // trimInfo.expectAmountOut(偏移 0x80)
            let expectAmountOut := mload(add(trimInfo, 0x80))
            if and(gt(flag, 0), gt(inputAmount, expectAmountOut)) {
                // trimInfo.hasTrim == True && inputAmount > trimInfo.expectAmountOut
                let trimAmount := _processTrim(trimInfo, toToken, inputAmount)
                // 回收额从产出中扣除
                inputAmount := sub(inputAmount, trimAmount)
                // 累加进被抽走的总额
                totalAmount := add(totalAmount, trimAmount)
            }

            // —— 步骤3：把扣除佣金与正滑点后的【净额】转给最终接收者 receiver ——
            // shr(96, shl(96, receiver)) 是清洗地址高位脏数据、只保留低 160 位
            switch eq(toToken, _ETH)
            case 1 {
                _sendETH(shr(96, shl(96, receiver)), inputAmount)
            }
            default {
                _sendToken(toToken, shr(96, shl(96, receiver)), inputAmount)
            }
        }
    }

    /**
     * @notice 校验佣金信息的合法性，不满足则 revert。
     * @dev 全 assembly 校验，规则：
     *        1. 若转账模式是 NO_TRANSFER / BY_INVEST / PERMIT2 之一，则不支持 fromToken 佣金 → "From commission not support"；
     *        2. fromToken 不能等于 toToken → "Invalid tokens"；
     *        3. fromToken 佣金与 toToken 佣金不能同时为真 → "Invalid commission direction"；
     *        4. 佣金 token 必须与方向匹配：fromToken 佣金则 token==fromToken；toToken 佣金则 token==toToken；
     *           或两者皆无佣金 → 否则 "Invalid commission info"。
     * @param commissionInfo 佣金信息
     * @param fromToken      输入代币
     * @param toToken        输出代币
     * @param mode           转账模式（含 _MODE_* 标志，见 CommonUtils）
     */
    function _validateCommissionInfo(
        CommissionInfo memory commissionInfo,
        address fromToken,
        address toToken,
        uint256 mode
    ) internal pure override {
        assembly ("memory-safe") {
            // 手工模拟 revert("xxx") / require(_,"xxx")：按内置 Error(string) 的 ABI 布局写入
            // 选择器(0x08c379a0) / 数据偏移(0x20) / 字符串(长度+内容打包在 m) 后 revert，省 gas。
            //
            // 注意这里按 32 字节对齐写(0/0x20/0x40)，但 selector 只占前 4 字节，会把后续字段整体右移 4 字节。
            // 从 0x00 连续读取的最终字节流为：
            //   [0x00..0x03] 08c379a0                      ← Error(string) 选择器(4字节)
            //   [0x04..0x23] 00..00 + 00 00 00 20          ← string 数据偏移量 offset = 32(0x20)
            //   [0x24..]     m 提供的 [长度 + 内容]          ← string 实际数据
            // 故第二个 mstore 的值要写成 0x00000020_00..00：把 0x20 放在该 word 的【高位第4字节】，
            // 正是为了抵消 selector 占用的前 4 字节，使其在字节流中落到 offset 字段处、被解码为 32。
            function _revertWithReason(m, len) {
                mstore(
                    0,
                    0x08c379a000000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    0x20,
                    0x0000002000000000000000000000000000000000000000000000000000000000
                )
                mstore(0x40, m)
                revert(0, len)
            }

            // if ((
            //     (mode & _MODE_NO_TRANSFER) != 0
            // || (mode & _MODE_BY_INVEST) != 0
            // || (mode & _MODE_PERMIT2) != 0
            // )
            // && commissionInfo.isFromTokenCommission) {
            //     revert("From commission not support");
            // }
            // —— 校验1：NO_TRANSFER / BY_INVEST / PERMIT2 这几种转账模式下不支持输入端(fromToken)佣金 ——
            // 因为这些模式资金来源特殊(免转账/已在合约/permit2)，无法按常规从 payer 拉取 fromToken 佣金
            // flag = 是否命中三种特殊模式之一
            let flag := or(
                or(
                    gt(and(mode, _MODE_NO_TRANSFER), 0),
                    gt(and(mode, _MODE_BY_INVEST), 0)
                ),
                gt(and(mode, _MODE_PERMIT2), 0)
            )
            // isFromTokenCommission(偏移 0x00)
            let isFromTokenCommission := mload(add(commissionInfo, 0x00)) // commissionInfo.isFromTokenCommission
            // 命中特殊模式 且 有 fromToken 佣金 → 报错
            if and(flag, isFromTokenCommission) {
                _revertWithReason(
                    0x0000001b46726f6d20636f6d6d697373696f6e206e6f7420737570706f727400,
                    0x5f
                ) // "From commission not support"
            }

            // if(fromToken == toToken) {
            //     revert("Invalid tokens");
            // }
            // —— 校验2：输入代币与输出代币不能相同 ——
            if eq(fromToken, toToken) {
                _revertWithReason(
                    0x0000000e496e76616c696420746f6b656e730000000000000000000000000000,
                    0x52
                ) // "Invalid tokens"
            }

            // if (commissionInfo.isFromTokenCommission && commissionInfo.isToTokenCommission) {
            //     revert("Invalid commission direction");
            // }
            // —— 校验3：输入端佣金与输出端佣金不能同时存在(只能二选一) ——
            // isToTokenCommission(偏移 0x20)
            let isToTokenCommission := mload(add(commissionInfo, 0x20)) // commissionInfo.isToTokenCommission
            // 两个方向同时为真 → 报错
            if and(isToTokenCommission, isFromTokenCommission) {
                _revertWithReason(
                    0x0000001c496e76616c696420636f6d6d697373696f6e20646972656374696f6e,
                    0x60
                ) // "Invalid commission direction"
            }

            // require(
            //     (commissionInfo.isFromTokenCommission && commissionInfo.token == fromToken)
            //         || (commissionInfo.isToTokenCommission && commissionInfo.token == toToken)
            //         || (!commissionInfo.isFromTokenCommission && !commissionInfo.isToTokenCommission),
            //     "Invalid commission info"
            // );
            // —— 校验4：佣金币种 token 必须与佣金方向匹配 ——
            // 合法情形(三者满足其一)：
            //   a) 有 fromToken 佣金 且 token == fromToken
            //   b) 有 toToken 佣金 且 token == toToken
            //   c) 两个方向都没有佣金
            // 佣金币种 token(偏移 0x40)
            let token := mload(add(commissionInfo, 0x40)) // commissionInfo.token
            // flag = 情形a
            flag := and(isFromTokenCommission, eq(token, fromToken))
            // flag |= 情形b
            flag := or(flag, and(isToTokenCommission, eq(token, toToken)))
            // flag |= 情形c
            flag := or(
                flag,
                and(iszero(isFromTokenCommission), iszero(isToTokenCommission))
            )
            // 三种合法情形都不满足 → 报错
            if iszero(flag) {
                _revertWithReason(
                    0x00000017496e76616c696420636f6d6d697373696f6e20696e666f0000000000,
                    0x5b
                ) // "Invalid commission info"
            }
        }
    }
}
