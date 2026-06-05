# 移除 Wave Intrinsics 以支持移动端 Vulkan 设备

## 背景

GPU Radix Sort（基数排序）原始实现使用了 HLSL Wave Intrinsics（Wave 操作指令）来完成排序中的关键并行原语：

| Wave Intrinsic | 用途 | 替代函数 |
|---|---|---|
| `WaveGetLaneCount()` | 获取 Wave（子组）大小 | `TJWaveGetLaneCount()` |
| `WaveActiveBallot()` | 跨 Lane 投票，返回 Bitmask | `TJWaveActiveBallot()` |
| `WavePrefixSum()` | 跨 Lane 排他前缀和 | `TJWavePrefixSum()` |
| `WaveReadLaneAt()` | 读取指定 Lane 的值 | `TJWaveReadLaneAt()` |

这些 Wave Intrinsics 在 PC 端（D3D12 / Vulkan Desktop）上运行稳定，但在移动端 Vulkan 设备上存在严重问题。

## 问题原因

### 1. Adreno 驱动中 SPIR-V Subgroup 操作的实现缺陷

Adreno 690 等 GPU 的 Vulkan 驱动对 SPIR-V Subgroup 操作的支持存在 bug：

- **`WavePrefixSum`** 在非均匀控制流下可能返回错误结果
- **`WaveActiveBallot`** 可能返回不正确的 Bitmask
- **`WaveReadLaneAt`** 跨 Wave 边界时可能读到错误值
- **`WaveGetLaneCount`** 在 SPIR-V 1.6 之前版本上可能返回错误值（原代码已通过 `getWaveSize()` 中的 `WaveActiveBallot(true)` workaround 绕过）

### 2. 排序结果不稳定

由于上述驱动 bug，排序结果在不同帧之间可能不一致，导致：

- Gaussian Splat 渲染闪烁/抖动
- 深度排序错误，透明物体前后关系混乱
- 严重时画面完全错乱

## 解决方案

将所有 Wave Intrinsics 替换为基于 `groupshared` 共享内存的软件模拟实现，并确保所有线程组线程都参与同步屏障。

### 核心设计

#### 编译期 Wave Size

```hlsl
#ifndef WAVE_SIZE
#define WAVE_SIZE 32   // Adreno 690 subgroup size = 32
#endif
```

- 将 Wave Size 从运行时检测改为编译期常量，彻底消除对 `WaveActiveBallot` / `WaveGetLaneCount` 的依赖
- 可通过 `-DWAVE_SIZE=64` 覆盖以适配 64-wide subgroup 的设备
- 必须为 2 的幂次

#### 共享内存暂存区

```hlsl
groupshared uint g_waveMem[D_DIM];  // D_DIM = 256
```

- 为 Wave 操作模拟提供每线程一个 slot 的共享内存
- 三个操作（PrefixSum、ReadLaneAt、ActiveBallot）复用同一块共享内存，因为它们之间总有 `GroupMemoryBarrierWithGroupSync()` 分隔
- 额外共享内存开销：256 × 4 = 1 KB，各 kernel 总共享内存用量均在 Adreno 690（32 KB/CU）限制内

#### 屏障安全约束

`GroupMemoryBarrierWithGroupSync()` 要求线程组内**所有线程**都到达屏障，否则会死锁。因此：

> **所有 Wave 模拟函数必须由线程组内全部线程调用，不能放在条件分支内。**

对于原先在 `if` 条件内调用 Wave Intrinsics 的代码，采用如下重构模式：

```hlsl
// ❌ 原始写法：条件内调用，只有部分线程参与
if (gtid < N)
{
    result = TJWavePrefixSum(gtid, value);
}

// ✅ 重构写法：所有线程调用，非参与线程传 0
uint prefixInput = (gtid < N) ? value : 0;
uint prefixResult = TJWavePrefixSum(gtid, prefixInput);
if (gtid < N)
{
    result = prefixResult;
}
```

**正确性证明**：`WavePrefixSum` 在仅 N 个 Lane 激活时，Lane i (i < N) 的结果为 value[0] + ... + value[i-1]。当所有 Lane 都参与但 N 之后的 Lane 贡献 0 时，Lane i (i < N) 的结果完全相同——0 的贡献不影响前 N 项的前缀和。

### 各函数实现

#### `TJWaveActiveBallot`

```hlsl
// 每线程写入 pred (0/1) → 屏障 → 每线程遍历 Wave 内所有 slot 打包为 uint4 → 屏障
g_waveMem[gtid] = pred ? 1 : 0;
GroupMemoryBarrierWithGroupSync();
// 遍历 base ~ base+WAVE_SIZE-1，将非零项的 bit 置入 result
GroupMemoryBarrierWithGroupSync();
return result;
```

#### `TJWavePrefixSum`

