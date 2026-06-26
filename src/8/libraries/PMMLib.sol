/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title PMMLib
 * @notice PMM（Private / Proactive Market Maker，私有/主动做市商）撮合模式所用的数据结构定义库。
 *         仅包含 struct / enum / event / error 的定义，不含任何函数逻辑，
 *         作为 DexRouter 与（链下/外部）做市商报价撮合系统之间的「数据契约」。
 *
 * @dev 【PMM 是什么】
 *      - 传统 AMM（如 Uniswap）按池子里的恒定乘积等曲线公式定价；
 *      - PMM 则是「链下做市商报价 + 链上成交」(RFQ, Request For Quote) 的模式：
 *          1. 用户/路由向做市商询价；
 *          2. 做市商用自有定价模型在链下给出报价，并对报价进行【签名】；
 *          3. 用户携带这份带签名的报价上链，合约验签后按该报价价格成交。
 *      - 价值：定价更灵活、对大额交易滑点更小、可桥接 CEX/做市商的外部流动性。
 *
 * @dev 【在本仓库中的现状（重要）】
 *      DexRouter 的若干入口（如 smartSwapByInvest 系列）以 `PMMSwapRequest[] extraData`
 *      形式声明了该参数，但在当前仓库的可见代码中，这些字段【未见被实际消费的实现】，
 *      多处 extraData 参数名被注释掉或仅保留类型。也就是说：本库目前是「数据结构占位/预留」，
 *      真正的撮合、验签、额度与订单状态管理逻辑不在本仓库内。
 *      因此，下文对某些字段语义的描述属于【基于命名与上下文的推断】，会显式标注，请勿当作权威定义。
 */
