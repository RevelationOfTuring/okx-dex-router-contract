/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "../interfaces/IDexRouter.sol";

/**
 * @title CommonUtils - 公共常量基础合约
 * @notice 定义了 DexRouter 系统中所有共用的常量：位掩码、占位符地址、网络部署地址等
 * @dev 这是一个 abstract 合约，不包含任何函数实现，纯粹作为常量集合被继承链使用
 *      继承路径：CommonUtils → CommonLib → UnxswapRouter / UnxswapV3Router → DexRouter
 */
abstract contract CommonUtils is IDexRouter {
    //=============================================================
    //                     ETH 占位符地址
    //=============================================================

    /**
     * @notice 原生 ETH 的占位符地址（行业标准）
     * @dev 因为 ETH 没有合约地址，需要用一个"伪地址"来统一 ETH/ERC20 的接口
     *      这个值是行业惯例（1inch / 0x / Paraswap 等聚合器都用相同地址）
     *      选择 0xEE 全填充是因为视觉上一眼能认出、且不可能与真实合约地址碰撞
     */
    address internal constant _ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    //=============================================================
    //                     位掩码常量 (Bitmasks)
    //=============================================================
    /*
     * 本合约大量使用 uint256 作为"打包数据"的容器，通过位运算把多个字段塞进同一个 256 位的槽里，
     * 以减少 calldata 长度和存储开销。下面的掩码用于提取各字段。
     *
     * 位图全景（不同上下文有不同的位约定，下方标注每个字段的 [起始位:结束位]=占用位数）:
     *
     *   高位 ──────────────────────────────────────────────────────────────► 低位
     *
     *    字段     占用 bit 区间      位宽     掩码常量
     *    ───────────────────────────────────────────────────────────────────
     *    rev/o4z  255                1 位    _REVERSE_MASK / _ONE_FOR_ZERO_MASK
     *    WETH     254                1 位    _WETH_MASK
     *    unwrap   253                1 位    _WETH_UNWRAP_MASK
     *    (保留)   252                1 位    —
     *    mode     251:249            3 位    _TRANSFER_MODE_MASK
     *    (保留)   248:192           57 位    —
     *    inIdx    191:184            8 位    _INPUT_INDEX_MASK
     *    outIdx   183:176            8 位    _OUTPUT_INDEX_MASK
     *    weight   175:160           16 位    _WEIGHT_MASK
     *    address  159:0            160 位    _ADDRESS_MASK
     *    ───────────────────────────────────────────────────────────────────
     *    合计 1+1+1+1+3+57+8+8+16+160 = 256 位
     *
     *  字段明细:
     *    rev/o4z   bit 255         (1 位)    方向标志 _REVERSE_MASK / _ONE_FOR_ZERO_MASK（同一 bit，不同语义）
     *    WETH      bit 254         (1 位)    _WETH_MASK，标记 pool 涉及 WETH
     *    unwrap    bit 253         (1 位)    _WETH_UNWRAP_MASK，swap 后是否把 WETH 解包成 ETH
     *    （保留）  bit 252         (1 位)    未使用
     *    mode      bit 251:249     (3 位)    转账模式 _TRANSFER_MODE_MASK（noTransfer / byInvest / permit2）
     *    （保留）  bit 248:192     (57 位)   未使用
     *    inIdx     bit 191:184     (8 位)    _INPUT_INDEX_MASK，DAG 路由输入节点索引
     *    outIdx    bit 183:176     (8 位)    _OUTPUT_INDEX_MASK，DAG 路由输出节点索引
     *    weight    bit 175:160     (16 位)   _WEIGHT_MASK，fork 分流权重（万分比 0~10000）
     *    address   bit 159:0       (160 位)  _ADDRESS_MASK，打包的合约/池子地址
     *
     *  注：bit 255:160（高 96 位）整体又可被复用为 _ORDER_ID_MASK 携带 orderId（见下方常量），
     *      与上面按字段拆分的用法是「不同上下文、不同约定」，不会同时生效。
     */

    /**
     * @notice 地址掩码：提取 uint256 的低 160 位，即 address 部分
     * @dev 用法：address poolAddr = address(uint160(rawData & _ADDRESS_MASK))
     *      等价于 _bytes32ToAddress(rawData)
     */
    uint256 internal constant _ADDRESS_MASK =
        0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;

    /**
     * @notice 方向标志掩码：bit 255（最高位）
     * @dev 在 _exeForks 的 rawData 中：
     *        0 = adapter 调用 sellBase（正向交易）
     *        1 = adapter 调用 sellQuote（反向交易）
     *      在 swapWrap 的 rawdata 中：
     *        0 = ETH → WETH（包装）
     *        1 = WETH → ETH（解包）
     */
    uint256 internal constant _REVERSE_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    /**
     * @notice 订单号掩码：bit 255~160（高 96 位，12 字节）
     * @dev 在 unxswapTo / uniswapV3SwapTo 中，srcToken/receiver 参数的高 96 位
     *      被复用来携带 orderId，这样不增加 calldata 长度就能传递订单号
     *      提取方式：orderId = (srcToken & _ORDER_ID_MASK) >> 160
     *      96 bit ≈ 8×10²⁸ 个订单号，远远足够
     */
    uint256 internal constant _ORDER_ID_MASK =
        0xffffffffffffffffffffffff0000000000000000000000000000000000000000;

    /**
     * @notice 权重掩码：bit 175~160（16 位）
     * @dev 表示一个 fork 在当前 hop 内的分流比例，单位是"万分比"
     *      范围 0~10000，10000 表示这个 fork 接收该 hop 的 100% 资金
     *      提取方式：weight = (rawData & _WEIGHT_MASK) >> 160
     *      16 位最大值 65535 > 10000，留有余地
     */
    uint256 internal constant _WEIGHT_MASK =
        0x00000000000000000000ffff0000000000000000000000000000000000000000;

    /**
     * @notice gas 上限常量：5000 gas
     * @dev 用于子合约中做 staticcall 时限制 gas（如查询 balanceOf）
     *      5000 gas 足够一次 SLOAD + 返回，但不够执行复杂逻辑
     *      目的：防止恶意 token 合约在 view 函数里执行任意操作（重入/消耗 gas 等）
     */
    uint256 internal constant _CALL_GAS_LIMIT = 5000;

    /**
     * @notice calldata 后缀魔数前缀
     * @dev 在 _exeAdapter 调用 adapter 时，会在标准 ABI 编码后面追加 32 字节：
     *        [ORIGIN_PAYER 高 12 字节 | refundTo 地址 20 字节]
     *      魔数 0x3ca20afc2ccc 的作用是"协议握手"：
     *        adapter 从 calldata 末尾读 32 字节后，先验证高位的魔数前缀是否匹配，
     *        匹配了才信任低 20 字节是 refundTo 地址
     *      这样普通外部调用（没有追加数据）不会被误识别
     */
    uint256 internal constant ORIGIN_PAYER =
        0x3ca20afc2ccc0000000000000000000000000000000000000000000000000000;

    /**
     * @notice swap 金额掩码：低 128 位
     * @dev 在 swapWrap(uint256 rawdata) 中使用：
     *        amount = rawdata & SWAP_AMOUNT     (低 128 位 = 金额)
     *        reversed = rawdata & _REVERSE_MASK (bit 255 = 方向)
     *      128 位最大值 ≈ 3.4×10³⁸ wei，比全宇宙的 ETH 还多，足够
     */
    uint256 internal constant SWAP_AMOUNT =
        0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff;

    /**
     * @notice WETH 标志掩码：bit 254
     * @dev 被 UnxswapRouter / V3 子合约用于标记"这个 pool 涉及 WETH"
     *      bit 255 已被 _REVERSE_MASK 占用，所以 WETH 标志放在 bit 254
     */
    uint256 internal constant _WETH_MASK =
        0x4000000000000000000000000000000000000000000000000000000000000000;

    /**
     * @notice Uniswap V3 交易方向掩码：bit 255
     * @dev 数值上与 _REVERSE_MASK 完全相同，但语义不同：
     *        0 = zeroForOne（token0 → token1）
     *        1 = oneForZero（token1 → token0）
     *      V3 池子按 token0 < token1 排序，方向用此 bit 区分
     *      之所以和 _REVERSE_MASK 定义两次，是为了代码可读性——
     *      在不同上下文中用不同名字，但编译器会内联为同一个字面量
     */
    uint256 internal constant _ONE_FOR_ZERO_MASK = 1 << 255;

    /**
     * @notice WETH 解包标志掩码：bit 253
     * @dev 在 V3 swap 的 pools[] 编码中：
     *      最后一个 pool 的这个位 = 1 → swap 完成后需要把 WETH 解包成 ETH 给用户
     *      场景：用户指定 toToken = 0xEeee...(ETH)，但 V3 池子实际输出 WETH，
     *            需要这个标志通知路由做最终解包
     */
    uint256 internal constant _WETH_UNWRAP_MASK = 1 << 253;

    //=============================================================
    //                  转账模式常量 (Transfer Modes)
    //=============================================================
    /*
     * 编码在 fromToken 字段的高位 (bit 251~249)，
     * 告诉 _transferInternal 函数"钱从哪里来、怎么转"
     */

    /**
     * @notice 默认模式：从用户钱包通过 ApproveProxy 拉款
     * @dev 值为 0，即 fromToken 高位无特殊标志时就是此模式
     *      如果 payer == address(this)，则用 safeTransfer 从合约余额转出
     *      如果 payer == 用户地址，则调 ApproveProxy.claimTokens() 拉款
     */
    uint256 internal constant _MODE_LEGACY = 0;

    /**
     * @notice 免转账模式：跳过 token 转账步骤
     * @dev bit 251 = 1
     *      使用场景：多跳路由中，上一跳的输出已经直接落到了下一跳的目标池子
     *      （通过设置 to = 下一跳的 assetTo），此时不需要再做一次转账
     *      这是 hop-to-hop 的 gas 优化
     */
    uint256 internal constant _MODE_NO_TRANSFER = 1 << 251;

    /**
     * @notice 投资模式：钱已经在 Router 合约中，直接 safeTransfer
     * @dev bit 250 = 1
     *      使用场景：smartSwapByInvest —— 外部合约（如投资合约）先把资金打到 Router，
     *      然后调 Router 执行 swap。此时 payer 就是 Router 自己
     */
    uint256 internal constant _MODE_BY_INVEST = 1 << 250;

    /**
     * @notice Permit2 模式（预留，当前未实现）
     * @dev bit 249 = 1
     *      为未来支持 Uniswap Permit2 协议预留的模式
     *      当前实现中遇到此模式直接 return，不做任何操作
     */
    uint256 internal constant _MODE_PERMIT2 = 1 << 249;

    /**
     * @notice 转账模式掩码：覆盖 bit 251~249 这三位
     * @dev 0x0E = 二进制 0000_1110，左移后正好覆盖 bit 251, 250, 249
     *      用法：mode = fromToken & _TRANSFER_MODE_MASK
     *      提取后直接与 _MODE_xxx 常量比对（不需要右移）
     */
    uint256 internal constant _TRANSFER_MODE_MASK =
        0x0E00000000000000000000000000000000000000000000000000000000000000;

    /**
     * @notice DAG 路由输入节点索引掩码：bit 191~184（8 位）
     * @dev 在 DagRouter 中使用，指定当前节点的输入来自 DAG 中哪个节点的输出
     *      8 位 = 最多 256 个节点，对单笔交易的路由拓扑而言远远足够
     */
    uint256 internal constant _INPUT_INDEX_MASK =
        0x0000000000000000ff0000000000000000000000000000000000000000000000;

    /**
     * @notice DAG 路由输出节点索引掩码：bit 183~176（8 位）
     * @dev 在 DagRouter 中使用，指定当前节点的输出将被 DAG 中哪个节点消费
     *      与 _INPUT_INDEX_MASK 配合，构成 DAG 路由的拓扑连接关系
     */
    uint256 internal constant _OUTPUT_INDEX_MASK =
        0x000000000000000000ff00000000000000000000000000000000000000000000;

    //=============================================================
    //              网络部署地址 (Network-Specific Addresses)
    //=============================================================
    /*
     * 以下三个地址是部署时硬编码的，每条链不同。
     * 使用 constant 而非 immutable 的原因：
     *   immutable 变量在 assembly 中无法直接引用（它是运行时从 bytecode 固定偏移加载的），
     *   而本项目的子合约（UnxswapRouter 等）大量在 inline assembly 中使用这些地址，
     *   只有 constant 能被编译器直接内联为字面量。
     *   代价：每部署一条新链都需要修改源码并重新编译。
     */

    /**
     * @notice WETH（Wrapped Native Token）合约地址
     * @dev 当前配置为 BSC 的 WBNB 地址
     *      ETH 主网对应：0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
     *      功能：ETH↔WETH 互换。Router 收到 ETH 后统一 deposit 成 WETH 处理，
     *      最后再按需 withdraw 回 ETH，统一了内部逻辑
     */
    // ETH:     C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    // BSC:     bb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
    // OEC:     8f8526dbfd6e38e3d8307702ca8469bae6c56c15
    // LOCAL:   5FbDB2315678afecb367f032d93F642f64180aa3
    // LOCAL2:  02121128f1Ed0AdA5Df3a87f42752fcE4Ad63e59
    // POLYGON: 0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270
    // AVAX:    B31f66AA3C1e785363F0875A1B74E27b85FD66c7
    // FTM:     21be370D5312f44cB42ce377BC9b8a0cEF1A4C83
    // ARB:     82aF49447D8a07e3bd95BD0d56f35241523fBab1
    // OP:      4200000000000000000000000000000000000006
    // CRO:     5C7F8A570d578ED84E63fdFA7b1eE72dEae1AE23
    // CFX:     14b2D3bC65e74DAE1030EAFd8ac30c533c976A9b
    // POLYZK   4F9A0e7FD2Bf6067db6994CF12E4495Df938E6e9
    address public constant _WETH = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // address public constant _WETH = 0x5FbDB2315678afecb367f032d93F642f64180aa3;    // hardhat1
    // address public constant _WETH = 0x707531c9999AaeF9232C8FEfBA31FBa4cB78d84a;    // hardhat2

    /**
     * @notice ApproveProxy 合约地址 —— 用户实际授权（approve）的目标
     * @dev 设计意图：
     *      1. 可升级性：Router 升级时，用户不需要重新 approve，只需 ApproveProxy 将新 Router 加入白名单
     *      2. 安全收敛：ApproveProxy 代码极简（只有 claimTokens），审计成本低、攻击面小
     *      3. 权限隔离：只有被白名单许可的合约才能调用 claimTokens 拉用户的币
     *      调用链：Router → ApproveProxy.claimTokens(token, from, to, amount) → transferFrom
     */
    // ETH:     70cBb871E8f30Fc8Ce23609E9E0Ea87B6b222F58
    // ETH-DEV：02D0131E5Cc86766e234EbF1eBe33444443b98a3
    // BSC:     d99cAE3FAC551f6b6Ba7B9f19bDD316951eeEE98
    // OEC:     E9BBD6eC0c9Ca71d3DcCD1282EE9de4F811E50aF
    // LOCAL:   e7f1725E7734CE288F8367e1Bb143E90bb3F0512
    // LOCAL2:  95D7fF1684a8F2e202097F28Dc2e56F773A55D02
    // POLYGON: 40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // AVAX:    70cBb871E8f30Fc8Ce23609E9E0Ea87B6b222F58
    // FTM:     E9BBD6eC0c9Ca71d3DcCD1282EE9de4F811E50aF
    // ARB:     E9BBD6eC0c9Ca71d3DcCD1282EE9de4F811E50aF
    // OP:      100F3f74125C8c724C7C0eE81E4dd5626830dD9a
    // CRO:     E9BBD6eC0c9Ca71d3DcCD1282EE9de4F811E50aF
    // CFX:     100F3f74125C8c724C7C0eE81E4dd5626830dD9a
    // POLYZK   1b5d39419C268b76Db06DE49e38B010fbFB5e226
    address public constant _APPROVE_PROXY =
        0xd99cAE3FAC551f6b6Ba7B9f19bDD316951eeEE98;
    // address public constant _APPROVE_PROXY = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;    // hardhat1
    // address public constant _APPROVE_PROXY = 0x2538a10b7fFb1B78c890c870FC152b10be121f04;    // hardhat2

    /**
     * @notice WNativeRelayer 合约地址 —— 专门负责「WETH → ETH 解包」的无状态中介合约
     * @dev 【它解决什么问题】
     *      Router 内部统一用 WETH 处理兑换，最后给用户原生 ETH 时需要解包(WETH.withdraw)。
     *      但 WETH.withdraw(amount) 会把解出的 ETH 发给【msg.sender（谁调用就发给谁）】。
     *      若 Router 自己直接调 withdraw，ETH 就会落在 Router 里，带来两个问题：
     *        1. 安全：Router 逻辑复杂、被广泛调用，持有 ETH 余额会扩大攻击面；
     *           且任何人可故意往 Router 直接打 ETH「投毒」，干扰依赖 address(this).balance 的余额计算；
     *        2. 复杂度：Router 需额外逻辑管理这笔 ETH 余额。
     *
     *      【Relayer 如何解决】把"持有 ETH"这个危险状态转移到一个极简合约里。
     *      因为 withdraw 发给 msg.sender，就让 Relayer 去当这个 msg.sender：
     *        Router 把 WETH transfer 给 Relayer
     *          → Router 调 Relayer.withdraw()
     *          → Relayer 调 WETH.withdraw()，ETH 落到 Relayer（而非 Router）
     *          → Relayer 立刻把 ETH 转给最终 receiver，自身余额归 0
     *      （本仓库对应实现见 CommonLib._transferTokenToUser 的 ETH 分支）
     *
     *      【为什么 Relayer 安全】它代码极简（只做"解包 + 转发"）、无状态、每次操作完余额为 0，
     *      可视为"一次性管道"——钱流过即走、不沉淀，几乎没有攻击面；从而让复杂的 Router 始终不碰 ETH。
     */
    // ETH:     5703B683c7F928b721CA95Da988d73a3299d4757
    // BSC:     0B5f474ad0e3f7ef629BD10dbf9e4a8Fd60d9A48
    // OEC:     d99cAE3FAC551f6b6Ba7B9f19bDD316951eeEE98
    // LOCAL:   D49a0e9A4CD5979aE36840f542D2d7f02C4817Be
    // LOCAL2:  11457D5b1025D162F3d9B7dBeab6E1fBca20e043
    // POLYGON: f332761c673b59B21fF6dfa8adA44d78c12dEF09
    // AVAX:    3B86917369B83a6892f553609F3c2F439C184e31
    // FTM:     40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // ARB:     d99cAE3FAC551f6b6Ba7B9f19bDD316951eeEE98
    // OP:      40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // CRO:     40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // CFX:     40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
    // POLYZK   d2F0aC2012C8433F235c8e5e97F2368197DD06C7
    address public constant _WNATIVE_RELAY =
        0x0B5f474ad0e3f7ef629BD10dbf9e4a8Fd60d9A48;
    // address public constant _WNATIVE_RELAY = 0x0B306BF915C4d645ff596e518fAf3F9669b97016;   // hardhat1
    // address public constant _WNATIVE_RELAY = 0x6A47346e722937B60Df7a1149168c0E76DD6520f;   // hardhat2
}
