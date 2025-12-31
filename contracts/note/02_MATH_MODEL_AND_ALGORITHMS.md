# 第二篇：Uniswap V3 数学模型与算法实现详解

> 深入解析V3的数学原理：为什么用√P、Q64.96定点数、以及防溢出的精妙技巧

---

## 📋 目录

1. [数学基础回顾](#1-数学基础回顾)
2. [为什么使用√P而非P](#2-为什么使用√p而非p)
3. [Q64.96定点数详解](#3-q6496定点数详解)
4. [FullMath高精度运算](#4-fullmath高精度运算)
5. [Tick与价格转换算法](#5-tick与价格转换算法)
6. [SqrtPriceMath核心算法](#6-sqrtpricemath核心算法)
7. [数值精度与舍入策略](#7-数值精度与舍入策略)
8. [总结与思考](#8-总结与思考)

---

## 1. 数学基础回顾

### 1.1 Uniswap V2的数学模型

**恒定乘积公式**：
```
x * y = k

其中：
x = token0储备量
y = token1储备量
k = 恒定常数
```

**价格定义**：
```
Price = y / x = token1 / token0
```

**交换公式**：
```
假设输入Δx，获得Δy
(x + Δx) * (y - Δy) = k = x * y

解得：
Δy = y * Δx / (x + Δx)
```

### 1.2 Uniswap V3的数学模型演进

**V3的核心改进：集中流动性**

在价格区间 [Pa, Pb] 内提供流动性L，虚拟储备量为：

```
x_virtual = L * (1/√Pa - 1/√Pb)
y_virtual = L * (√Pb - √Pa)

当前价格P时：
x_real = L * (1/√P - 1/√Pb)
y_real = L * (√P - √Pa)
```

**为什么引入√P？**（详见下节）

---

## 2. 为什么使用√P而非P

### 2.1 问题的提出

在AMM中，我们需要频繁计算：
1. 根据价格变化计算代币数量变化
2. 根据代币数量变化计算价格变化

**传统方式（使用P）**：
```
x * y = k
P = y / x

问题：需要频繁做开方和平方运算
√P = √(y/x) = √y / √x  ← 需要两次开方！
```

**V3方式（使用√P）**：
```
直接存储 sqrtP = √(y/x)

好处：避免开方运算
```

### 2.2 使用√P的数学优势

#### **优势1：流动性计算更简洁**

**使用P的公式**：
```
x = L / √P
y = L * √P

每次都需要计算 √P
```

**使用√P的公式**：
```
设 sqrtP = √P

x = L / sqrtP              ← 只需要一次除法
y = L * sqrtP              ← 只需要一次乘法

流动性 L = y / sqrtP = x * sqrtP
```

#### **优势2：价格更新更高效**

**交换Δy（token1）**：

使用P：
```
P_new = P + ΔP
需要计算 √P_new 和 √P
```

使用√P：
```
sqrtP_new = sqrtP + Δy / L     ← 直接线性关系！

证明：
y = L * sqrtP
dy = L * d(sqrtP)
d(sqrtP) = dy / L
```

**交换Δx（token0）**：

使用√P：
```
1/sqrtP_new = 1/sqrtP + Δx / L

证明：
x = L / sqrtP = L * (1/sqrtP)
dx = L * d(1/sqrtP)
d(1/sqrtP) = dx / L
```

#### **优势3：避免精度损失**

```
价格范围可能很大：
P ∈ [2^-128, 2^128]

如果直接存储P：
- 很小的价格（如 0.00001）精度损失大
- 很大的价格（如 100000）也可能溢出

使用√P：
sqrtP ∈ [2^-64, 2^64]
范围缩小，精度更好！
```

### 2.3 实际例子

**场景：ETH/USDC池，当前价格 P = 2500**

使用P：
```
P = 2500
需要计算：√2500 = 50

存储：2500（需要16位）
每次计算都需要开方
```

使用√P：
```
sqrtP = 50
直接存储和使用

存储：50（需要6位）
无需开方运算
```

**价格变化Δy = 100 USDC**：

使用P：
```
1. 计算 √P = √2500 = 50
2. 计算 Δ√P = 100 / L
3. 新的 √P_new = 50 + Δ√P
4. 计算 P_new = (√P_new)²
```

使用√P：
```
1. sqrtP_new = sqrtP + 100 / L  ← 一步完成！
```

---

## 3. Q64.96定点数详解

### 3.1 什么是定点数

**浮点数（float）**：
```
123.456 = 1.23456 × 10²
         ^符号  ^指数
```

**定点数（fixed point）**：
```
固定小数点位置

例如 Q32.32：
- 前32位：整数部分
- 后32位：小数部分

123.456 表示为：
123 << 32 + 0.456 * 2^32
```

### 3.2 V3的Q64.96格式

**定义**：
```
sqrtPriceX96 = sqrtPrice * 2^96

其中：
- 64位：整数部分（足够大）
- 96位：小数部分（足够精确）
- 总共：160位（正好uint160）
```

**为什么选96位小数部分？**

```
考虑价格精度：
1 basis point (0.01%) = 0.0001

在Q64.96格式：
0.0001 * 2^96 = 79,228,162,514
                ^ 约10位数字，精度足够

在Q64.32格式：
0.0001 * 2^32 = 429,496
                ^ 只有6位，精度不够

在Q64.128格式：
0.0001 * 2^128 = 34,028,236,692,093,846,346
                  ^ 精度过剩，浪费存储
```

**为什么选160位总长度？**

```
1. 正好是一个存储槽的大小（256位可以放1.6个）
2. 满足价格范围需求：
   MIN_SQRT_RATIO = 4295128739 (约2^32)
   MAX_SQRT_RATIO = 2^160 - 1
   
3. 与address类型一致（都是160位）
```

### 3.3 Q64.96运算规则

#### **乘法**：
```solidity
// sqrtPriceX96 * value
result = (sqrtPriceX96 * value) >> 96

原理：
(P * 2^96) * value = P * value * 2^96
结果右移96位保持格式
```

#### **除法**：
```solidity
// sqrtPriceX96 / value
result = (sqrtPriceX96 << 96) / value

原理：
(P * 2^96) / value = P / value * 2^96
需要先左移96位维持精度
```

#### **平方**：
```solidity
// sqrtPriceX96 * sqrtPriceX96 = priceX192
result = (sqrtPriceX96 * sqrtPriceX96) >> 96

原理：
(√P * 2^96) * (√P * 2^96) = P * 2^192
右移96位得到 P * 2^96
```

### 3.4 精度示例

**场景：ETH/USDC，价格 = 2500**

```javascript
// 价格
P = 2500

// 平方根价格
sqrtP = √2500 = 50

// Q64.96格式
sqrtPriceX96 = 50 * 2^96
             = 50 * 79228162514264337593543950336
             = 3961408125713216879677197266880

// 验证：
sqrtPriceX96 / 2^96 = 50 ✓

// 恢复价格：
P = (sqrtPriceX96 / 2^96)²
  = 50² = 2500 ✓
```

---

## 4. FullMath高精度运算

### 4.1 溢出问题

**Solidity的限制**：
```solidity
uint256最大值 = 2^256 - 1

问题：
a * b / c

如果 a * b > 2^256，直接溢出！
```

**常见场景**：
```solidity
// 计算手续费
feeAmount = liquidityAmount * feeGrowth / 2^128

如果 liquidityAmount = 2^128
    feeGrowth = 2^130
    
则 liquidityAmount * feeGrowth = 2^258 ← 溢出！
```

### 4.2 FullMath.mulDiv实现

**核心思想：使用512位中间结果**

```solidity
function mulDiv(
    uint256 a,
    uint256 b,
    uint256 denominator
) internal pure returns (uint256 result) {
    // 步骤1：计算512位乘积 [prod1 prod0] = a * b
    uint256 prod0; // 低256位
    uint256 prod1; // 高256位
    
    assembly {
        // mulmod(a, b, not(0)) = (a * b) % 2^256
        let mm := mulmod(a, b, not(0))
        // mul(a, b) = (a * b) mod 2^256
        prod0 := mul(a, b)
        // prod1 = (a * b) / 2^256
        prod1 := sub(sub(mm, prod0), lt(mm, prod0))
    }
    
    // 步骤2：如果没有溢出，直接除法
    if (prod1 == 0) {
        require(denominator > 0);
        assembly {
            result := div(prod0, denominator)
        }
        return result;
    }
    
    // 步骤3：处理溢出情况（512位除法）
    require(denominator > prod1);  // 确保结果 < 2^256
    
    // 步骤4：计算余数
    uint256 remainder;
    assembly {
        remainder := mulmod(a, b, denominator)
    }
    
    // 步骤5：减去余数使除法精确
    assembly {
        prod1 := sub(prod1, gt(remainder, prod0))
        prod0 := sub(prod0, remainder)
    }
    
    // 步骤6：提取2的幂次因子
    uint256 twos = -denominator & denominator;  // 最低位的1
    assembly {
        denominator := div(denominator, twos)
        prod0 := div(prod0, twos)
    }
    
    // 步骤7：移位合并
    assembly {
        twos := add(div(sub(0, twos), twos), 1)
    }
    prod0 |= prod1 * twos;
    
    // 步骤8：计算denominator的模逆
    // 使用牛顿迭代法
    uint256 inv = (3 * denominator) ^ 2;
    inv *= 2 - denominator * inv;  // mod 2^8
    inv *= 2 - denominator * inv;  // mod 2^16
    inv *= 2 - denominator * inv;  // mod 2^32
    inv *= 2 - denominator * inv;  // mod 2^64
    inv *= 2 - denominator * inv;  // mod 2^128
    inv *= 2 - denominator * inv;  // mod 2^256
    
    // 步骤9：最终结果 = prod0 * inv
    result = prod0 * inv;
    return result;
}
```

### 4.3 原理解析

#### **512位乘法**

```
a * b = prod1 * 2^256 + prod0

例如：
a = 2^200
b = 2^200
a * b = 2^400

在512位表示：
prod1 = 2^400 / 2^256 = 2^144
prod0 = 2^400 % 2^256 = 0
```

#### **中国剩余定理（CRT）**

```
利用两个模运算恢复原数：
x mod 2^256      -> prod0
x mod (2^256-1)  -> mm

通过CRT恢复完整的512位数
```

#### **模逆运算**

```
目标：找到 inv 使得 denominator * inv ≡ 1 (mod 2^256)

方法：牛顿迭代
初始：inv = (3 * d) ^ 2  正确到mod 2^4
迭代：inv = inv * (2 - d * inv)  每次精度翻倍

迭代6次后：精度达到 mod 2^256
```

### 4.4 实际案例

**计算手续费**：

```solidity
// 场景：
liquidity = 10^18
feeGrowth = 10^30
FixedPoint128.Q128 = 2^128

// 手续费 = liquidity * feeGrowth / 2^128

// 直接计算会溢出：
10^18 * 10^30 = 10^48 > 2^256 ❌

// 使用FullMath.mulDiv：
FullMath.mulDiv(
    10^18,      // a
    10^30,      // b
    2^128       // denominator
) = 10^48 / 2^128 ✓

// 流程：
1. 计算512位乘积：10^48
2. 除以 2^128
3. 结果在256位范围内
```

---

## 5. Tick与价格转换算法

### 5.1 Tick的定义

```
Price = 1.0001^tick

其中：
tick ∈ [-887272, 887272]

为什么是1.0001？
-> 0.01% 的价格步长
-> 精度足够，又不会太密集
```

**价格范围**：
```
MIN_PRICE = 1.0001^(-887272) ≈ 2^-128
MAX_PRICE = 1.0001^887272 ≈ 2^128

覆盖范围：约 10^77 倍
```

### 5.2 getSqrtRatioAtTick算法

**目标：计算 sqrt(1.0001^tick) * 2^96**

**朴素方法**：
```solidity
// ❌ 这样不行
sqrtPrice = sqrt(1.0001^tick) * 2^96
```

**问题**：
1. Solidity没有pow函数
2. 没有sqrt函数
3. 没有浮点数

**V3的解决方案：位分解 + 预计算**

```solidity
function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
    // 步骤1：取绝对值
    uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
    require(absTick <= uint256(MAX_TICK), 'T');
    
    // 步骤2：初始化ratio
    // 如果tick最低位是1，ratio = sqrt(1.0001^1)
    // 否则 ratio = 1
    uint256 ratio = absTick & 0x1 != 0 
        ? 0xfffcb933bd6fad37aa2d162d1a594001  // sqrt(1.0001^1)
        : 0x100000000000000000000000000000000;  // 1
    
    // 步骤3：检查每一位，累乘对应的预计算值
    if (absTick & 0x2 != 0)    ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;  // sqrt(1.0001^2)
    if (absTick & 0x4 != 0)    ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;  // sqrt(1.0001^4)
    if (absTick & 0x8 != 0)    ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;  // sqrt(1.0001^8)
    if (absTick & 0x10 != 0)   ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;  // sqrt(1.0001^16)
    // ... 更多位
    if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;  // sqrt(1.0001^524288)
    
    // 步骤4：如果tick是负数，取倒数
    if (tick > 0) ratio = type(uint256).max / ratio;
    
    // 步骤5：从Q128.128转换为Q64.96
    sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
}
```

**原理：二进制分解**

```
例如 tick = 19 = 0b10011

10011 = 16 + 2 + 1

所以：
1.0001^19 = 1.0001^16 * 1.0001^2 * 1.0001^1

只需要预计算：
1.0001^1, 1.0001^2, 1.0001^4, 1.0001^8, 1.0001^16, ...

最多20次乘法（因为tick最大约2^20）
```

**魔法数字的来源**：

```javascript
// 计算 sqrt(1.0001^(2^n)) * 2^128

function computeMagicNumber(n) {
    const base = 1.0001;
    const exponent = 2 ** n;
    const value = Math.sqrt(base ** exponent);
    const fixed = BigInt(Math.floor(value * (2 ** 128)));
    return '0x' + fixed.toString(16);
}

computeMagicNumber(0);  // sqrt(1.0001^1)
// -> 0xfffcb933bd6fad37aa2d162d1a594001

computeMagicNumber(1);  // sqrt(1.0001^2)
// -> 0xfff97272373d413259a46990580e213a

// ...
```

### 5.3 getTickAtSqrtRatio算法

**目标：给定sqrtPrice，计算对应的tick**

**数学关系**：
```
sqrtPrice = sqrt(1.0001^tick)
sqrt(1.0001^tick) = 1.0001^(tick/2)

两边取log：
log(sqrtPrice) = (tick/2) * log(1.0001)
tick = 2 * log(sqrtPrice) / log(1.0001)
```

**实现思路**：

1. **计算 log₂(sqrtPrice)**：使用MSB（最高有效位）
2. **转换为 log₁.₀₀₀₁**：使用换底公式

```solidity
function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
    require(sqrtPriceX96 >= MIN_SQRT_RATIO && sqrtPriceX96 < MAX_SQRT_RATIO, 'R');
    
    // 步骤1：转换为Q128.128
    uint256 ratio = uint256(sqrtPriceX96) << 32;
    
    // 步骤2：计算MSB（最高有效位）
    uint256 r = ratio;
    uint256 msb = 0;
    
    // 二分查找MSB
    assembly {
        let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
        msb := or(msb, f)
        r := shr(f, r)
    }
    // ... 更多二分步骤
    
    // 步骤3：归一化到[1, 2)范围
    if (msb >= 128) r = ratio >> (msb - 127);
    else r = ratio << (127 - msb);
    
    // 步骤4：计算log₂(r)（在[0, 1)范围）
    int256 log_2 = (int256(msb) - 128) << 64;
    
    // 泰勒展开计算对数
    assembly {
        r := shr(127, mul(r, r))
        let f := shr(128, r)
        log_2 := or(log_2, shl(63, f))
        r := shr(f, r)
    }
    // ... 14次迭代
    
    // 步骤5：换底公式转换为log₁.₀₀₀₁
    // log₁.₀₀₀₁(P) = log₂(P) / log₂(1.0001)
    int256 log_sqrt10001 = log_2 * 255738958999603826347141;
    
    // 步骤6：计算tick = 2 * log_sqrt10001(sqrtPrice)
    int24 tickLow = int24((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128);
    int24 tickHi = int24((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128);
    
    // 步骤7：验证并返回
    tick = tickLow == tickHi ? tickLow : (getSqrtRatioAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow);
}
```

**关键技巧**：

1. **MSB查找**：O(log n)确定最高位
2. **泰勒展开**：精确计算对数
3. **定点数运算**：全程避免浮点数
4. **范围验证**：最后验证确保正确性

---

## 6. SqrtPriceMath核心算法

### 6.1 根据Δx计算新价格

**公式推导**：
```
x = L / sqrtP

Δx = L * (1/sqrtP_new - 1/sqrtP_old)
   = L * (sqrtP_old - sqrtP_new) / (sqrtP_new * sqrtP_old)

解得：
sqrtP_new = L * sqrtP_old / (L + Δx * sqrtP_old)
```

**实现**：
```solidity
function getNextSqrtPriceFromAmount0RoundingUp(
    uint160 sqrtPX96,
    uint128 liquidity,
    uint256 amount,
    bool add
) internal pure returns (uint160) {
    if (amount == 0) return sqrtPX96;
    
    uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;  // L * 2^96
    
    if (add) {
        // 添加x -> 价格下降
        uint256 product;
        if ((product = amount * sqrtPX96) / amount == sqrtPX96) {
            // 没有溢出
            uint256 denominator = numerator1 + product;
            if (denominator >= numerator1)
                return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
        }
        // 溢出的情况
        return uint160(UnsafeMath.divRoundingUp(numerator1, (numerator1 / sqrtPX96).add(amount)));
    } else {
        // 移除x -> 价格上升
        uint256 product;
        require((product = amount * sqrtPX96) / amount == sqrtPX96 && numerator1 > product);
        uint256 denominator = numerator1 - product;
        return FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator).toUint160();
    }
}
```

### 6.2 根据Δy计算新价格

**公式推导**：
```
y = L * sqrtP

Δy = L * (sqrtP_new - sqrtP_old)

解得：
sqrtP_new = sqrtP_old + Δy / L
```

**实现**：
```solidity
function getNextSqrtPriceFromAmount1RoundingDown(
    uint160 sqrtPX96,
    uint128 liquidity,
    uint256 amount,
    bool add
) internal pure returns (uint160) {
    if (add) {
        // 添加y -> 价格上升
        uint256 quotient = amount <= type(uint160).max
            ? (amount << FixedPoint96.RESOLUTION) / liquidity  // 优化：直接位移除法
            : FullMath.mulDiv(amount, FixedPoint96.Q96, liquidity);  // 溢出时用高精度
        
        return uint256(sqrtPX96).add(quotient).toUint160();
    } else {
        // 移除y -> 价格下降
        uint256 quotient = amount <= type(uint160).max
            ? UnsafeMath.divRoundingUp(amount << FixedPoint96.RESOLUTION, liquidity)
            : FullMath.mulDivRoundingUp(amount, FixedPoint96.Q96, liquidity);
        
        require(sqrtPX96 > quotient);
        return uint160(sqrtPX96 - quotient);
    }
}
```

### 6.3 计算代币数量

**amount0Delta（给定价格区间）**：
```solidity
function getAmount0Delta(
    uint160 sqrtRatioAX96,
    uint160 sqrtRatioBX96,
    uint128 liquidity
) internal pure returns (uint256) {
    // 公式：Δx = L * (sqrtPB - sqrtPA) / (sqrtPA * sqrtPB)
    
    if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
    
    uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
    uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;
    
    return FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
}
```

**amount1Delta**：
```solidity
function getAmount1Delta(
    uint160 sqrtRatioAX96,
    uint160 sqrtRatioBX96,
    uint128 liquidity
) internal pure returns (uint256) {
    // 公式：Δy = L * (sqrtPB - sqrtPA)
    
    if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
    
    return FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);
}
```

---

## 7. 数值精度与舍入策略

### 7.1 为什么需要舍入策略

**问题场景**：
```
计算需要的token数量：
amount = liquidity * priceDelta / 2^96

结果可能有小数：123.456789...
```

**两种舍入方式**：
```
向下舍入（floor）：123
向上舍入（ceil）： 124
```

**影响**：
- 向下舍入：可能导致池子收到的代币少于应得
- 向上舍入：可能导致池子收到的代币多于应得

### 7.2 V3的舍入原则

**核心原则：保护池子**

```
池子收代币时：向上舍入（多收）
池子给代币时：向下舍入（少给）

目的：确保池子的资产只增不减
```

**具体规则**：

| 操作 | 计算方向 | 舍入方向 | 原因 |
|------|----------|----------|------|
| mint | 计算用户需给的代币 | 向上 | 多收保护池子 |
| burn | 计算用户能取的代币 | 向下 | 少给保护池子 |
| swap（输入） | 计算输出数量 | 向下 | 少给保护池子 |
| swap（输出） | 计算输入数量 | 向上 | 多收保护池子 |
| fee | 计算手续费 | 向上 | 多收保护池子 |

### 7.3 实现示例

```solidity
// FullMath.sol

// 向下舍入
function mulDiv(uint256 a, uint256 b, uint256 denominator) 
    internal pure returns (uint256 result) 
{
    // ... 省略计算过程
    result = prod0 * inv;  // 默认向下
}

// 向上舍入
function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) 
    internal pure returns (uint256 result) 
{
    result = mulDiv(a, b, denominator);
    if (mulmod(a, b, denominator) > 0) {  // 有余数
        require(result < type(uint256).max);
        result++;  // 加1向上舍入
    }
}
```

### 7.4 精度损失分析

**典型场景**：

```solidity
// 小额流动性
liquidity = 100
priceDelta = 1

// 计算amount
amount = 100 * 1 / 2^96 = 0.0000...0126  ← 非常小！

// 向下舍入
floor(amount) = 0  ← 损失100%精度！

// 向上舍入
ceil(amount) = 1   ← 多收1 wei，可接受
```

**V3的处理**：

1. **最小流动性限制**：
```solidity
require(liquidity > 0);  // 防止0流动性
```

2. **最小Tick间距**：
```solidity
tickSpacing >= 10  // 确保价格变化足够大
```

3. **累积误差处理**：
```solidity
// 使用feeGrowthGlobal累积，减少小额误差影响
```

---

## 8. 总结与思考

### 8.1 核心要点总结

1. **√P的优势**：
   - 简化流动性计算
   - 避免开方运算
   - 线性价格更新
   - 更好的精度范围

2. **Q64.96定点数**：
   - 96位小数精度
   - 160位总长度（与address一致）
   - 高效的位运算

3. **FullMath**：
   - 512位中间结果
   - 避免溢出
   - 牛顿迭代求模逆

4. **Tick算法**：
   - 二进制分解
   - 预计算魔法数字
   - O(log n)复杂度

5. **舍入策略**：
   - 保护池子原则
   - 收入向上，支出向下
   - 最小化累积误差

### 8.2 思考题

1. **如果使用Q64.128而非Q64.96，会有什么影响？**

2. **为什么tick的基数是1.0001而不是1.001或1.00001？**

3. **FullMath.mulDiv中的模逆运算为什么使用牛顿迭代？**

4. **如果不使用舍入保护，攻击者可以如何利用？**

5. **Q64.96格式下，最小可表示的价格变化是多少？**

### 8.3 延伸阅读

- **下一篇**：[价格机制与Tick系统源码分析](./03_PRICE_AND_TICK_SYSTEM.md)
- **相关库**：
  - [TickMath.sol](../libraries/TickMath.sol)
  - [FullMath.sol](../libraries/FullMath.sol)
  - [SqrtPriceMath.sol](../libraries/SqrtPriceMath.sol)
- **数学背景**：
  - [定点数运算](https://en.wikipedia.org/wiki/Fixed-point_arithmetic)
  - [牛顿迭代法](https://en.wikipedia.org/wiki/Newton%27s_method)

---

## 9. 数学附录

### 9.1 常用公式汇总

```
基本关系：
P = y / x
sqrtP = √P = √(y/x)
L = √(x * y)

流动性公式：
L = Δy / ΔsqrtP = Δx * sqrtP / ΔsqrtP
Δx = L * ΔsqrtP / sqrtP = L * (1/sqrtP_b - 1/sqrtP_a)
Δy = L * ΔsqrtP

价格更新：
sqrtP_new = sqrtP_old + Δy / L
1/sqrtP_new = 1/sqrtP_old + Δx / L

Tick转换：
P = 1.0001^tick
sqrtP = 1.0001^(tick/2)
tick = log₁.₀₀₀₁(P) = log(P) / log(1.0001)
```

### 9.2 数值范围

```
Tick范围：
MIN_TICK = -887272
MAX_TICK = 887272

价格范围：
MIN_PRICE = 1.0001^(-887272) ≈ 2.938735877 × 10^-39
MAX_PRICE = 1.0001^887272 ≈ 3.406430312 × 10^38

SqrtPrice范围（X96）：
MIN_SQRT_RATIO = 4295128739
MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342

流动性范围：
MAX_LIQUIDITY_PER_TICK = (2^128 - 1) / (MAX_TICK - MIN_TICK)
```

---

V3的数学设计体现了以太坊智能合约编程的最高水平：在有限的EVM指令集下，通过巧妙的数学变换和算法优化，实现了高精度、高效率的计算。

**下一篇预告**：我们将深入Tick系统的实现细节，解析TickBitmap的精妙优化，以及Tick跨越机制的完整流程。

---

*本文是"Uniswap V3源码赏析系列"的第二篇，更多内容请查看[系列目录](./UNISWAP_V3_SOURCE_CODE_SERIES.md)*

