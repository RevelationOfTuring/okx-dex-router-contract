// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeMath} from "./SafeMath.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20} from "./SafeERC20.sol";

/**
 * @title UniversalERC20 - 统一处理「原生 ETH」与「ERC20 代币」的工具库
 * @notice 提供一组 universalXxx 函数，用【同一套接口】同时支持原生币(ETH)与 ERC20：
 *         内部自动判断 token 是否为 ETH 占位地址，分别走 ETH 原生转账 / ERC20 调用。
 *         这样上层路由逻辑无需到处写 if(isETH) 分支，简化代码。
 * @dev 约定：用占位地址 0xEeee...EEeE 代表原生 ETH（行业惯例，见 CommonUtils._ETH）。
 *      ERC20 部分复用 SafeERC20 做安全调用（兼容不返回 bool 的 token、失败 revert 等）。
 */
library UniversalERC20 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20; // 让 IERC20 可直接调用 safeTransfer/safeTransferFrom/forceApprove

    /// @dev 原生 ETH 的占位地址（与 CommonUtils._ETH 一致）：用它在 IERC20 类型里"伪装"成 ETH
    IERC20 private constant ETH_ADDRESS =
        IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /**
     * @notice 通用转账：把 amount 数量的 token 转给 to，自动区分 ETH 与 ERC20。
     * @dev amount==0 时直接跳过（省 gas 且避免无谓调用）。
     *      ETH：用 to.transfer（注意只转发 2300 gas）；ERC20：用 SafeERC20.safeTransfer。
     * @param token  代币（ETH 用占位地址 ETH_ADDRESS）
     * @param to     收款地址（payable，以便接收 ETH）
     * @param amount 转账数量
     */
    function universalTransfer(
        IERC20 token,
        address payable to,
        uint256 amount
    ) internal {
        if (amount > 0) {
            if (isETH(token)) {
                to.transfer(amount);            // 原生 ETH 转账
            } else {
                token.safeTransfer(to, amount); // ERC20 安全转账
            }
        }
    }

    /**
     * @notice 通用授权转账：从 from 把 amount 数量的 ERC20 转给 to。
     * @dev 仅适用于 ERC20（原生 ETH 没有 transferFrom 语义，本函数不处理 ETH 分支）。
     *      amount==0 时跳过。底层用 SafeERC20.safeTransferFrom。
     * @param token  ERC20 代币
     * @param from   付款方（需已对本合约授权）
     * @param to     收款方（payable，签名保持一致性）
     * @param amount 转账数量
     */
    function universalTransferFrom(
        IERC20 token,
        address from,
        address payable to,
        uint256 amount
    ) internal {
        if (amount > 0) {
            token.safeTransferFrom(from, to, amount);
        }
    }

    /**
     * @notice 按需把 token 对 to 的授权额度提升到最大值（type(uint256).max）。
     * @dev 仅当现有 allowance 不足 amount 时才发起 approve，避免重复授权浪费 gas。
     *      用 forceApprove 设为最大值（一次授权后续免再授权）；forceApprove 兼容 USDT 等
     *      "改非零额度前需先清零"的 token。
     * @param token  ERC20 代币
     * @param to     被授权方（通常是某个会来 transferFrom 的合约，如池子/中介）
     * @param amount 本次所需的最小额度（仅用于判断是否需要重新授权）
     */
    function universalApproveMax(
        IERC20 token,
        address to,
        uint256 amount
    ) internal {
        uint256 allowance = token.allowance(address(this), to);
        if (allowance < amount) {
            token.forceApprove(to, type(uint256).max);
        }
    }

    /**
     * @notice 通用余额查询：返回 who 持有的 token 数量，自动区分 ETH 与 ERC20。
     * @dev ETH：返回 who.balance（地址原生余额）；ERC20：返回 token.balanceOf(who)。
     * @param token 代币（ETH 用占位地址）
     * @param who   被查询地址
     * @return 对应代币余额
     */
    function universalBalanceOf(IERC20 token, address who)
        internal
        view
        returns (uint256)
    {
        if (isETH(token)) {
            return who.balance;
        } else {
            return token.balanceOf(who);
        }
    }

    /**
     * @notice 纯 ERC20 余额查询：直接返回 token.balanceOf(who)，不做 ETH 判断。
     * @dev 与 universalBalanceOf 的区别：本函数【不处理 ETH】，调用方已确定 token 是 ERC20 时使用。
     * @param token ERC20 代币
     * @param who   被查询地址
     * @return ERC20 余额
     */
    function tokenBalanceOf(IERC20 token, address who)
        internal
        view
        returns (uint256)
    {
        return token.balanceOf(who);
    }

    /**
     * @notice 判断 token 是否为原生 ETH（即等于 ETH 占位地址 ETH_ADDRESS）。
     * @param token 待判断的代币
     * @return 是 ETH 返回 true，否则 false
     */
    function isETH(IERC20 token) internal pure returns (bool) {
        return token == ETH_ADDRESS;
    }
}
