# HMIAndroid 下 `b_globalHist` 异常导致高斯排序错误的总结

## 背景

在 Unity 该工程中进行 splat（高斯点云）GPU 排序时，发现：

- **Mac Standalone（正常）**
- **Editor + HMIAndroid（不正常）**

通过 Xcode 抓帧分析，发现排序中用于 Radix Sort 的 `_SplatSortKeys`/绘制顺序会被破坏；进一步对比排序内部的直方图阶段，定位到 **`DeviceRadixSort` 的 `b_globalHist`** 与正确结果不一致。

## 现象与范围

1. 注释掉 `Downsweep` 后，仍能在抓帧中看到 `b_globalHist` 与正确结果不同。
2. 对比 CSV 数据后确认：
   - `b_sort`（keys 输入）在两个 Build Target 下**完全一致**。
   - `b_passHist`（Upsweep 中分区统计直方图）在两个 Build Target 下**完全一致**。
   - 仅 `DeviceRadixGlobalHistogram`（即 `b_globalHist`）在 **HMIAndroid** 下与正确答案不同。

抓帧 CSV 的关键形态：

- HMIAndroid 的 `b_globalHist` 非零值只出现在非常稀疏的索引集合中（例如集中在 `1..4, 33..36, 65..68...` 这样的规律位置）。
- Standalone 下 `b_globalHist` 恰好等于由 `b_passHist` 求和后推导的 exclusive prefix sum（数学自洽）。

## 关键证据（为什么不是 shader 代码差异）

你在 Xcode 中对比了两个目标平台下的 `upsweep` kernel 代码：

- 两份 kernel 的主体算法逻辑看起来一致。
- 但 **kernel 参数/attribute 对 `gl_SubgroupInvocationID` 的映射不同**：
  - Mac Standalone 的 kernel 使用：`[[thread_index_in_simdgroup]]`
  - HMIAndroid 的 kernel 使用：`[[thread_index_in_quadgroup]]`

在 HLSL 里使用 wave intrinsic（例如 `WaveGetLaneIndex()` / `WavePrefixSum()` / `WaveReadLaneAt()`）时，
这意味着 **lane index 的语义坐标系发生了变化**：

- `WaveGetLaneCount()` 来自 `[[thread_execution_width]]`（simdgroup 尺寸）
- `WaveGetLaneIndex()` 在 HMIAndroid 下却被翻译为 quadgroup 内的 lane index（通常只有 0..3）

最终造成：

> `GlobalHistExclusiveScan*` 阶段依赖 lane index 进行 scatter/offset 计算的逻辑错位，
> 所以 `b_globalHist` 写入的位置错误，进而 Radix Sort 的全局排序结构被破坏。

## 根因

**HMIAndroid（Metal 后端）下 wave intrinsic 的 lane index 实现不匹配。**

更具体地说：

1. `WaveGetLaneCount()` 的“波大小”来自 simdgroup（thread_execution_width）。
2. `WaveGetLaneIndex()` 的 lane index 却被翻译为 quadgroup（thread_index_in_quadgroup）。
3. 在 `DeviceRadixSort` 的 `GlobalHistExclusiveScanWGE16/GlobalHistExclusiveScanWLT16` 中，
   通过 lane index 参与计算 `b_globalHist` 写入下标，因此出现系统性写错（只在某些固定位置非零）。

这也解释了为什么：

- `b_sort` 一致：keys 输入本身没变。
- `b_passHist` 一致：分区直方图在 GlobalHist scan 之前计算/写入，未触发 lane scatter 错位。
- `b_globalHist` 不一致：只有它在 GlobalHistExclusiveScan 使用了依赖 lane index 的 scatter 写入。

## 影响

错误的 `b_globalHist` 会导致：

- 下一步 `Scan/Downsweep` 使用的全局直方图前缀偏移错误
- 最终 `b_sortKeys / _OrderBuffer`（排序后的 instID）错误
- 绘制顺序紊乱，从而在画面上表现为排序失效或闪烁/稀疏化

## 修复建议（方向）

最直接的修复思路是：**避免依赖 `WaveGetLaneIndex()` 作为 scatter 的 lane index 来源**，
改为用确定性的线程维度推导 lane index。

例如：

- 用 `SV_GroupThreadID`（或等价的 dispatch 内部线程号）与 waveSize 推导 lane：
  - `lane = groupThreadId % waveSize`
- 然后替换 `GlobalHistExclusiveScan*` 内所有使用 `WaveGetLaneIndex()` 的位置，
  使得 `lane index` 与 `waveSize` 在同一个坐标系下。

需要改动的文件/区域通常在：

- `package/Shaders/DeviceRadixSort.hlsl`
- `package/Shaders/SortCommon.hlsl`
  - 与 `GlobalHistExclusiveScanWGE16 / WLT16` 相关的 `WaveGetLaneIndex()`/`WaveReadLaneAt()` 相关计算块

## 如何验证修复是否有效

1. 保持抓帧点在：Upsweep 之后、Scan 之前。
2. 对比两份 capture 的 CSV：
   - `b_sort`：必须一致
   - `b_passHist`：必须一致
   - `b_globalHist`：在 HMIAndroid 下应当与 Standalone（由 passHist 推导）一致
3. 最终确认排序后 `_OrderBuffer` 与 expected 排序一致，画面闪烁消失。

