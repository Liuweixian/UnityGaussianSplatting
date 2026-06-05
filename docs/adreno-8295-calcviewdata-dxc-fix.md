# Adreno 8295 上 `CSCalcViewData` 输出错误与 DXC 拆分修复

## 背景

在 Unity 高斯点云（Gaussian Splatting）渲染管线中，`CSCalcViewData` compute kernel 负责为每个 splat 计算视空间数据（位置、屏幕椭圆参数、颜色等），写入 `_SplatViewData` buffer，供后续排序与绘制使用。

在 **SA8295（Adreno）** 车载平台上截帧对比时发现：

- **Pixel 手机（Adreno，正常）**：`_SplatViewData` 与预期一致，画面正确。
- **8295 平台（异常）**：`_SplatViewData` 大量条目错位，高斯渲染结果严重错误。

两台设备使用相同的场景、相同的 splat 资产，且 dispatch 参数一致（`vkCmdDispatch(137, 1, 1)`，workgroup 1024，splat 数 139410）。

## 现象与数据分析

对比 `calcview/8295/` 与 `calcview/pixel-phone/` 目录下的截帧 CSV：

| 对比项 | 结论 |
|--------|------|
| 输入 buffer（`_SplatPos`、`_SplatOther`、`_SplatChunks` 等） | 基本一致 |
| SPIR-V 反汇编（`calcview.txt`） | 相同，均由 DXC / spiregg 生成 |
| 同 index `_SplatViewData.pos` 匹配率 | 仅约 **11%**（15416 / 139410） |
| 错位模式 | 非固定 index 偏移；8295[2] 的 pos 更接近 pixel[103]，而非 pixel[2] |

对前 5000 条数据的脚本分析进一步表明：同 index 最佳匹配仅约 4.4%，说明是**大量条目被写乱**，而不是简单的平移或固定 stride 错位。

典型错误表现：8295 上 matrix multiply 与 buffer load 生成的 SPIR-V 在驱动执行时行为异常，导致 `_SplatViewData[idx]` 写入的内容与输入 splat index 不对应。

## 根因

**DXC 编译路径下 `CSCalcViewData` 生成的 SPIR-V，在 SA8295 Adreno GPU 上执行结果不正确。**

更具体地说：

1. 原工程所有 compute kernel（含 `CSCalcViewData` 与 DeviceRadixSort）均放在 `SplatUtilities.compute`，并统一使用 `#pragma use_dxc`。
2. C# 侧传参、输入 buffer、dispatch 规模均正确，问题不在 CPU 端。
3. Pixel 与 8295 拿到相同 SPIR-V，但 8295 驱动/GPU 对 DXC 生成的特定指令序列（矩阵运算、structured buffer 访问）存在兼容性问题。
4. 因此 `_SplatViewData` 在 8295 上被大量错误写入，后续排序与 splat shader 即使正常，画面仍会错乱。

## 为何不能简单地全局去掉 DXC

最初尝试在 `SplatUtilities.compute` 中移除 `#pragma use_dxc`，让 `CSCalcViewData` 走传统 HLSL 编译器，但会引发其他 kernel 编译失败：

1. **非 DXC 路径缺少 `PackHalf2x16`**：若改用 `f32tof16` 可解决颜色打包，但……
2. **DeviceRadixSort 的 `Scan` kernel 报错**：
   ```
   this variable dependent on potentially varying data: gtid at kernel Scan
   ```
   Radix Sort（`DeviceRadixSort.hlsl`）依赖 wave intrinsic 与 DXC 特性，**必须用 DXC 编译**。

结论：**Radix Sort 保留 DXC，`CSCalcViewData` 单独用非 DXC 编译**，二者拆分。

## 修复方案

将 `CSCalcViewData` 从 `SplatUtilities.compute` 拆到独立 compute shader，仅对该 kernel 禁用 DXC。

```
┌─────────────────────────────┐     ┌──────────────────────────────┐
│  SplatUtilities.compute     │     │  SplatCalcViewData.compute   │
│  #pragma use_dxc            │     │  （无 use_dxc）               │
│  ─────────────────────────  │     │  ──────────────────────────  │
│  Radix Sort (Init/Upsweep/  │     │  CSCalcViewData              │
│    Scan/Downsweep)          │     │  协方差分解、SH 着色、写入     │
│  编辑/选择/导出等 kernel     │     │  _SplatViewData              │
└─────────────────────────────┘     └──────────────────────────────┘
         DXC 编译                              传统编译器
      （排序必须保留）                    （修复 8295 兼容性）
```

