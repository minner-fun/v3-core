// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library Tick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // info stored for each initialized individual tick 
    struct Info {
        // the total position liquidity that references this tick 总流动性
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left), 净流动性
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick) 手续费增长率
        // only has relative meaning, not absolute — the value depends on when the tick is initialized 只有相对意义，没有绝对意义——值取决于何时初始化
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // the cumulative tick value on the other side of the tick 另一个侧面的累计 tick 值
        int56 tickCumulativeOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick) 另一个侧面的每流动性秒数
        // only has relative meaning, not absolute — the value depends on when the tick is initialized 只有相对意义，没有绝对意义——值取决于何时初始化
        uint160 secondsPerLiquidityOutsideX128;
        // the seconds spent on the other side of the tick (relative to the current tick) 另一个侧面的秒数
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint32 secondsOutside;
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0 如果 tick 已初始化，则值等于 liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks 这些 8 位用于防止在跨越新初始化的 tick 时进行新的存储
        bool initialized;
    }

    /// @notice Derives max liquidity per tick from given tick spacing 从给定的tick间隔推导出每个tick的最大流动性
    /// @dev Executed within the pool constructor 在池构造函数中执行
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing` tick间隔，以`tickSpacing`的倍数实现
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ... 例如，tickSpacing为3需要每隔3个tick初始化，即..., -6, -3, 0, 3, 6, ...
    /// @return The max liquidity per tick 每个tick的最大流动性
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    /// @notice Retrieves fee growth data 获取手续费增长数据
    /// @param self The mapping containing all tick information for initialized ticks 包含所有已初始化tick信息的映射
    /// @param tickLower The lower tick boundary of the position 仓位下边界Tick
    /// @param tickUpper The upper tick boundary of the position 仓位上边界Tick
    /// @param tickCurrent The current tick 当前tick
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0 全局手续费增长，每单位流动性，token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1 全局手续费增长，每单位流动性，token1
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries 该仓位内每单位流动量的手续费增长，token0
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries 该仓位内每单位流动量的手续费增长，token1
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];

        // calculate fee growth below
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        // calculate fee growth above
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa 更新一个tick并返回true，如果tick从初始化到未初始化，或反之
    /// @param self The mapping containing all tick information for initialized ticks 包含所有已初始化tick信息的映射
    /// @param tick The tick that will be updated 要更新的tick
    /// @param tickCurrent The current tick 当前tick
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left) 当tick从左到右（从右到左）跨越时，要添加（减去）的新流动性量
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0 全局手续费增长，每单位流动性，token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1 全局手续费增长，每单位流动性，token1
    /// @param secondsPerLiquidityCumulativeX128 The all-time seconds per max(1, liquidity) of the pool 池中每单位最大(1,流动性)的秒数
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized 池第一次初始化以来，tick * 时间流逝
    /// @param time The current block timestamp cast to a uint32 当前区块时间戳转换为uint32
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick 为true时更新仓位上边界tick，为false时更新仓位下边界tick
    /// @param maxLiquidity The maximum liquidity allocation for a single tick 单个tick的最大流动性分配
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa 是否从初始化到未初始化，或反之
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        require(liquidityGrossAfter <= maxLiquidity, 'LO');

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
                info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128;
                info.tickCumulativeOutside = tickCumulative;
                info.secondsOutside = time;
            }
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    /// @notice Clears tick data 清除tick数据
    /// @param self The mapping containing all initialized tick information for initialized ticks 包含所有已初始化tick信息的映射
    /// @param tick The tick that will be cleared 要清除的tick
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement 根据价格移动过渡到下一个tick
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The destination tick of the transition 过渡到的目标tick
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0 全局手续费增长，每单位流动性，token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1 全局手续费增长，每单位流动性，token1
    /// @param secondsPerLiquidityCumulativeX128 The current seconds per liquidity 当前每单位流动量的秒数
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized 池第一次初始化以来，tick * 时间流逝
    /// @param time The current block.timestamp 当前区块时间戳
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left) 当tick从左到右（从右到左）跨越时，要添加（减去）的流动性量
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128 - info.secondsPerLiquidityOutsideX128;
        info.tickCumulativeOutside = tickCumulative - info.tickCumulativeOutside;
        info.secondsOutside = time - info.secondsOutside;
        liquidityNet = info.liquidityNet;
    }
}
