// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Interface for DAI-style permits
/**
 * @title IDaiLikePermit - DAI 风格的 permit（链下签名授权）接口
 * @notice permit 让用户用一个链下签名代替一笔 approve 交易（省 gas、改善体验）。
 *         本接口是 DAI 等早期 token 采用的【非标准】permit 变体，与标准 EIP-2612 不兼容。
 * @dev 与标准 EIP-2612 permit 的关键区别（详见 SafeERC20.safePermit）：
 *        - 参数个数：DAI 风格 8 个（本接口）vs EIP-2612 7 个 → calldata 为 256 vs 224 字节，
 *          SafeERC20 正是靠这个长度差来区分调用哪种 permit。
 *        - 授权额度：DAI 用布尔 allowed（只能「无限额度」或「取消」）vs EIP-2612 用 value（精确数额）。
 *        - nonce：两者合约【都记录】每个用户的 nonce（nonces 映射）并据此防重放；区别仅在于
 *          DAI 要求调用方把 nonce 作为参数【显式传入】（合约校验须等于链上值），
 *          而 EIP-2612 由合约内部自动读取，无需传入（故 DAI 比 EIP-2612 多 1 个参数）。
 *        - 字段命名：DAI 用 holder/expiry vs EIP-2612 用 owner/deadline（仅命名不同）。
 *      并存原因：DAI 上线早于 EIP-2612 标准化，沿用了其前标准的自定义接口。
 */
interface IDaiLikePermit {
    /**
     * @notice DAI 风格的链下签名授权：凭 holder 的签名，授权/取消 spender 对其代币的支配权。
     * @dev 【防重放原理】合约里有 nonces[holder] 记录用户当前 nonce；nonce 被纳入签名内容，
     *      permit 执行时校验「传入的 nonce == nonces[holder]」并随即将其 +1。
     *      因此每个 nonce（及对应签名）只能用一次：旧签名的 nonce 会小于递增后的链上值，
     *      重放时因 nonce 不匹配而 revert。所以「手动传入」不影响安全——传入值必须匹配链上记录。
     * @param holder  授权人（代币持有者、签名者；相当于 EIP-2612 的 owner）
     * @param spender 被授权人（获得支配额度的一方）
     * @param nonce   防重放计数器，须等于 holder 在合约中的当前 nonce（nonces[holder]）；校验通过后合约将其 +1
     * @param expiry  签名有效截止时间戳（相当于 EIP-2612 的 deadline）；0 通常表示永不过期
     * @param allowed 授权开关：true = 授予无限额度（type(uint256).max）；false = 取消授权（额度归 0）
     * @param v       ECDSA 签名分量 v
     * @param r       ECDSA 签名分量 r
     * @param s       ECDSA 签名分量 s
     */
    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
