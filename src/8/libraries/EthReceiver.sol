/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Base contract with common payable logics
 * @notice 提供「接收 ETH」通用逻辑的基础合约
 * @dev abstract 合约，被需要接收 ETH 的合约（如 DexRouter、Adapter）继承。
 *      核心目的：只允许「合约」给本合约转 ETH，拒绝「外部账户(EOA)」的直接转账，
 *      防止用户误操作把 ETH 直接打进路由合约而无法找回。
 */
abstract contract EthReceiver {
  /**
   * @notice 接收纯 ETH 转账的回退函数（calldata 为空时触发）
   * @dev receive() 在「有人向本合约转 ETH 且未附带 calldata」时被自动调用。
   *
   *      安全校验：require(msg.sender != tx.origin)
   *        - tx.origin  = 发起整笔交易的最初账户，永远是一个 EOA（外部账户）
   *        - msg.sender = 直接调用本合约的地址（可能是 EOA，也可能是合约）
   *
   *      两者关系：
   *        · 若 msg.sender == tx.origin → 调用链只有一层，说明是【EOA 直接】转账   → 拒绝
   *        · 若 msg.sender != tx.origin → 中间隔了至少一层合约，说明是【合约】转来的 → 放行
   *
   *      为什么要拒绝 EOA 直接转账？
   *        本合约是 DEX 路由这类「中转型」合约，ETH 应当在 swap 流程中由内部逻辑
   *        （如 WETH.withdraw 经 Relayer、或多跳路由的合约间转账）打进来，而不是
   *        被用户用钱包直接转入。直接转入的 ETH 没有对应的业务逻辑处理，会「卡死」
   *        在合约里取不出来。用此校验在入口处拦截，避免用户资金损失。
   *
   *      ⚠️ 注意：此校验【不是】严格的安全防护，不能用来防黑客：
   *        攻击者可在自己合约的 constructor 里发起转账，此时 msg.sender(构造中的合约)
   *        与 tx.origin 不同，校验会通过。它的定位是「防误操作」，而非「防攻击」。
   */
  receive() external payable {
    // solhint-disable-next-line avoid-tx-origin
    // msg.sender == tx.origin 即 EOA 直接转账，直接 revert 拒绝
    require(msg.sender != tx.origin, "ETH deposit rejected");
  }
}
