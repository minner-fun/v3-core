# Uniswap V3 快速参考指南

> 核心概念、公式、代码位置速查

---

## 🎯 核心概念速查

### 价格与Tick

```
Price = 1.0001^tick
sqrtPriceX96 = sqrt(Price) * 2^96
tick ∈ [-887272, 887272]
```

### 流动性公式

```
当前价格在区间内：
amount0 = L * (1/√P_current - 1/√P_upper)
amount1 = L * (√P_current - √P_lower)

当前价格在区间下方：
amount0 = L * (1/√P_lower - 1/√P_upper)
amount1 = 0

当前价格在区间上方：
amount0 = 0
amount1 = L * (√P_upper - √P_lower)
```

### 手续费计算

```
tokensOwed = (feeGrowthInside_now - feeGrowthInside_last) * liquidity / 2^128

feeGrowthInside = feeGrowthGlobal - feeGrowthBelow - feeGrowthAbove
```

---

## 📂 关键代码位置

### 核心合约

```
contracts/
├── UniswapV3Factory.sol (73行)
│   └── createPool() - 创建新池子
│
├── UniswapV3Pool.sol (879行) ⭐️ 核心
│   ├── initialize() - 初始化价格
│   ├── mint() - 添加流动性
│   ├── burn() - 移除流动性
│   ├── collect() - 提取代币/手续费
│   ├── swap() - 交换
│   └── flash() - 闪电贷
│
└── UniswapV3PoolDeployer.sol (38行)
    └── deploy() - CREATE2部署
```

### 数学库

```
libraries/
├── TickMath.sol ⭐️ Tick↔Price转换
│   ├── getSqrtRatioAtTick() - tick转价格
│   └── getTickAtSqrtRatio() - 价格转tick
│
├── SqrtPriceMath.sol ⭐️ 价格计算
│   ├── getNextSqrtPriceFromAmount0RoundingUp()
│   ├── getNextSqrtPriceFromAmount1RoundingDown()
│   ├── getAmount0Delta()
│   └── getAmount1Delta()
│
├── SwapMath.sol ⭐️ 交换计算
│   └── computeSwapStep() - 单Tick内交换
│
├── Tick.sol - Tick管理
│   ├── update() - 更新Tick
│   ├── cross() - 跨越Tick
│   └── getFeeGrowthInside() - 计算区间内手续费
│
├── TickBitmap.sol ⭐️ 位图优化
│   ├── flipTick() - 翻转Tick状态
│   └── nextInitializedTickWithinOneWord() - 找下一个Tick
│
├── Position.sol - 仓位管理
│   └── update() - 更新仓位
│
├── Oracle.sol - 预言机
│   ├── initialize()
│   ├── write()
│   └── observe()
│
└── FullMath.sol ⭐️ 高精度运算
    ├── mulDiv() - 避免溢出的乘除
    └── mulDivRoundingUp()
```

---

## 🔥 最常用代码片段

### 1. 计算仓位需要的代币数量

```solidity
function calculateTokenAmounts(
    uint160 sqrtPriceX96,
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
) public pure returns (uint256 amount0, uint256 amount1) {
    uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
    uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
    
    amount0 = SqrtPriceMath.getAmount0Delta(
        sqrtPriceX96,
        sqrtRatioBX96,
        liquidity,
        true
    );
    
    amount1 = SqrtPriceMath.getAmount1Delta(
        sqrtRatioAX96,
        sqrtPriceX96,
        liquidity,
        true
    );
}
```

### 2. 计算当前价格

```solidity
(uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
uint256 price = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 2**96) / 1e18;
```

### 3. 计算仓位应得手续费

```solidity
Position.Info memory position = pool.positions(positionKey);

(uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = 
    pool.getFeeGrowthInside(tickLower, tickUpper);

uint256 tokensOwed0 = FullMath.mulDiv(
    feeGrowthInside0X128 - position.feeGrowthInside0LastX128,
    position.liquidity,
    FixedPoint128.Q128
);
```

---

## 📊 数值范围

