# 第六篇：Uniswap V3 Gas优化技巧与工程实践

> 教科书级的Gas优化技巧全解析

---

## Gas优化技巧清单

### 1. 存储布局优化

#### Slot0打包（31 bytes → 1个存储槽）

```solidity
struct Slot0 {
    uint160 sqrtPriceX96;           // 20 bytes
    int24 tick;                      // 3 bytes
    uint16 observationIndex;         // 2 bytes
    uint16 observationCardinality;   // 2 bytes
    uint16 observationCardinalityNext; // 2 bytes
    uint8 feeProtocol;               // 1 byte
    bool unlocked;                   // 1 byte
}  // 总计 31 bytes，正好小于32 bytes！

// 效果：一次SLOAD读取所有状态
Slot0 memory _slot0 = slot0;  // 2100 gas
// vs 分别读取：7 * 2100 = 14700 gas
// 节省：85.7%
```

#### ProtocolFees打包

```solidity
struct ProtocolFees {
    uint128 token0;  // 16 bytes
    uint128 token1;  // 16 bytes
}  // 总计 32 bytes，正好1个槽
```

### 2. 缓存策略

#### 将存储变量缓存到内存

```solidity
// ❌ 低效：每次都SLOAD
function bad() {
    if (slot0.unlocked) {  // SLOAD 2100
        slot0.tick = ...;   // SLOAD 2100 + SSTORE 5000
        slot0.sqrtPriceX96 = ...;  // 再次SLOAD + SSTORE
    }
}

// ✅ 高效：缓存到内存
function good() {
    Slot0 memory _slot0 = slot0;  // SLOAD 2100（一次）
    if (_slot0.unlocked) {
        _slot0.tick = ...;         // 内存操作 3 gas
        _slot0.sqrtPriceX96 = ...;  // 内存操作 3 gas
        slot0 = _slot0;            // SSTORE 5000（一次）
    }
}

// 节省：多个SLOAD/SSTORE → 一次读一次写
```

### 3. 位运算优化

#### TickBitmap的位运算

```solidity
// 翻转bit：使用XOR而非条件判断
function flipTick(mapping(int16 => uint256) storage self, int24 tick, int24 tickSpacing) {
    (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
    uint256 mask = 1 << bitPos;
    self[wordPos] ^= mask;  // XOR翻转，3 gas
    
    // vs 条件判断：
    // if (bit == 1) self[wordPos] &= ~mask;
    // else self[wordPos] |= mask;
    // 多一个SLOAD和分支判断
}
```

#### 位移代替乘除法

```solidity
// 除以2^n
value >> n  // 位移，3 gas

// vs
value / (2 ** n)  // 除法，5 gas

// 乘以2^n
value << n  // 位移，3 gas

// vs
value * (2 ** n)  // 乘法，5 gas
```

### 4. 短路评估

```solidity
// ✅ 将最可能失败的条件放前面
require(amount > 0 && tickLower < tickUpper && tickLower >= MIN_TICK);
//       ↑最常见     ↑较常见              ↑极少失败

// ❌ 昂贵的检查放前面
require(tickLower >= MIN_TICK && amount > 0);
```

### 5. 避免零值写入

```solidity
// ✅ 只在有值时写入
if (tokensOwed0 > 0 || tokensOwed1 > 0) {
    self.tokensOwed0 += tokensOwed0;
    self.tokensOwed1 += tokensOwed1;
}

// ❌ 总是写入
self.tokensOwed0 += tokensOwed0;  // 即使为0也写入，浪费20000 gas
```

### 6. 使用unchecked（Solidity 0.8+）

```solidity
// V3使用0.7.6，但原理相同
// 使用LowGasSafeMath避免溢出检查

// ✅ 明确不会溢出时
function addDelta(uint128 x, int128 y) internal pure returns (uint128) {
    if (y < 0) {
        return x - uint128(-y);  // 无溢出检查
    } else {
        return x + uint128(y);
    }
}

// ❌ SafeMath每次都检查溢出
```

### 7. 常量vs Immutable vs Storage

```solidity
// 最优：常量（编译时内联）
uint24 public constant MIN_FEE = 500;  // 0 gas

// 次优：immutable（部署时设置，内联到bytecode）
address public immutable factory;  // ~100 gas (从bytecode读取)
address public immutable token0;

// 最差：storage
uint24 public fee;  // 2100 gas (SLOAD)
```

### 8. 事件优化

```solidity
// ✅ indexed参数可以过滤，但限制3个
event Swap(
    address indexed sender,
    address indexed recipient,
    int256 amount0,
    int256 amount1,
    uint160 sqrtPriceX96,
    uint128 liquidity,
    int24 tick
);

// indexed参数：存储在topics（可搜索，较贵）
// 非indexed：存储在data（便宜，但不可搜索）
```

