// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title SafeMath
 * @notice 数学运算工具库，包含两部分：
 *         (1) 经典的「溢出安全」整数运算（add/sub/mul/div/mod，OpenZeppelin 风格）；
 *         (2) DappHub 风格的「定点数」运算（WAD = 1e18 精度、RAY = 1e27 精度）及其乘除、幂运算。
 *
 * @dev 【关于 0.8+ 的重要说明】
 *      Solidity 0.8.0 起，原生的 +、-、*、/ 已【内置溢出/下溢检查】（溢出会自动 revert）。
 *      因此本库里的 add/sub/mul/div/mod 在功能上与原生运算符基本等价，主要价值在于：
 *        - 兼容从 0.7 及更早版本迁移过来的旧代码（保留同名 API）；
 *        - 允许自定义错误信息（sub/div/mod 的带 errorMessage 重载）。
 *      新代码若无上述需求，可直接使用原生运算符。
 *
 * @dev 【定点数约定（来自 MakerDAO/DappHub）】
 *      EVM 没有小数类型，故用「大整数 + 固定缩放因子」表示小数：
 *        - WAD：缩放 1e18，表示 18 位小数。例如 1.5 记作 1.5e18。
 *        - RAY：缩放 1e27，表示 27 位小数，用于需要更高精度的利率/累积计算。
 *      两个 WAD 相乘结果会带 1e36 缩放，需再除以 WAD 才回到 1e18 精度（wmul 即做此事）；除法同理（wdiv）。
 *
 * @dev 【WAD 还是 RAY？如何选择】
 *      - 用 WAD(1e18) 的场景：表示代币金额、普通比例/百分比、价格等「一次性、不反复累乘」的量。
 *        18 位小数与多数 ERC20 的 decimals 一致，够用且更省 gas、不易溢出。
 *      - 用 RAY(1e27) 的场景：利率、复利、按时间反复累乘的累积指数等「需要长期高精度」的量。
 *        典型如「每秒利率」是极接近 1 的数（如 1.0000000015...），用 1e18 会损失有效位，
 *        多次 rpow/rmul 累乘后误差被放大，必须用 1e27 才能保持精度（MakerDAO 的稳定费率即如此）。
 *      选择口诀：「算钱/比例用 WAD；算利率/复利累积用 RAY」。
 *      注意：精度越高越占数值空间，RAY 运算更易在大数下接近溢出，无高精度需求时优先 WAD。
 */