```
MIN_TICK = -887272
MAX_TICK = 887272

MIN_SQRT_RATIO = 4295128739
MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342

MIN_PRICE ≈ 2.938735877 × 10^-39
MAX_PRICE ≈ 3.406430312 × 10^38

tickSpacing:
- 10 (0.05% fee)
- 60 (0.3% fee)
- 200 (1% fee)

Q64.96: 96位小数精度
Q128: 128位小数精度
```

---

## 🛠️ 调试技巧

### 1. 查看池子状态

```javascript
const slot0 = await pool.slot0();
console.log('Price:', slot0.sqrtPriceX96.toString());
console.log('Tick:', slot0.tick);
console.log('Liquidity:', (await pool.liquidity()).toString());
```

### 2. 查看Tick信息

```javascript
const tickInfo = await pool.ticks(tick);
console.log('Gross:', tickInfo.liquidityGross.toString());
console.log('Net:', tickInfo.liquidityNet.toString());
console.log('Initialized:', tickInfo.initialized);
```

### 3. 查看仓位

```javascript
const positionKey = ethers.utils.keccak256(
    ethers.utils.solidityPack(
        ['address', 'int24', 'int24'],
        [owner, tickLower, tickUpper]
    )
);
const position = await pool.positions(positionKey);
```

---

## ⚡ Gas优化清单

- [ ] 使用Slot0打包读取状态
- [ ] 缓存存储变量到内存
- [ ] 使用位运算代替算术运算
- [ ] 批量更新存储
- [ ] 避免零值写入
- [ ] 使用immutable常量
- [ ] Library代替Contract
- [ ] 紧凑的函数参数
- [ ] 删除不用的存储槽

---

## 🔒 安全检查清单

- [ ] 使用lock修饰符防重入
- [ ] 设置sqrtPriceLimitX96限制滑点
- [ ] 验证Tick范围和对齐
- [ ] 检查流动性上限
- [ ] 回调中验证调用者
- [ ] 使用FullMath避免溢出
- [ ] TWAP而非即时价格
- [ ] 测试边界条件

---

## 📚 学习路径

### 初学者（1-2周）
1. 阅读系列总览
2. 理解V2和V3的区别
3. 学习Tick系统基础
4. 理解集中流动性概念

### 中级（2-4周）
1. 深入数学模型
2. 理解TickMath实现
3. 掌握流动性管理
4. 学习Swap流程

### 高级（4-8周）
1. 源码逐行分析
2. Gas优化技巧
3. 安全机制研究
4. 实战项目开发

---

## 🔗 资源链接

**官方**
- [V3 Whitepaper](https://uniswap.org/whitepaper-v3.pdf)
- [V3 Core GitHub](https://github.com/Uniswap/v3-core)
- [V3 Docs](https://docs.uniswap.org/)

**本系列文章**
- [00. 系列总览](./UNISWAP_V3_SOURCE_CODE_SERIES.md)
- [01. 架构设计](./01_ARCHITECTURE_DEEP_DIVE.md)
- [02. 数学模型](./02_MATH_MODEL_AND_ALGORITHMS.md)
- [03. Tick系统](./03_PRICE_AND_TICK_SYSTEM.md)
- [04. 流动性管理](./04_LIQUIDITY_MANAGEMENT.md)
- [05. Swap机制](./05_SWAP_MECHANISM_DEEP_DIVE.md)
- [06. Gas优化](./06_GAS_OPTIMIZATION_PRACTICES.md)
- [07. 安全机制](./07_SECURITY_MECHANISMS.md)

---

## ❓ 常见问题

**Q: 为什么使用√P而不是P？**
A: 简化流动性计算，避免开方运算，保持线性关系。

**Q: tickSpacing的作用是什么？**
A: 减少存储需求，匹配波动性，防止溢出。

**Q: 手续费何时计算？**
A: 在mint、burn、collect时计算并累加到tokensOwed。

**Q: 为什么burn不立即转账？**
A: Gas优化，允许批量提取，手续费一起提取。

**Q: TickBitmap如何工作？**
A: 使用位图标记Tick是否初始化，O(1)快速查找。

**Q: 最大流动性限制的原因？**
A: 防止liquidityNet溢出int128。

**Q: 如何防止MEV攻击？**
A: 设置滑点保护，使用Flashbots，考虑时机。

---

这份快速参考将帮助你在学习和开发过程中快速查找关键信息！

*配合系列文章使用效果更佳*