### 9. 删除存储槽以退还Gas

```solidity
// PoolDeployer中的精妙设计
function deploy(...) internal returns (address pool) {
    parameters = Parameters({...});  // SSTORE 20000 gas
    pool = address(new UniswapV3Pool{...}());
    delete parameters;  // 退还 15000 gas
}

// 净成本：20000 - 15000 = 5000 gas
```

### 10. Library代替Contract

```solidity
// ✅ Library：DELEGATECALL或内联
library TickMath {
    function getSqrtRatioAtTick(...) internal pure returns (uint160) {
        // 会被内联到调用合约
    }
}

// ❌ Contract：需要CALL，额外成本
contract TickMathContract {
    function getSqrtRatioAtTick(...) external pure returns (uint160) {
        // 需要跨合约调用，至少700 gas
    }
}
```

### 11. 紧凑的函数参数

```solidity
// ✅ 使用struct（栈空间优化）
struct SwapState {
    int256 amountSpecifiedRemaining;
    int256 amountCalculated;
    uint160 sqrtPriceX96;
    int24 tick;
    uint128 liquidity;
}

// ❌ 太多参数（栈溢出）
function swap(
    int256 amountSpecifiedRemaining,
    int256 amountCalculated,
    uint160 sqrtPriceX96,
    int24 tick,
    uint128 liquidity,
    // ... 更多参数
) {
    // Stack too deep!
}
```

### 12. 批量更新

```solidity
// ✅ 一次性更新多个值
slot0 = Slot0({
    sqrtPriceX96: newPrice,
    tick: newTick,
    observationIndex: newIndex,
    ...
});  // 1次SSTORE

// ❌ 分别更新
slot0.sqrtPriceX96 = newPrice;  // SLOAD + SSTORE
slot0.tick = newTick;            // SLOAD + SSTORE
```

### 13. 函数可见性

```solidity
// ✅ internal/private：可以内联
function _modifyPosition(...) private returns (...) {
    // 可能被编译器内联
}

// ❌ external：总是需要CALL
function modifyPosition(...) external returns (...) {
    // 无法内联，增加调用成本
}
```

### 14. 循环优化

```solidity
// ✅ 缓存数组长度
uint256 length = array.length;  // 一次SLOAD
for (uint256 i = 0; i < length; i++) {
    // ...
}

// ❌ 每次都读取
for (uint256 i = 0; i < array.length; i++) {  // 每次循环都SLOAD
    // ...
}
```

### Gas成本速查表

```
操作                    Gas成本
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SLOAD（冷）            2100
SLOAD（热）             100
SSTORE（0→非0）       20000
SSTORE（非0→非0）      5000
SSTORE（非0→0，退款）  -15000
CALL                   ~700
DELEGATECALL          ~700
ADD/SUB/MUL            3
DIV/MOD                5
SHIFT                  3
AND/OR/XOR             3
JUMP                   8
JUMPI                  10
CREATE                 32000
CREATE2                32000
LOG0                   375
LOG1                   375 + 375 = 750
每字节calldata          16（非零）/4（零）
内存扩展               线性增长
```

### 实战对比

#### 案例：更新tick和价格

```solidity
// ❌ 低效版本
function updatePrice_Bad(uint160 newPrice, int24 newTick) {
    slot0.sqrtPriceX96 = newPrice;  // SLOAD(2100) + SSTORE(5000) = 7100
    slot0.tick = newTick;            // SLOAD(2100) + SSTORE(5000) = 7100
    emit PriceUpdated(newPrice, newTick);  // LOG2 ~1500
}
// 总计：~15700 gas

// ✅ 高效版本
function updatePrice_Good(uint160 newPrice, int24 newTick) {
    Slot0 memory _slot0 = slot0;    // SLOAD(2100)
    _slot0.sqrtPriceX96 = newPrice;  // 内存操作 ~3
    _slot0.tick = newTick;           // 内存操作 ~3
    slot0 = _slot0;                  // SSTORE(5000)
    emit PriceUpdated(newPrice, newTick);  // LOG2 ~1500
}
// 总计：~8606 gas

// 节省：45.2%
```

---

## 总结

Uniswap V3的Gas优化是多层次的：
1. **架构层**：合约职责分离
2. **存储层**：打包、缓存、删除
3. **计算层**：位运算、避免溢出检查
4. **逻辑层**：短路评估、批量操作

这些优化累积起来，使V3在复杂度大幅增加的情况下，Gas效率仍然保持竞争力。

---

*本文是"Uniswap V3源码赏析系列"的第六篇*