library PMMLib {

  // ============ Struct ============

  /**
   * @notice 单笔 PMM 询价/成交请求：描述「按某做市商报价成交一段兑换」所需的信息。
   * @dev 通常由做市商在链下填充并签名后，作为 DexRouter 的 extraData 传入。
   *      字段含义中标注「(推断)」者表示本仓库无实现可佐证，仅依据命名/上下文推测。
   *      （注：以下字段为 struct 成员，Solidity NatSpec 不解析成员注释，故用普通注释说明。）
   */
  struct PMMSwapRequest {
      // 路由路径索引：在多路径/多跳路由中标识本请求属于第几条 path（与 PMMSwap 事件的 pathIndex 对应）
      uint256 pathIndex;
      // 付款方地址：实际支付 fromToken 的一方（可能是用户本人，也可能是 Router 等中间合约）
      address payer;
      // 卖出代币地址（用户支付的 token）
      address fromToken;
      // 买入代币地址（用户收到的 token）
      address toToken;
      // 本次成交允许卖出的 fromToken 上限，用于给报价的成交量封顶、防止超量成交
      uint256 fromTokenAmountMax;
      // 本次成交允许买入的 toToken 上限，与 fromTokenAmountMax 共同界定报价的成交边界
      uint256 toTokenAmountMax;
      // 盐值：用于让每份报价/订单唯一化，(推断) 配合 deadLine 起到防重放、避免订单哈希碰撞的作用
      uint256 salt;
      // 报价有效截止时间（unix 时间戳）；超过后报价作废，(推断) 对应错误码 QUOTE_EXPIRED
      uint256 deadLine;
      // 是否为「推送单(push order)」。
      //   (推断) push/pull 表示订单的发起方向：
      //     - true  ：做市商【主动推送】、预先签好挂出的订单（类似挂单，可能支持部分/多次成交）；
      //     - false ：用户/路由【主动询价】触发的 RFQ 撮合（拉取式）。
      //   该推断与 PMM_ERROR 中的 ORDER_CANCELLED_OR_FINALIZED / REMAINING_AMOUNT_NOT_ENOUGH
      //   （暗示存在可取消、可部分成交的挂单）相吻合，但本仓库无读取此字段的实现可证实。
      bool isPushOrder;
      // 扩展字段：用 bytes 打包承载额外的/可变长的数据，以保持结构体 ABI 稳定、便于向后兼容
      bytes extension;
      // ───────────────────────────────────────────────────────────────────────────
      // 以下 4 行是【本文件原始版本中即已被注释掉的字段】，此处原样保留、未作任何改动。
      // 它们的确切用途在本仓库中无说明、无实现；可能是计划编码进上面的 extension、或历史遗留，无法确定。
      // ───────────────────────────────────────────────────────────────────────────
      // address marketMaker;
      // uint256 subIndex;
      // bytes signature;
      // uint256 source;  1byte type + 1byte bool（reverse） + 0...0 + 20 bytes address
  }

  /**
   * @notice PMM 交易的基础参数：描述「用户视角」的整笔兑换意图（与具体做市商无关的总体约束）。
   * @dev 与 PMMSwapRequest 配合使用：本结构管整笔总目标，PMMSwapRequest 管每段具体成交。
   */
  struct PMMBaseRequest {
    // 用户计划卖出的 fromToken 总量
    uint256 fromTokenAmount;
    // 用户能接受的最小买入量（滑点保护下限）；(推断) 实际成交低于此值则整笔回滚
    uint256 minReturnAmount;
    // 整笔交易的截止时间（unix 时间戳），过期则交易无效
    uint256 deadLine;
    // 卖出侧是否为原生币(ETH/BNB 等)：(推断) true 表示用户用原生币支付，需先 wrap 成 WETH 处理
    bool fromNative;
    // 买入侧是否为原生币：(推断) true 表示最终需把 WETH unwrap 成原生币发给用户
    bool toNative;
  }

  // ============ Error Codes ============

  /**
   * @notice PMM 撮合过程中的错误码枚举，用于精确表达某笔 PMM 成交失败的原因。
   * @dev 枚举值从 0 递增；NO_ERROR=0 表示成功，便于以「值 != 0 即失败」判断。
   *      (推断) 既可作为 PMMSwap 事件 errorCode 字段的取值，也可经 PMMErrorCode 错误以数值形式抛出。
   */
  enum PMM_ERROR {
      NO_ERROR,                     // 0：无错误，成交成功
      INVALID_OPERATOR,             // 1：(推断) 操作者非法（调用方/签名者无权限）
      QUOTE_EXPIRED,                // 2：(推断) 报价已过期（超过 PMMSwapRequest.deadLine）
      ORDER_CANCELLED_OR_FINALIZED, // 3：(推断) 订单已被取消或已完成，不可再成交（暗示存在可取消的挂单）
      REMAINING_AMOUNT_NOT_ENOUGH,  // 4：(推断) 订单剩余可成交额度不足（暗示订单可部分/多次成交）
      INVALID_AMOUNT_REQUEST,       // 5：(推断) 请求金额非法（如超出 Max 上限或为 0）
      FROM_TOKEN_PAYER_ERROR,       // 6：(推断) fromToken 付款方校验失败（payer 异常）
      TO_TOKEN_PAYER_ERROR,         // 7：(推断) toToken 收款方校验失败
      WRONG_FROM_TOKEN              // 8：(推断) fromToken 与报价不匹配
  }

  // ============ Events ============

  /**
   * @notice PMM 成交事件：(推断) 用于链下监控与对账，记录每笔 PMM 撮合的结果。
   * @param pathIndex 对应的路由路径索引（与 PMMSwapRequest.pathIndex 对应）。
   * @param subIndex  (推断) 同一 path 下的子成交序号，用于区分一条路径中的多笔 PMM 成交。
   * @param errorCode 结果码：0(NO_ERROR) 表示成功，非 0 对应 PMM_ERROR 中的失败原因。
   */
  event PMMSwap(
    uint256 pathIndex,
    uint256 subIndex,
    uint256 errorCode
  );

  // ============ Custom Errors ============

  /**
   * @notice PMM 自定义错误，以数值形式携带 PMM_ERROR 枚举对应的错误码。
   * @dev (推断) 用于需要 revert 整笔交易的场景；而可容忍的失败则可能通过 PMMSwap 事件的 errorCode 上报。
   * @param errorCode 由 PMM_ERROR 枚举转换而来的错误码数值。
   */
  error PMMErrorCode(uint256 errorCode);

}