## 改动清单

### 1. 新建 `package/Shaders/SplatCalcViewData.compute`

- 仅包含 `#pragma kernel CSCalcViewData` 及其依赖（`DecomposeCovariance`、cutout 检测、SH 着色等）。
- **不使用** `#pragma use_dxc`。
- 移动端 `GROUP_SIZE` 为 256（`SHADER_API_GLES3` / `SHADER_API_GLES` / `SHADER_API_MOBILE`），其他平台 1024。
- 颜色打包继续使用 `f32tof16`（非 DXC 路径兼容）。

### 2. 修改 `package/Shaders/SplatUtilities.compute`

- **恢复** `#pragma use_dxc`。
- **移除** `#pragma kernel CSCalcViewData` 及 `CSCalcViewData` 函数体。
- 移除仅 CalcView 使用的变量与 `DecomposeCovariance`（已迁至新文件）。
- 保留 Radix Sort、编辑、选择、导出等所有其他 kernel。

### 3. 修改 `package/Runtime/GaussianSplatRenderer.cs`

- 新增字段：`public ComputeShader m_CSSplatCalcView`。
- `resourcesAreSetUp` 增加对 `m_CSSplatCalcView != null` 的检查。
- `SetAssetDataOnCS` 重构为接受 `(ComputeShader cs, int kernelIndex)` 的重载。
- `CalcViewData()` 改为 dispatch **`m_CSSplatCalcView`** kernel 0，不再使用 `m_CSSplatUtilities`。
- `KernelIndices.CalcViewData` 枚举项保留（避免破坏 enum 索引），但不再用于 CalcView dispatch。

### 4. 修改 `package/Editor/GaussianSplatRendererEditor.cs`

- Inspector 中增加 `m_CSSplatCalcView` 字段展示，与 `m_CSSplatUtilities` 并列。

### 5. 默认引用与场景

以下文件的默认引用已补上 `m_CSSplatCalcView` → `SplatCalcViewData.compute`（guid: `a7c3e1f42b8d4a6e9f0c2d5b8e7a4f31`）：

- `package/Runtime/GaussianSplatRenderer.cs.meta`
- `package/Runtime/GaussianSplatURPFeature.cs.meta`
- `projects/GaussianExample-URP/Assets/GSTestScene.unity`
- `projects/GaussianExample/Assets/GSTestScene.unity`
- `projects/GaussianExample-HDRP/Assets/GSTestScene.unity`

## 如何验证

1. **Shader 编译**：确认 `SplatUtilities.compute`（含 Scan kernel）与 `SplatCalcViewData.compute` 均能无报错编译。
2. **Inspector 引用**：`GaussianSplatRenderer` 组件上 **Calc View Compute** 应指向 `SplatCalcViewData`。
3. **8295 截帧对比**：
   - 抓取 `_SplatViewData` CSV，与 Pixel 或 Editor 参考结果对比。
   - 同 index `pos` 匹配率应接近 **100%**（此前约 11%）。
4. **功能回归**：排序、编辑、导出等仍走 `SplatUtilities`，行为应与改前一致。

## 相关数据目录

| 路径 | 说明 |
|------|------|
| `calcview/8295/` | 8295 平台截帧（异常） |
| `calcview/pixel-phone/` | Pixel 手机截帧（正常参考） |
| `capture/8295-splatshader-wrong/` | 8295 渲染错误时的 shader/buffer 捕获 |
| `capture/phone-splatshader-correct/` | Pixel 正确渲染时的捕获 |

## 备注

- 本问题与 [HMIAndroid 下 b_globalHist 异常](hmiandroid-splat-sort-globalhist-bug.md) 不同：后者是 Metal 上 wave intrinsic lane index 映射错误；本文是 Vulkan/Adreno 上 DXC 生成 SPIR-V 的执行兼容性问题。
- 若未来 Unity / Adreno 驱动修复 DXC SPIR-V 兼容性，可考虑合并回单一 compute shader；当前拆分是最小侵入、风险最低的 workaround。
