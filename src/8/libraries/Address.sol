/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Address - 地址类型工具库
 * @dev OpenZeppelin 经典工具库，封装了与 address 类型相关的底层操作：
 *      1. isContract —— 判断一个地址是否为合约
 *      2. toPayable  —— 把普通 address 转成 address payable
 *      3. sendValue  —— 替代 Solidity 原生 transfer 的安全转账（转发全部 gas）
 *
 *      使用方式：library 中的 internal 函数会在编译期被内联进调用方合约，
 *      不产生独立的部署字节码，也没有 delegatecall 开销。
 *
 * @notice Collection of functions related to the address type
 */
library Address {
    /**
     * @notice 判断 `account` 是否为合约地址
     * @dev 原理：通过 EVM 的 EXTCODEHASH 操作码读取目标地址的代码哈希，
     *      根据哈希值判断该地址上是否「存在已部署的合约代码」。
     *
     *      EIP-1052 对 extcodehash 的返回约定：
     *        - 账户尚未创建（不存在）        → 返回 0x0
     *        - 账户存在但无代码（如 EOA）   → 返回 keccak256("") = 0xc5d2...a470（空字符串哈希）
     *        - 账户存在且有代码（合约）     → 返回该合约代码的 keccak256 哈希
     *      因此「是合约」的判定 = 哈希既不等于空哈希、也不等于 0。
     *
     * @dev [重要安全提示]
     *      不能反过来假设：本函数返回 false 就一定是 EOA（外部账户）而非合约。
     *      以下几种情况本函数同样会返回 false，但它们可能与合约相关：
     *        - 一个外部账户（EOA）
     *        - 正处于「构造函数执行中」的合约（此时其代码尚未写入链上，extcodehash 仍为空）
     *        - 一个未来将通过 CREATE2 在此地址部署合约的地址
     *        - 一个曾经有合约、但已被 selfdestruct 销毁的地址
     *      => 不要用 isContract 来做安全防护（如「禁止合约调用」），它可被绕过。
     *
     * @param account 待检查的地址
     * @return 若该地址上存在合约代码返回 true，否则返回 false
     */
    function isContract(address account) internal view returns (bool) {
        // 根据 EIP-1052：
        //   0x0     是「尚未创建的账户」的返回值。注：从没收到过钱 or 执行过selfdestruct且本身没有余额的合约地址（即不存在于状态树中的账户地址）
        //   0xc5d2..a470 是「无代码账户」的返回值，即 keccak256('') 空字符串哈希
        bytes32 codehash;
        // accountHash = keccak256("")，即「有账户但无代码」时 extcodehash 的返回值
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // 直接调用 EXTCODEHASH 取目标地址的代码哈希（比 extcodesize 略省 gas）
            codehash := extcodehash(account)
        }
        // 既不是空代码哈希、也不是 0（未创建）→ 说明该地址确实部署了合约代码
        return (codehash != accountHash && codehash != 0x0);
    }

    /**
     * @notice 把 `address` 转换为 `address payable`
     * @dev 这只是一次类型转换（cast），底层的地址数值不会发生任何改变，
     *      只是让该地址在语义上「可接收 ETH」，从而能调用 .transfer / .send / .call{value:}。
     *
     * @param account 普通地址
     * @return 等值的 payable 地址
     *
     * _Available since v2.4.0._
     */
    function toPayable(
        address account
    ) internal pure returns (address payable) {
        return payable(account);
    }

    /**
     * @notice 向 `recipient` 转账 `amount` wei 的 ETH，转发全部可用 gas，失败则 revert
     * @dev 用于替代 Solidity 原生的 `recipient.transfer(amount)`：
     *
     *      为什么不用原生 transfer？
     *        原生 transfer/send 会硬编码只转发 2300 gas 给接收方。
     *        EIP-1884 提高了部分操作码（如 SLOAD）的 gas 成本，导致一些原本能正常工作的
     *        接收合约（receive/fallback 里有简单逻辑）超过 2300 gas 限制而收款失败。
     *        sendValue 通过底层 call 转发「全部剩余 gas」，规避了这个 2300 gas 限制。
     *        参考：https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/
     *
     * @dev [重要安全提示] 重入风险
     *      由于使用 call 会把控制权交给 `recipient`（触发其 receive/fallback，可执行任意逻辑），
     *      调用方必须防范重入攻击：
     *        - 使用 ReentrancyGuard 互斥锁，或
     *        - 遵循 Checks-Effects-Interactions（先改状态、最后才转账）模式。
     *
     * @param recipient 收款地址
     * @param amount    转账金额（单位 wei）
     *
     * _Available since v2.4.0._
     */
    function sendValue(address recipient, uint256 amount) internal {
        // Check：先校验本合约余额是否充足，不足则直接 revert，避免无谓的 call
        require(
            address(this).balance >= amount,
            "Address: insufficient balance"
        );

        // Interaction：通过底层 call 转账，附带 value 且转发全部剩余 gas；空 calldata("") 表示纯转账
        // solhint-disable-next-line avoid-call-value
        (bool success, ) = recipient.call{value: amount}("");
        // call 不会因对方 revert 而自动回滚，必须手动检查返回的 success 标志
        require(
            success,
            "Address: unable to send value, recipient may have reverted"
        );
    }
}
