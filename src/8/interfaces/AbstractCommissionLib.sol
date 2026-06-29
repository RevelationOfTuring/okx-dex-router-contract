// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Abstract base contract with virtual functions
/**
 * @title AbstractCommissionLib - 佣金/正滑点回收的抽象基类
 * @notice 定义 CommissionLib 所需的数据结构（CommissionInfo / TrimInfo）与一组 virtual 函数签名，
 *         由 CommissionLib 给出具体实现（全 assembly）。
 * @dev 结构体字段右侧的 // 0xXX 是该字段在 memory 结构体中的【偏移量】——
 *      CommissionLib 的 assembly 正是按这些固定偏移 mstore/mload 读写字段，二者必须严格对应。
 *      （memory 结构体在内存里按字段顺序、每个字段占 32 字节连续排布，故偏移依次 +0x20。）
 */
abstract contract AbstractCommissionLib {
    /**
     * @notice 佣金信息：描述本次兑换的抽佣方向、币种、各推荐人的费率与地址。
     * @dev 支持最多 8 个推荐人（commissionRate/referrerAddress 1~8）；实际生效个数由 commissionLength 决定。
     *      右侧 0xXX 为字段在 memory 结构体中的偏移（assembly 按此读写，勿改顺序）。
     */
    struct CommissionInfo {
        bool isFromTokenCommission; //0x00  是否从输入端(fromToken)抽佣
        bool isToTokenCommission; //0x20    是否从输出端(toToken)抽佣
        address token; // 0x40              抽佣所用的代币地址（fromToken 或 toToken）
        uint256 toBCommission; // 0x60      toB 模式标记：0=无佣金, 1=非 toB 佣金, 2=toB 佣金
        uint256 commissionLength; // 0x80   实际生效的推荐人个数（1~8）
        uint256 commissionRate; // 0xa0     第 1 个推荐人的费率（以 DENOMINATOR=1e9 为基准）
        address referrerAddress; // 0xc0    第 1 个推荐人地址
        uint256 commissionRate2; // 0xe0    第 2 个推荐人费率
        address referrerAddress2; // 0x100  第 2 个推荐人地址
        uint256 commissionRate3; // 0x120   第 3 个推荐人费率
        address referrerAddress3; // 0x140  第 3 个推荐人地址
        uint256 commissionRate4; // 0x160   第 4 个推荐人费率
        address referrerAddress4; // 0x180  第 4 个推荐人地址
        uint256 commissionRate5; // 0x1a0   第 5 个推荐人费率
        address referrerAddress5; // 0x1c0  第 5 个推荐人地址
        uint256 commissionRate6; // 0x1e0   第 6 个推荐人费率
        address referrerAddress6; // 0x200  第 6 个推荐人地址
        uint256 commissionRate7; // 0x220   第 7 个推荐人费率
        address referrerAddress7; // 0x240  第 7 个推荐人地址
        uint256 commissionRate8; // 0x260   第 8 个推荐人费率
        address referrerAddress8; // 0x280  第 8 个推荐人地址
    }

    /**
     * @notice 正滑点回收(Trim)信息：当实际兑换所得超过用户预期(expectAmountOut)时，
     *         按 trimRate 上限回收超出部分，并按 chargeRate 在 trim/charge 两地址间分配。
     * @dev 右侧 0xXX 为字段在 memory 结构体中的偏移（assembly 按此读写）。
     */
    struct TrimInfo {
        bool hasTrim; // 0x00               是否启用正滑点回收
        uint256 trimRate; // 0x20           回收比例上限（以 TRIM_DENOMINATOR=1000 为基准，上限 TRIM_RATE_LIMIT=100 即 10%）
        address trimAddress; // 0x40        回收资金（trim 部分）的接收地址
        uint256 toBTrim; // 0x60            toB 模式标记：0=无 trim, 1=非 toB trim, 2=toB trim
        uint256 expectAmountOut; // 0x80    用户预期的输出额（超过此值的部分才算正滑点）
        uint256 chargeRate; // 0xa0         charge 占回收额的比例（以 TRIM_DENOMINATOR=1000 为基准）
        address chargeAddress; // 0xc0      charge 部分的接收地址
    }

    /**
     * @notice 从 calldata 末尾解析出 CommissionInfo 与 TrimInfo（具体实现见 CommissionLib）。
     */
    function _getCommissionAndTrimInfo()
        internal
        virtual
        returns (CommissionInfo memory commissionInfo, TrimInfo memory trimInfo);

    // function _getBalanceOf(address token, address user)
    //     internal
    //     virtual
    //     returns (uint256);

    /**
     * @notice 处理输入端(fromToken)佣金，并确定兑换产物的中间接收地址。
     * @return 中间接收地址 middleReceiver；若收到本合约则返回兑换前余额 balanceBefore。
     */
    function _doCommissionFromToken(
        CommissionInfo memory commissionInfo,
        address payer,
        address receiver,
        uint256 inputAmount,
        bool hasTrim,
        address toToken
    ) internal virtual returns (address, uint256);

    /**
     * @notice 处理输出端(toToken)佣金 + 正滑点回收，并把净额转给最终接收者。
     * @return 被抽走的总额（佣金 + trim）。
     */
    function _doCommissionAndTrimToToken(
        CommissionInfo memory commissionInfo,
        address receiver,
        uint256 balanceBefore,
        address toToken,
        TrimInfo memory trimInfo
    ) internal virtual returns (uint256);

    /**
     * @notice 校验佣金信息的合法性（方向、币种、模式匹配等），不满足则 revert。
     */
    function _validateCommissionInfo(
        CommissionInfo memory commissionInfo,
        address fromToken,
        address toToken,
        uint256 mode
    ) internal pure virtual;
}
