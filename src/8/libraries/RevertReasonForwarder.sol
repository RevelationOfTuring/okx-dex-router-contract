/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title RevertReasonForwarder
 * @notice 工具库：把「上一次外部调用」失败时返回的原始 revert 原因，原封不动地再次抛出（冒泡）。
 * @dev 典型用法：当本合约用底层 call/staticcall/delegatecall 调用外部合约，得到 success == false 时，
 *      调用 reRevert() 把对方的失败原因原样向上传递，而不是丢失它或替换成一句笼统的错误。
 *      这样最终调用者/前端/调试工具能看到「真正的失败原因」（如 "Insufficient liquidity"、自定义错误等）。
 *      用法示例：
 *          (bool ok, ) = target.call(data);
 *          if (!ok) RevertReasonForwarder.reRevert();
 */
library RevertReasonForwarder {
    /**
     * @notice 把最近一次外部调用返回的 returndata（即 revert 原因）原样 revert 出去。
     * @dev 只能在「紧接着一次外部调用之后」使用，因为它依赖 returndatacopy/returndatasize
     *      读取的是「最近一次外部调用」的返回数据缓冲区；中间若有别的调用会覆盖该缓冲区。
     */
    function reRevert() internal pure {
        // bubble up revert reason from latest external call
        // 把上一次外部调用的 revert 原因冒泡抛出
        /// @solidity memory-safe-assembly
        assembly { // solhint-disable-line no-inline-assembly
            // ptr = 当前空闲内存指针（free memory pointer），作为拷贝目标地址；
            // 这里只读 0x40 取地址、不更新它，因为下一步立即 revert 退出，无需归还内存
            let ptr := mload(0x40)
            // 把「最近一次外部调用」返回的全部数据（returndatasize 字节）从偏移 0 拷到内存 ptr 处；
            // 当外部调用是 revert 时，这段 returndata 正是对方的错误信息
            returndatacopy(ptr, 0, returndatasize())
            // 从 ptr 起、按 returndatasize 长度回滚，把原始 revert 原因原样抛给上层调用者
            revert(ptr, returndatasize())
        }
    }
}
