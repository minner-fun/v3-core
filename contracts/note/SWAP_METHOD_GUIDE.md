# Uniswap V3 Swap 方法详解

> 深入解析 Uniswap V3 核心交易方法 `swap()`，重点说明费用计算机制

---

## 📋 目录

1. [方法概述](#1-方法概述)
2. [方法签名与参数](#2-方法签名与参数)
3. [整体流程](#3-整体流程)
4. [费用计算详解](#4-费用计算详解)
5. [关键数据结构](#5-关键数据结构)
6. [代码逐行解析](#6-代码逐行解析)
7. [费用计算示例](#7-费用计算示例)

---

## 1. 方法概述

`swap()` 是 Uniswap V3 中执行代币交换的核心方法，它实现了：
- ✅ 在集中流动性区间内进行交易
- ✅ 跨多个 tick 的连续交易
- ✅ 手续费的计算和分配
- ✅ 协议费的提取
- ✅ 全局手续费增长率的更新

---

## 2. 方法签名与参数

```solidity
function swap(
    address recipient,           // 接收输出代币的地址
    bool zeroForOne,             // 交易方向：true = token0 → token1, false = token1 → token0
    int256 amountSpecified,      // 指定的输入/输出数量（正数=精确输入，负数=精确输出）
    uint160 sqrtPriceLimitX96,   // 价格限制（防止价格滑点过大）
    bytes calldata data          // 回调数据
) external override noDelegateCall returns (int256 amount0, int256 amount1)
```

### 2.1 参数说明

| 参数 | 类型 | 说明 |
|------|------|------|
| `recipient` | address | 接收输出代币的地址 |
| `zeroForOne` | bool | `true` = 用 token0 换 token1（价格下降）<br>`false` = 用 token1 换 token0（价格上升） |
| `amountSpecified` | int256 | 正数 = 精确输入模式（指定输入数量）<br>负数 = 精确输出模式（指定输出数量） |
| `sqrtPriceLimitX96` | uint160 | 价格下限/上限，防止滑点过大 |
| `data` | bytes | 传递给回调函数的数据 |

### 2.2 返回值

- `amount0`：token0 的净变化量（正数=池子收到，负数=池子支付）
- `amount1`：token1 的净变化量（正数=池子收到，负数=池子支付）

---

## 3. 整体流程

```
┌─────────────────────────────────────────────────────────┐
│ 1. 参数验证和初始化                                        │
│    - 检查 amountSpecified != 0                           │
│    - 检查池子未锁定                                        │
│    - 验证价格限制                                          │
│    - 初始化 SwapCache 和 SwapState                       │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ 2. 循环执行 Swap Steps                                    │
│    while (amountRemaining != 0 && price != limit) {     │
│      a) 查找下一个已初始化的 tick                         │
│      b) 计算当前 step 的交易结果                           │
│      c) 更新状态                                           │
│      d) 处理 tick 跨越（如果到达边界）                     │
│    }                                                      │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ 3. 费用计算和分配                                          │
│    - 计算基础手续费（SwapMath.computeSwapStep）           │
│    - 提取协议费（如果启用）                                │
│    - 更新全局手续费增长率                                  │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ 4. 更新状态和预言机                                        │
│    - 更新 slot0（价格、tick）                              │
│    - 更新流动性                                            │
│    - 写入预言机观察值（如果 tick 变化）                    │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ 5. 执行代币转账                                            │
│    - 调用回调函数获取输入代币                              │
│    - 转账输出代币给 recipient                              │
└─────────────────────────────────────────────────────────┘
```

---

## 4. 费用计算详解

费用计算是 swap 方法的核心，分为三个层次：

### 4.1 第一层：基础手续费计算（SwapMath.computeSwapStep）

在 `SwapMath.computeSwapStep()` 中计算每个 step 的基础手续费。

#### 4.1.1 精确输入模式（exactInput = true）

```solidity
// SwapMath.sol:40-52
if (exactIn) {
    // 1. 计算扣除手续费后的可用金额
    uint256 amountRemainingLessFee = FullMath.mulDiv(
        uint256(amountRemaining), 
        1e6 - feePips,  // 例如：1e6 - 3000 = 997000（0.3% 手续费）
        1e6
    );
    
    // 2. 计算需要多少输入才能到达目标价格
    amountIn = zeroForOne
        ? SqrtPriceMath.getAmount0Delta(...)  // token0 → token1
        : SqrtPriceMath.getAmount1Delta(...);   // token1 → token0
    
    // 3. 根据可用金额计算实际到达的价格
    if (amountRemainingLessFee >= amountIn) {
        sqrtRatioNextX96 = sqrtRatioTargetX96;  // 到达目标
    } else {
        sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(...);
    }
}
```

#### 4.1.2 精确输出模式（exactInput = false）

```solidity
// SwapMath.sol:53-65
else {
    // 直接计算输出数量
    amountOut = zeroForOne
        ? SqrtPriceMath.getAmount1Delta(...)
        : SqrtPriceMath.getAmount0Delta(...);
    
    // 根据输出限制计算价格
    if (uint256(-amountRemaining) >= amountOut) {
        sqrtRatioNextX96 = sqrtRatioTargetX96;
    } else {
        sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(...);
    }
}
```

#### 4.1.3 手续费金额计算

```solidity
// SwapMath.sol:91-96
if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
    // 情况1：精确输入但未到达目标价格
    // 剩余部分全部作为手续费
    feeAmount = uint256(amountRemaining) - amountIn;
} else {
    // 情况2：到达目标价格或精确输出模式
    // 手续费 = amountIn * fee / (1e6 - fee)
    feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
}
```

**公式推导**：
- 设输入为 `amountIn`，手续费为 `feeAmount`
- 实际用于交易的金额 = `amountIn - feeAmount`
- 手续费率 = `fee / 1e6`（例如 0.3% = 3000 / 1e6）
- `feeAmount = amountIn * fee / 1e6`
- 但实际计算中，使用：`feeAmount = amountIn * fee / (1e6 - fee)`

这是因为手续费是从输入中扣除的，所以：
- `amountIn = amountUsed + feeAmount`
- `feeAmount = amountUsed * fee / (1e6 - fee)`
- 其中 `amountUsed = amountIn - feeAmount`

### 4.2 第二层：协议费提取

协议费是从总手续费中提取的一部分，用于协议治理。

```solidity
// UniswapV3Pool.sol:691-695
if (cache.feeProtocol > 0) {
    uint256 delta = step.feeAmount / cache.feeProtocol;
    step.feeAmount -= delta;
    state.protocolFee += uint128(delta);
}
```

#### 4.2.1 feeProtocol 的含义

`feeProtocol` 是一个复合值，存储在 `slot0.feeProtocol` 中：
- 低 4 位：token0 的协议费比例（`feeProtocol % 16`）
- 高 4 位：token1 的协议费比例（`feeProtocol >> 4`）

```solidity
// UniswapV3Pool.sol:630
feeProtocol: zeroForOne 
    ? (slot0Start.feeProtocol % 16)   // token0 交易，使用低 4 位
    : (slot0Start.feeProtocol >> 4),  // token1 交易，使用高 4 位
```

#### 4.2.2 协议费比例

`feeProtocol` 的值表示 `1/x`：
- `feeProtocol = 0`：不收取协议费
- `feeProtocol = 4`：收取 1/4 = 25% 的手续费作为协议费
- `feeProtocol = 6`：收取 1/6 ≈ 16.67% 的手续费作为协议费
- `feeProtocol = 10`：收取 1/10 = 10% 的手续费作为协议费

**示例**：
- 如果 `feeProtocol = 6`，总手续费 = 100
- 协议费 = 100 / 6 = 16.67（向下取整 = 16）
- LP 手续费 = 100 - 16 = 84

### 4.3 第三层：全局手续费增长率更新

这是 V3 的核心创新，使用累加器模式记录手续费，避免为每个仓位单独计算。

```solidity
// UniswapV3Pool.sol:698-699
if (state.liquidity > 0)
    state.feeGrowthGlobalX128 += FullMath.mulDiv(
        step.feeAmount,           // 当前 step 的手续费
        FixedPoint128.Q128,       // 2^128，用于定点数计算
        state.liquidity           // 当前流动性
    );
```

#### 4.3.1 公式说明

```
feeGrowthGlobalX128 += (feeAmount * 2^128) / liquidity
```

**含义**：
- `feeGrowthGlobalX128` 表示**每单位流动性**累计获得的手续费
- 使用 Q128 定点数格式（类似 Q64.96，但这里是 Q128.0）
- 除以 `liquidity` 得到单位流动性的手续费增长

#### 4.3.2 为什么使用累加器？

**传统方式（V2）**：
- 每个仓位单独记录手续费
- 每次交易需要更新所有相关仓位
- Gas 成本高

**V3 累加器方式**：
- 全局记录累计手续费增长率
- 每个仓位记录上次更新时的增长率
- 提取时计算差值：`(当前增长率 - 上次增长率) * 流动性`
- 只在 mint/burn/collect 时更新，节省 gas

#### 4.3.3 提取手续费时的计算

```solidity
// 伪代码示例
uint256 feeGrowthInside = feeGrowthGlobal - feeGrowthOutsideLower - feeGrowthOutsideUpper;
uint256 feeOwed = (feeGrowthInside - position.feeGrowthInsideLast) * position.liquidity / Q128;
```

---

## 5. 关键数据结构

### 5.1 SwapCache

```solidity
struct SwapCache {
    uint8 feeProtocol;                          // 协议费比例
    uint128 liquidityStart;                     // 初始流动性
    uint32 blockTimestamp;                      // 区块时间戳
    int56 tickCumulative;                       // tick 累加值（预言机用）
    uint160 secondsPerLiquidityCumulativeX128;  // 每流动性秒数（预言机用）
    bool computedLatestObservation;             // 是否已计算最新观察值
}
```

### 5.2 SwapState

```solidity
struct SwapState {
    int256 amountSpecifiedRemaining;  // 剩余待交换数量
    int256 amountCalculated;          // 已计算出的输出数量
    uint160 sqrtPriceX96;             // 当前价格（sqrt）
    int24 tick;                        // 当前 tick
    uint256 feeGrowthGlobalX128;      // 全局手续费增长率
    uint128 protocolFee;              // 累计协议费
    uint128 liquidity;                // 当前流动性
}
```

### 5.3 StepComputations

```solidity
struct StepComputations {
    uint160 sqrtPriceStartX96;   // step 开始时的价格
    int24 tickNext;              // 下一个 tick
    bool initialized;            // tickNext 是否已初始化
    uint160 sqrtPriceNextX96;    // tickNext 对应的价格
    uint256 amountIn;            // 输入数量
    uint256 amountOut;           // 输出数量
    uint256 feeAmount;           // 手续费数量
}
```

---

## 6. 代码逐行解析

### 6.1 初始化阶段（605-647 行）

```solidity
// 605-611: 方法签名
function swap(...) external override noDelegateCall returns (int256 amount0, int256 amount1) {
    require(amountSpecified != 0, 'AS');  // 确保数量不为 0
    
    Slot0 memory slot0Start = slot0;      // 保存初始状态
    
    // 616-622: 验证池子未锁定，价格限制有效
    require(slot0Start.unlocked, 'LOK');
    require(
        zeroForOne
            ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
            : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
        'SPL'
    );
    
    slot0.unlocked = false;  // 锁定池子，防止重入
    
    // 626-634: 初始化 SwapCache
    SwapCache memory cache = SwapCache({
        liquidityStart: liquidity,
        blockTimestamp: _blockTimestamp(),
        feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
        secondsPerLiquidityCumulativeX128: 0,
        tickCumulative: 0,
        computedLatestObservation: false
    });
    
    bool exactInput = amountSpecified > 0;  // 判断是精确输入还是精确输出
    
    // 638-647: 初始化 SwapState
    SwapState memory state = SwapState({
        amountSpecifiedRemaining: amountSpecified,
        amountCalculated: 0,
        sqrtPriceX96: slot0Start.sqrtPriceX96,
        tick: slot0Start.tick,
        feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
        protocolFee: 0,
        liquidity: cache.liquidityStart
    });
```

### 6.2 主循环（650-739 行）

```solidity
// 650: 循环直到用完所有数量或到达价格限制
while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
    StepComputations memory step;
    
    step.sqrtPriceStartX96 = state.sqrtPriceX96;  // 记录开始价格
    
    // 655-659: 查找下一个已初始化的 tick
    (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
        state.tick,
        tickSpacing,
        zeroForOne
    );
    
    // 662-666: 确保不超出 tick 范围
    if (step.tickNext < TickMath.MIN_TICK) {
        step.tickNext = TickMath.MIN_TICK;
    } else if (step.tickNext > TickMath.MAX_TICK) {
        step.tickNext = TickMath.MAX_TICK;
    }
    
    // 669: 计算下一个 tick 对应的价格
    step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
    
    // 672-680: 计算当前 step 的交易结果
    (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
        state.sqrtPriceX96,
        (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
            ? sqrtPriceLimitX96  // 如果价格限制更近，使用限制价格
            : step.sqrtPriceNextX96,  // 否则使用下一个 tick 的价格
        state.liquidity,
        state.amountSpecifiedRemaining,
        fee
    );
    
    // 682-688: 更新剩余数量和已计算数量
    if (exactInput) {
        state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
        state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
    } else {
        state.amountSpecifiedRemaining += step.amountOut.toInt256();
        state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
    }
    
    // 691-695: 提取协议费
    if (cache.feeProtocol > 0) {
        uint256 delta = step.feeAmount / cache.feeProtocol;
        step.feeAmount -= delta;
        state.protocolFee += uint128(delta);
    }
    
    // 698-699: 更新全局手续费增长率
    if (state.liquidity > 0)
        state.feeGrowthGlobalX128 += FullMath.mulDiv(
            step.feeAmount, 
            FixedPoint128.Q128, 
            state.liquidity
        );
    
    // 702-738: 处理 tick 跨越
    if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
        // 到达了下一个 tick 边界
        if (step.initialized) {
            // tick 已初始化，需要更新流动性
            if (!cache.computedLatestObservation) {
                // 延迟计算预言机数据（只在第一次跨越 tick 时计算）
                (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(...);
                cache.computedLatestObservation = true;
            }
            // 跨越 tick，更新流动性
            int128 liquidityNet = ticks.cross(...);
            if (zeroForOne) liquidityNet = -liquidityNet;
            state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
        }
        state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
    } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
        // 价格变化但未到达 tick 边界，重新计算 tick
        state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
    }
}
```

### 6.3 状态更新（741-774 行）

```solidity
// 741-761: 如果 tick 变化，更新状态和预言机
if (state.tick != slot0Start.tick) {
    (uint16 observationIndex, uint16 observationCardinality) = observations.write(
        slot0Start.observationIndex,
        cache.blockTimestamp,
        slot0Start.tick,  // 写入旧 tick（交易开始时的 tick）
        cache.liquidityStart,
        slot0Start.observationCardinality,
        slot0Start.observationCardinalityNext
    );
    (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
        state.sqrtPriceX96,
        state.tick,
        observationIndex,
        observationCardinality
    );
} else {
    // tick 未变化，只更新价格
    slot0.sqrtPriceX96 = state.sqrtPriceX96;
}

// 764: 更新流动性（如果变化）
if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

// 768-774: 更新全局手续费增长率和协议费
if (zeroForOne) {
    feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
    if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
} else {
    feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
    if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
}
```

### 6.4 代币转账（776-797 行）

```solidity
// 776-778: 计算最终数量
(amount0, amount1) = zeroForOne == exactInput
    ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
    : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

// 781-793: 执行转账
if (zeroForOne) {
    // token0 → token1
    if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));
    
    uint256 balance0Before = balance0();
    IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
} else {
    // token1 → token0
    if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));
    
    uint256 balance1Before = balance1();
    IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
}

emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
slot0.unlocked = true;  // 解锁池子
```

---

## 7. 费用计算示例

### 7.1 示例场景

假设：
- 池子手续费率：0.3% (fee = 3000)
- 协议费比例：1/6 (feeProtocol = 6)
- 当前流动性：1000
- 一个 step 的输入：1000 token0
- 手续费率：3000 / 1e6 = 0.003

### 7.2 计算过程

#### Step 1: 基础手续费计算（SwapMath）

```solidity
// 精确输入模式
amountRemainingLessFee = 1000 * (1e6 - 3000) / 1e6 = 1000 * 997000 / 1000000 = 997

// 假设实际使用 997 token0，手续费为：
feeAmount = 1000 * 3000 / (1e6 - 3000) = 1000 * 3000 / 997000 ≈ 3.009
// 或更准确：feeAmount = 1000 - 997 = 3
```

#### Step 2: 协议费提取

```solidity
if (feeProtocol = 6) {
    delta = 3 / 6 = 0  // 整数除法，向下取整
    // 如果 feeAmount = 18，则 delta = 18 / 6 = 3
    step.feeAmount = 3 - 0 = 3  // LP 手续费
    protocolFee = 0  // 协议费（太小，被舍去）
}
```

#### Step 3: 全局手续费增长率更新

```solidity
// FixedPoint128.Q128 = 2^128
feeGrowthGlobalX128 += (3 * 2^128) / 1000
// 表示每单位流动性增加了 3/1000 的手续费
```

### 7.3 完整示例（较大金额）

假设：
- 输入：100,000 token0
- 手续费：100,000 * 0.003 = 300
- feeProtocol = 6

计算：
1. **基础手续费**：300 token0
2. **协议费**：300 / 6 = 50 token0
3. **LP 手续费**：300 - 50 = 250 token0
4. **手续费增长率**：如果流动性 = 1,000,000
   - `feeGrowthGlobalX128 += (250 * 2^128) / 1,000,000`
   - 每单位流动性增加 0.00025 token0 的手续费

---

## 8. 关键要点总结

### 8.1 费用计算三层次

1. **SwapMath.computeSwapStep**：计算基础手续费
   - 精确输入：`feeAmount = amountIn * fee / (1e6 - fee)`
   - 精确输出：类似计算

2. **协议费提取**：从总手续费中提取
   - `protocolFee = feeAmount / feeProtocol`
   - `lpFee = feeAmount - protocolFee`

3. **全局增长率更新**：累加器模式
   - `feeGrowthGlobalX128 += (lpFee * Q128) / liquidity`

### 8.2 设计优势

- ✅ **Gas 效率**：累加器模式避免频繁更新所有仓位
- ✅ **精度**：使用定点数保证计算精度
- ✅ **灵活性**：支持协议费配置
- ✅ **安全性**：重入保护、价格限制检查

### 8.3 注意事项

- ⚠️ 协议费使用整数除法，小金额可能被舍去
- ⚠️ 手续费增长率使用 Q128 定点数，提取时需要除以 Q128
- ⚠️ 流动性为 0 时，不更新手续费增长率（避免除零）

---

## 📚 相关代码位置

| 功能 | 文件 | 行号 |
|------|------|------|
| Swap 主方法 | `UniswapV3Pool.sol` | 605-797 |
| 基础手续费计算 | `SwapMath.sol` | 21-97 |
| 协议费设置 | `UniswapV3Pool.sol` | 846-854 |
| 全局手续费增长率 | `UniswapV3Pool.sol` | 77-79, 698-699 |
| 定点数常量 | `FixedPoint128.sol` | 7 |

---

**最后更新**：2024

