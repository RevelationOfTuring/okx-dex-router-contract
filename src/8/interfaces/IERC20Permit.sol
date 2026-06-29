// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on `{IERC20-approve}`, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 */
/**
 * @title IERC20Permit - 标准 EIP-2612 permit（链下签名授权）接口
 * @notice 让用户用一个链下签名代替 approve 交易来设置 ERC20 授权额度，无需自己发交易、无需持有 ETH 付 gas。
 * @dev 这是 EIP-2612 官方标准接口（OpenZeppelin 版）。与 DAI 风格(IDaiLikePermit)的对照：
 *        - 参数 7 个（calldata 224 字节）vs DAI 8 个（256 字节）——SafeERC20 据长度区分两者；
 *        - 用 value 设置【精确额度】vs DAI 的布尔 allowed（无限/取消）；
 *        - nonce 由合约【自动管理】、调用方无需作为参数传入（仅签名时需引用，见 nonces()）；
 *        - 字段命名 owner/deadline vs DAI 的 holder/expiry。
 *      签名采用 EIP-712 结构化数据格式（配合 DOMAIN_SEPARATOR 防跨合约/跨链重放）。
 */
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over `owner`'s tokens,
     * given `owner`'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    /**
     * @notice 凭 owner 的签名，将 spender 对 owner 代币的授权额度设为 value（成功后触发 Approval 事件）。
     * @dev 要求：
     *        - spender 不能为零地址；
     *        - deadline 必须是未来的时间戳（否则签名过期）；
     *        - v/r/s 必须是 owner 对 EIP-712 格式化参数的有效 secp256k1 签名；
     *        - 签名必须使用 owner 的【当前 nonce】（见 nonces()）——每次成功 permit 后 nonce 自动 +1，
     *          从而保证每个签名只能用一次（防重放）。
     *      注意：与 approve 一样存在「交易排序(front-running)」相关的已知问题（如先用旧额度再被改额度）。
     * @param owner    授权人（代币持有者、签名者）
     * @param spender  被授权人
     * @param value    要授予的精确授权额度
     * @param deadline 签名有效截止时间戳，过期则 revert
     * @param v        ECDSA 签名分量 v
     * @param r        ECDSA 签名分量 r
     * @param s        ECDSA 签名分量 s
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    /**
     * @notice 返回 owner 当前的 nonce（防重放计数器）。生成 permit 签名时必须把此值纳入签名内容。
     * @dev 每次成功调用 permit 都会让该 owner 的 nonce +1，使旧签名因 nonce 不再匹配而失效，从而防重放。
     *      与 DAI 风格的差异：EIP-2612 的 nonce 不作为 permit 的参数传入（合约内部读取），
     *      但调用方仍需先读它来构造签名——本方法即用于查询当前应使用的 nonce。
     * @param owner 要查询 nonce 的账户
     * @return 该账户当前的 nonce 值
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for `permit`, as defined by {EIP712}.
     */
    /**
     * @notice 返回 EIP-712 的域分隔符(domain separator)，用于 permit 签名的编码。
     * @dev domain separator 通常由 name、version、chainId、合约地址 等哈希而成，作用是把签名【绑定到
     *      特定合约 + 特定链】，防止同一签名被在「其它合约」或「其它链」上重放（跨域重放保护）。
     *      它与 nonce 互补：nonce 防同一合约内的重复使用，domain separator 防跨合约/跨链使用。
     * @return EIP-712 域分隔符
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