library SafeMath {
    /// @dev WAD 精度因子：1e18，代表 18 位小数的定点数缩放基准。
    uint256 constant WAD = 10 ** 18;
    /// @dev RAY 精度因子：1e27，代表 27 位小数的定点数缩放基准（高精度）。
    uint256 constant RAY = 10 ** 27;

    /// @notice 返回 WAD 常量（1e18）。
    function wad() public pure returns (uint256) {
        return WAD;
    }

    /// @notice 返回 RAY 常量（1e27）。
    function ray() public pure returns (uint256) {
        return RAY;
    }

    /**
     * @notice 安全加法：a + b，溢出则 revert。
     * @dev 通过 `c >= a` 检测溢出（无符号加法若回绕，结果必小于任一加数）。
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    /**
     * @notice 安全减法：a - b，若 b > a（下溢）则 revert（默认错误信息）。
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    /**
     * @notice 安全减法（可自定义错误信息）：a - b，要求 b <= a。
     * @param errorMessage 下溢时抛出的自定义错误信息。
     */
    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    /**
     * @notice 安全乘法：a * b，溢出则 revert。
     * @dev gas 优化：先单独处理 a==0 直接返回 0，比对 a、b 都做非零判断更省 gas；
     *      非零时用 `c / a == b` 反验来检测溢出。
     *      参考：https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @notice 安全除法：a / b（向下取整），除数为 0 则 revert（默认错误信息）。
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    /**
     * @notice 安全除法（可自定义错误信息）：a / b，要求 b > 0。
     * @param errorMessage 除数为 0 时抛出的自定义错误信息。
     */
    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @notice 安全取模：a % b，除数为 0 则 revert（默认错误信息）。
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    /**
     * @notice 安全取模（可自定义错误信息）：a % b，要求 b != 0。
     * @param errorMessage 除数为 0 时抛出的自定义错误信息。
     */
    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }

    /// @notice 返回两数较小值。
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }

    /// @notice 返回两数较大值。
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @notice 整数平方根（向下取整），即返回最大的 b 使 b*b <= a。
     * @dev 采用牛顿迭代法（巴比伦法）逼近：x_{n+1} = (a/x_n + x_n) / 2，收敛到 √a。
     *      边界处理：a==0 → 0；a 为 1~3 → 1（这些小值不进入迭代，直接给 1）。
     */
    function sqrt(uint256 a) internal pure returns (uint256 b) {
        if (a > 3) {
            b = a;
            uint256 x = a / 2 + 1; // 初始猜测值
            while (x < b) {
                // 迭代直到不再下降，即收敛
                b = x;
                x = (a / x + x) / 2; // 牛顿迭代步
            }
        } else if (a != 0) {
            b = 1; // a ∈ {1,2,3} 时 √a 向下取整均为 1
        }
        // a == 0 时 b 保持默认值 0
    }

    /**
     * @notice WAD 定点数乘法：a * b 后除以 WAD，结果回到 1e18 精度（向下取整）。
     * @dev 两个 1e18 缩放的数相乘得到 1e36 缩放，需 / WAD 归一化。
     */
    function wmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return mul(a, b) / WAD;
    }

    /**
     * @notice WAD 定点数乘法（四舍五入版）：在除以 WAD 前先加 WAD/2，实现就近取整。
     */
    function wmulRound(uint256 a, uint256 b) internal pure returns (uint256) {
        return add(mul(a, b), WAD / 2) / WAD;
    }

    /**
     * @notice RAY 定点数乘法：a * b 后除以 RAY，结果回到 1e27 精度（向下取整）。
     */
    function rmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return mul(a, b) / RAY;
    }

    /**
     * @notice RAY 定点数乘法（四舍五入版）：除以 RAY 前先加 RAY/2，实现就近取整。
     */
    function rmulRound(uint256 a, uint256 b) internal pure returns (uint256) {
        return add(mul(a, b), RAY / 2) / RAY;
    }

    /**
     * @notice WAD 定点数除法：a 先放大 WAD 倍再除以 b，保持 1e18 精度（向下取整）。
     * @dev 先 * WAD 再除，避免直接相除导致小数精度丢失。
     */
    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(mul(a, WAD), b);
    }

    /**
     * @notice WAD 定点数除法（四舍五入版）：a*WAD 后加 b/2 再除以 b，实现就近取整。
     */
    function wdivRound(uint256 a, uint256 b) internal pure returns (uint256) {
        return add(mul(a, WAD), b / 2) / b;
    }

    /**
     * @notice RAY 定点数除法：a 先放大 RAY 倍再除以 b，保持 1e27 精度（向下取整）。
     */
    function rdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(mul(a, RAY), b);
    }

    /**
     * @notice RAY 定点数除法（四舍五入版）：a*RAY 后加 b/2 再除以 b，实现就近取整。
     */
    function rdivRound(uint256 a, uint256 b) internal pure returns (uint256) {
        return add(mul(a, RAY), b / 2) / b;
    }

    /**
     * @notice WAD 定点数幂运算：计算 x^n（x 为 1e18 精度的定点数，n 为普通整数指数）。
     * @dev 采用「快速幂(平方求幂)」：把指数 n 按二进制拆分，每轮把底数自乘、遇到对应 bit 为 1 时累乘进结果，
     *      时间复杂度 O(log n)。结果初值取 WAD（即定点数的 1.0）。
     */
    function wpow(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 result = WAD; // 1.0（WAD 精度）作为幂的初始值
        while (n > 0) {
            if (n % 2 != 0) {
                // 当前最低位为 1 → 把当前底数累乘进结果
                result = wmul(result, x);
            }
            x = wmul(x, x); // 底数平方，对应处理下一个更高的 bit
            n /= 2; // 指数右移一位
        }
        return result;
    }

    /**
     * @notice RAY 定点数幂运算：计算 x^n（x 为 1e27 精度），实现同 wpow，仅精度基准换成 RAY。
     * @dev 常用于复利/利率累积等需要高精度的幂计算。
     */
    function rpow(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 result = RAY; // 1.0（RAY 精度）作为初始值
        while (n > 0) {
            if (n % 2 != 0) {
                result = rmul(result, x);
            }
            x = rmul(x, x);
            n /= 2;
        }
        return result;
    }

    /**
     * @notice 向上取整除法：返回 ceil(a / b)，即 a/b 有余数时结果 +1。
     * @dev 普通整数除法向下取整；本函数在有余数时进 1，常用于「所需份数/批次数」等不能向下取整的场景。
     */
    function divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 quotient = div(a, b); // 向下取整的商（b==0 会在 div 内 revert）
        uint256 remainder = a - quotient * b; // 余数
        if (remainder > 0) {
            return quotient + 1; // 有余数 → 向上进 1
        } else {
            return quotient; // 整除 → 直接返回
        }
    }
}
