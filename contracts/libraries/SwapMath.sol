// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './FullMath.sol';
import './SqrtPriceMath.sol';

/// @title Computes the result of a swap within ticks 计算在tick范围内的交换结果
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick. 包含方法用于计算在单个tick价格范围内的交换结果，即单个tick。
library SwapMath {
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap 计算交换一些输入或输出，给定交换的参数
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive 手续费，加上输入量，永远不会超过交换的`amountSpecified`如果为正
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool 当前池子的sqrt价格
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred 不能超过的价格，从which the direction of the swap is inferred 推断交换的方向
    /// @param liquidity The usable liquidity 可用的流动性
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out 剩余的输入或输出量
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip 从输入量中收取的手续费，以百分之一为单位
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target 交换后，不超过目标价格的价格
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap 交换的输入量，基于交换的方向
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap 交换的输出量，基于交换的方向
    /// @return feeAmount The amount of input that will be taken as a fee 输入量作为手续费
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            if (amountRemainingLessFee >= amountIn) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
        } else {
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            if (uint256(-amountRemaining) >= amountOut) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
        }

        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // get the input/output amounts
        if (zeroForOne) {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // cap the output amount to not exceed the remaining output amount
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            // 没有达到目标，所以把剩余的最大输入作为手续费
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
