# 第五篇：Uniswap V3 Swap机制源码深度剖析

> 全面解析swap函数的状态机设计与跨Tick交易实现

---

## 核心要点速览

### swap函数的精妙设计

```solidity
function swap(
    address recipient,
    bool zeroForOne,      // token0 -> token1 (true) or token1 -> token0 (false)
    int256 amountSpecified, // 正数=精确输入，负数=精确输出
    uint160 sqrtPriceLimitX96,
    bytes calldata data
) external override noDelegateCall returns (int256 amount0, int256 amount1);
```

### 核心循环：跨Tick交易

```solidity
while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
    // 1. 找到下一个初始化的Tick
    (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(...);
    
    // 2. 计算在当前Tick内的交换
    (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = 
        SwapMath.computeSwapStep(...);
    
    // 3. 更新状态
    state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount);
    state.amountCalculated -= step.amountOut;
    
    // 4. 如果到达边界，跨越Tick
    if (state.sqrtPriceX96 == TickMath.getSqrtRatioAtTick(step.tickNext)) {
        if (step.initialized) {
            int128 liquidityNet = ticks.cross(...);
            state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
        }
        state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
    }
}
```

### SwapMath.computeSwapStep详解

这是swap的核心计算函数：

```solidity
function computeSwapStep(
    uint160 sqrtRatioCurrentX96,  // 当前价格
    uint160 sqrtRatioTargetX96,   // 目标价格（下一个Tick）
    uint128 liquidity,            // 当前流动性
    int256 amountRemaining,       // 剩余交换数量
    uint24 feePips                // 手续费率
) internal pure returns (
    uint160 sqrtRatioNextX96,     // 交换后的价格
    uint256 amountIn,             // 实际输入
    uint256 amountOut,            // 实际输出
    uint256 feeAmount             // 手续费
) {
    bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
    bool exactIn = amountRemaining >= 0;
    
    if (exactIn) {
        // 精确输入模式
        uint256 amountRemainingLessFee = FullMath.mulDiv(
            uint256(amountRemaining),
            1e6 - feePips,
            1e6
        );
        
        amountIn = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
        
        if (amountRemainingLessFee >= amountIn) {
            sqrtRatioNextX96 = sqrtRatioTargetX96;  // 到达目标
        } else {
            sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(...);
        }
    } else {
        // 精确输出模式
        amountOut = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
        
        if (uint256(-amountRemaining) >= amountOut) {
            sqrtRatioNextX96 = sqrtRatioTargetX96;
        } else {
            sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(...);
        }
    }
    
    // 计算另一侧的数量和手续费
    if (sqrtRatioTargetX96 == sqrtRatioNextX96) {
        amountIn = ...;
        amountOut = ...;
    } else {
        amountIn = ...;
        amountOut = ...;
    }
    
    if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
        feeAmount = uint256(amountRemaining) - amountIn;
    } else {
        feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
    }
}
```

### 回调机制的完整流程

```solidity
// 1. Pool先转出代币
if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));
if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

// 2. 记录转出前的余额
uint256 balance0Before = balance0();
uint256 balance1Before = balance1();

// 3. 回调要求转入代币
IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);

// 4. 验证余额增加
if (amount0 > 0) require(balance0Before.add(uint256(amount0)) <= balance0());
if (amount1 > 0) require(balance1Before.add(uint256(amount1)) <= balance1());
```

### 关键特性

1. **跨Tick交易**：自动处理跨越多个价格区间
2. **双向交换**：支持token0→token1和token1→token0
3. **双模式**：精确输入或精确输出
4. **价格限制**：sqrtPriceLimitX96防止滑点
5. **闪电交易**：先转出后转入的设计

### 实战案例：跨3个Tick的交易

```
初始状态：
currentTick = 1000, liquidity = 1000000
amountIn = 10000 token0

Tick布局：
tick 1000: liquidityNet = 0 (current)
tick 1200: liquidityNet = +300000
tick 1500: liquidityNet = -200000
tick 1800: liquidityNet = -100000

交易流程：
Step 1: [1000, 1200), liquidity=1000000
  → 使用 3000 token0，获得output1
  → 到达tick 1200，跨越

Step 2: cross tick 1200
  → liquidity = 1000000 + 300000 = 1300000
  → 翻转feeGrowthOutside

Step 3: [1200, 1500), liquidity=1300000
  → 使用 4000 token0，获得output2
  → 到达tick 1500，跨越

Step 4: cross tick 1500
  → liquidity = 1300000 - 200000 = 1100000

Step 5: [1500, 1800), liquidity=1100000
  → 使用剩余 3000 token0，获得output3
  → 价格停在tick 1750（未到1800）

最终结果：
totalOutput = output1 + output2 + output3
finalTick = 1750
finalLiquidity = 1100000
```

### 关键优化

1. **TickBitmap快速查找**：O(1)找到下一个Tick
2. **循环内最小化SLOAD**：缓存状态到内存
3. **手续费即时更新**：避免后续重新计算
4. **预言机同步更新**：利用已有的SSTORE

---

*详细内容请参考系列文章和源码*

*本文是"Uniswap V3源码赏析系列"的第五篇*