```hlsl
// 每线程写入 val → 屏障 → 每线程累加 base ~ base+laneIndex-1 → 屏障
g_waveMem[gtid] = val;
GroupMemoryBarrierWithGroupSync();
uint sum = 0;
for (uint i = 0; i < laneIndex; i++)
    sum += g_waveMem[base + i];
GroupMemoryBarrierWithGroupSync();
return sum;
```

- 时间复杂度 O(W) per thread，W=32 时最多 31 次加法，开销可接受
- 结果为排他前缀和（Lane 0 得 0），与 `WavePrefixSum` 语义一致

#### `TJWaveReadLaneAt`

```hlsl
// 每线程写入 val → 屏障 → 读取 base+lane 处的值 → 屏障
g_waveMem[gtid] = val;
GroupMemoryBarrierWithGroupSync();
uint result = g_waveMem[base + lane];
GroupMemoryBarrierWithGroupSync();
return result;
```

#### `getWaveSize` / `TJWaveGetLaneCount`

```hlsl
// 直接返回编译期常量，不再需要运行时检测
return WAVE_SIZE;
```

## 改动文件清单

### `package/Shaders/SortCommon.hlsl`

| 改动 | 说明 |
|---|---|
| 新增 `WAVE_SIZE` 宏定义 | 编译期 Wave Size，默认 32 |
| 新增 `g_waveMem[D_DIM]` | 共享内存暂存区 |
| 重写 `TJWaveGetLaneCount()` | 返回 `WAVE_SIZE` |
| 重写 `getWaveSize()` | 返回 `WAVE_SIZE`，移除 `WaveActiveBallot` 运行时检测 |
| 重写 `TJWaveReadLaneAt()` | 基于 `g_waveMem` + 屏障实现 |
| 重写 `TJWavePrefixSum()` | 基于 `g_waveMem` + 屏障实现 |
| 重写 `TJWaveActiveBallot()` | 基于 `g_waveMem` + 屏障实现 |
| 重构 `WaveHistReductionExclusiveScanWGE16()` | 条件内 `TJWavePrefixSum` 调用改为无条件 |

### `package/Shaders/DeviceRadixSort.hlsl`

| 函数 | 改动 |
|---|---|
| `GlobalHistExclusiveScanWGE16()` | 条件内 `TJWavePrefixSum` + `TJWaveReadLaneAt` 改为无条件，非参与线程传 0 |
| `GlobalHistExclusiveScanWLT16()` | 循环内多个条件 `TJWavePrefixSum` + `TJWaveReadLaneAt` 改为无条件 |
| `ExclusiveThreadBlockScanFullWGE16()` | 条件内 `TJWavePrefixSum` + `TJWaveReadLaneAt` 改为无条件 |
| `ExclusiveThreadBlockScanPartialWGE16()` | 条件内 `TJWavePrefixSum` 改为无条件 |
| `ExclusiveThreadBlockScanFullWLT16()` | 多个条件 `TJWavePrefixSum` + `TJWaveReadLaneAt` 改为无条件，增加数组越界保护 |
| `ExclusiveThreadBlockScanParitalWLT16()` | 条件内 `TJWavePrefixSum` + `TJWaveReadLaneAt` 改为无条件，增加数组越界保护 |
| `Downsweep` kernel | 条件内 `TJWavePrefixSum` 改为无条件 |

### `package/Shaders/SplatUtilities.compute`

| 改动 | 说明 |
|---|---|
| 移除 `#pragma require wavebasic` / `#pragma require waveballot` 注释 | Wave Intrinsics 已不再使用 |

## 性能影响

| 方面 | 影响 |
|---|---|
| 共享内存 | 额外 1 KB（`g_waveMem[256]`），各 kernel 总量仍在 32 KB 限制内 |
| 屏障次数 | 每个 Wave 操作增加 2 次 `GroupMemoryBarrierWithGroupSync()`，相比硬件 Wave 操作有所增加 |
| 前缀和计算 | 从硬件 O(1) 变为软件 O(W)，W=32 时为 31 次加法 |
| Ballot 计算 | 从硬件指令变为 W 次共享内存读取 + 位操作 |
| 总体 | 在 Adreno 690 上性能可能略有下降，但排序正确性和稳定性得到保证 |

## 适配其他设备

如果目标设备的 subgroup size 不是 32，需要在编译时指定：

- 64-wide subgroup（部分 Adreno / Intel GPU）：`-DWAVE_SIZE=64`
- 16-wide subgroup（极少数 GPU）：`-DWAVE_SIZE=16`
- 8-wide subgroup（几乎不存在）：`-DWAVE_SIZE=8`

`WAVE_SIZE` 必须为 2 的幂次，且必须等于实际 subgroup size，否则排序结果将不正确。
