# Gaussian Splatting 渲染流程详解

> 基于 UnityGaussianSplatting 项目源码分析，覆盖 BiRP / URP / HDRP 三条管线

---

## 完整渲染流程（以 URP Unity 6+ 为例）

整个流程分为 **5 个阶段**，从帧触发到最终像素输出：

---

### 阶段 0：帧入口 — 哪里触发渲染

| 渲染管线 | 触发方式 |
|----------|---------|
| **BiRP** | `Camera.onPreCull` 回调 → `GaussianSplatRenderSystem.OnPreCullCamera` |
| **URP (Unity 6+)** | `ScriptableRendererFeature.OnCameraPreCull` → `GatherSplatsForCamera`，然后在 `RenderGraph` 的 `UnsafePass` 里执行 |
| **HDRP** | `CustomPass` 在指定 injection point 执行 |

核心逻辑都在 `GaussianSplatRenderSystem.SortAndRenderSplats`，各管线只是**接入点不同**，排序+绘制+合成的 GPU 工作完全一样。

---

### 阶段 1：收集 & 排序 Splat 对象

```
GatherSplatsForCamera → SortAndRenderSplats (对每个 GaussianSplatRenderer 循环)
```

1. **收集**：遍历所有已注册的 `GaussianSplatRenderer`，筛掉无效/禁用的
2. **排序多个 Splat 对象**：按 `m_RenderOrder` 和到相机的 z 深度排序，决定绘制先后
3. **对每个对象**执行下面的阶段 2~4

---

### 阶段 2：排序 — `SortPoints`（ComputeShader）

对应 `SplatUtilities.compute`，**3 个 kernel 顺序执行**：

#### 2a. `CSSetIndices`（仅初始化时执行一次）

```hlsl
_SplatSortKeys[idx] = idx;   // key buffer = [0, 1, 2, ..., N-1]
```

#### 2b. `CSCalcDistances` — 计算排序键（每帧）

```hlsl
uint origIdx = _SplatSortKeys[idx];
float3 pos = LoadSplatPos(origIdx);           // 从 GPU Buffer 读原始位置
pos = mul(_MatrixMV, float4(pos, 1)).xyz;     // Object → View Space
_SplatSortDistances[idx] = FloatToSortableUint(pos.z);  // 深度 → 可排序 uint
```

- `_MatrixMV` = `worldToCameraMatrix × localToWorldMatrix`
- `FloatToSortableUint` 把 IEEE 754 float 映射为单调递增 uint（符号位翻转技巧），使 radix sort 能正确处理负数

#### 2c. `GpuSorting.Dispatch` — GPU 8-bit LSD Radix Sort

4 轮循环（radixShift = 0/8/16/24），每轮：

| Kernel | 作用 |
|--------|------|
| `InitDeviceRadixSort` | 清零 `b_globalHist`（全局 256-bin 直方图） |
| `Upsweep` | 每个 partition(3840 keys) 统计本地直方图 → reduce → exclusive scan → 原子加到全局直方图 |
| `Scan` | 对 `b_passHist` 做 exclusive prefix scan，算出每个 partition 每个 digit 的全局偏移 |
| `Downsweep` | 根据 scan 结果把 key-value pair scatter 到正确位置，写入 alt buffer，然后 swap src/dst |

排序后 `_SplatSortKeys` 存的就是**按深度从远到近排列的 splat 索引**。

> **性能优化**：`m_SortNthFrame` 可控制每 N 帧才排一次（默认 1），减少 GPU 开销。

---

### 阶段 3：计算视图相关数据 — `CalcViewData`（ComputeShader）

对应 `CSCalcDistances` 之后的 `CSCalcViewData` kernel，**每帧执行**：

```hlsl
void CSCalcViewData(uint3 id : SV_DispatchThreadID)
{
    SplatData splat = LoadSplatData(idx);  // 从 GPU Buffer 解码 pos/rot/scale/SH/color
    
    // 1) 位置变换
    centerWorldPos = mul(_MatrixObjectToWorld, float4(splat.pos, 1));
    centerClipPos  = mul(UNITY_MATRIX_VP, float4(centerWorldPos, 1));
    
    // 2) 判断是否被删除/cutout
    if (deleted || IsSplatCut(splat.pos))
        centerClipPos.w = 0;  // 标记为不可见

    // 3) 计算 3D 协方差矩阵（旋转+缩放 → 协方差）
    splatRotScaleMat = CalcMatrixFromRotationScale(boxRot, boxSize);
    CalcCovariance3D(splatRotScaleMat, cov3d0, cov3d1);
    
    // 4) 投影到 2D 协方差（EWA Splatting, Zwicker 2002）
    cov2d = CalcCovariance2D(splat.pos, cov3d0, cov3d1, _MatrixMV, UNITY_MATRIX_P, screenParams);
    
    // 5) 分解 2D 协方差为椭圆的两个轴
    DecomposeCovariance(cov2d, view.axis1, view.axis2);  // 特征值分解
    
    // 6) 计算视点相关颜色（Spherical Harmonics 求值）
    objViewDir = normalize(mul(_MatrixWorldToObject, cameraPos - centerWorldPos));
    col.rgb = ShadeSH(splat.sh, objViewDir, _SHOrder, _SHOnly);
    col.a = splat.opacity * opacityScale;
    
    // 7) 打包颜色为 4×FP16
    view.color = pack_f16(col);
    
    _SplatViewData[idx] = view;
}
```

输出 `SplatViewData` 结构（40 bytes/splat）：

| 字段 | 含义 |
|------|------|
| `pos : float4` | Clip space 中心坐标 |
| `axis1 : float2` | 2D 椭圆第一轴方向+长度 |
| `axis2 : float2` | 2D 椭圆第二轴方向+长度 |
| `color : uint2` | RGBA × FP16 打包的颜色+透明度 |

#### 协方差投影详解

3D 高斯的协方差矩阵 Σ 由旋转 R 和缩放 S 决定：

```
Σ = R · S · Sᵀ · Rᵀ
```

投影到 2D 使用 EWA Splatting（Zwicker et al. 2002）的方法：

```
Σ' = J · W · Σ · Wᵀ · Jᵀ
```

其中 J 是投影的雅可比矩阵，W 是 view matrix 的 3×3 部分。得到 2D 协方差后，通过特征值分解提取椭圆的两个轴（方向+长度），用于 vertex shader 中偏移四边形顶点。

---

### 阶段 4：绘制 Splat — `DrawProcedural`（Vertex + Fragment Shader）

使用 `RenderGaussianSplats.shader`，**Procedural Draw**：

```csharp
cmd.DrawProcedural(indexBuffer, matrix, displayMat, 0, MeshTopology.Triangles, 
                    indexCount: 6, instanceCount: splatCount, mpb);
```

每个 splat 实例画一个**四边形**（2 个三角形，6 个索引）。

#### Vertex Shader

```hlsl
v2f vert(uint vtxID : SV_VertexID, uint instID : SV_InstanceID)
{
    instID = _OrderBuffer[instID];       // 读取排序后的索引
    SplatViewData view = _SplatViewData[instID];
    
    // 相机后面的 splat → 输出 NaN 丢弃
    if (view.pos.w <= 0)
        o.vertex = NaN;
    
    // 解码 FP16 颜色
    o.col = unpack_f16(view.color);
    
    // 生成四边形顶点：[-1,-1] → [1,1]，放大2倍
    float2 quadPos = float2(vtxID&1, (vtxID>>1)&1) * 2.0 - 1.0;
    quadPos *= 2;
    
    // 用椭圆轴偏移中心位置
    float2 deltaScreen = (quadPos.x * view.axis1 + quadPos.y * view.axis2) * 2 / _ScreenParams.xy;
    o.vertex.xy = view.pos.xy + deltaScreen * view.pos.w;
}
```

**核心**：每个 splat 被绘制为以其 clip-space 中心为原点的四边形，四个角偏移量由 `axis1`/`axis2`（2D 协方差的特征向量）决定。

#### Fragment Shader

```hlsl
half4 frag(v2f i) : SV_Target
{
    // 2D 高斯函数：exp(-||Δpos||²)
    float power = -dot(i.pos, i.pos);
    half alpha = exp(power);
    alpha = saturate(alpha * i.col.a);  // 乘以 splat 透明度
    
    if (alpha < 1/255.0) discard;
    
    // 预乘 alpha 输出
    return half4(i.col.rgb * alpha, alpha);
}
```

**关键混合模式**：
```hlsl
Blend OneMinusDstAlpha One   // 即：result = src.rgb * (1 - dst.a) + dst.rgb * 1
```

这是 **alpha-weighted blending**（加权平均混合），不是传统的 alpha blend。它让所有 splat 按"从远到近"的顺序叠加，每个 splat 的颜色乘以自身 alpha，同时乘以 `(1 - dst.a)` 使远处 splat 的贡献随近处 splat 累积而衰减。最终结果是所有高斯贡献的加权平均，避免传统 alpha blending 的顺序依赖问题。

---

### 阶段 5：合成到屏幕 — `GaussianComposite.shader`

Splat 绘制到一个 **离屏 RT**（`_GaussianSplatRT`，R16G16B16A16_SFloat），最后用全屏三角形合成到相机 color target：

```hlsl
// GaussianComposite.shader
half4 frag(v2f i) : SV_Target
{
    half4 col = _GaussianSplatRT.Load(int3(i.vertex.xy, 0));
    return float4(GammaToLinearSpace(col.rgb / col.a), col.a);
    //                          ^^^^^^^^^^^^^^^^^^^^      ^^^^^^
    //                          预乘alpha → 直通alpha     保留alpha用于混合
}
```

```hlsl
Blend SrcAlpha OneMinusSrcAlpha   // 传统 alpha blend 合到屏幕
```

**`col.rgb / col.a`**：把阶段 4 的预乘 alpha 颜色还原为正常颜色（除以累积的 alpha），再做 `GammaToLinearSpace` 转换（假设 splat 数据在 gamma 空间），最后用标准 alpha 混合贴到屏幕上。

---

## 完整数据流图

```
┌─────────────────────────────────────────────────────────────────────┐
│  GPU Buffers (uploaded at asset creation)                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐  │
│  │ _SplatPos│ │_SplatOther│ │ _SplatSH │ │_SplatColor│ │_SplatChk│  │
│  │ pos(N×12)│ │rot+scl   │ │ SH coeff │ │ 2D tex   │ │ chunk   │  │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬────┘  │
└───────┼─────────────┼────────────┼────────────┼────────────┼────────┘
        │             │            │            │            │
        ▼             ▼            ▼            ▼            ▼
┌──────────────────────────────────────────────────────────────────┐
│  SplatUtilities.compute  (每帧)                                  │
│                                                                  │
│  ┌────────────────┐    ┌──────────────────┐    ┌───────────────┐  │
│  │ CalcDistances  │───▶│  Radix Sort     │───▶│ CalcViewData │  │
│  │ pos → view z   │    │  4-pass LSD     │    │ cov3D → cov2D│  │
│  │ → sortable uint│    │  sort by depth  │    │ SH → color   │  │
│  └────────────────┘    └───────┬──────────┘    └───────┬───────┘  │
│                                │                       │          │
└────────────────────────────────┼───────────────────────┼──────────┘
                                 │                       │
                                 ▼                       ▼
                    ┌──────────────────────────────────────────┐
                    │        _SplatSortKeys  _SplatViewData   │
                    │        (sorted indices) (view data)     │
                    └───────────┬──────────────────┬─────────┘
                                │                  │
                                ▼                  ▼
┌──────────────────────────────────────────────────────────────────┐
│  RenderGaussianSplats.shader (DrawProcedural)                    │
│                                                                  │
│  Vertex: index → sorted splat → 2D quad (axis1/axis2 offset)   │
│  Fragment: Gaussian exp(-r²) × alpha → premultiplied color      │
│  Blend: OneMinusDstAlpha One (alpha-weighted accumulate)         │
│                                                                  │
│  输出到 _GaussianSplatRT (R16G16B16A16_SFloat, 离屏RT)            │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│  GaussianComposite.shader (全屏三角形)                            │
│                                                                  │
│  col.rgb / col.a → 还原预乘 alpha                                │
│  GammaToLinearSpace → 线性空间                                    │
│  Blend SrcAlpha OneMinusSrcAlpha → 合成到屏幕                     │
└──────────────────────────────────────────────────────────────────┘
```

---

## 为什么需要离屏 RT + 合成两步？

1. **深度测试**：Splat 渲染时需要读取现有深度缓冲（不透明物体已经画好），但 splat 自身不写深度。通过 `SetRenderTarget(splatRT, existingDepth)` 实现
2. **独立 alpha 通道**：alpha-weighted blending 需要一个干净的 alpha 通道来累积权重，不能和屏幕上已有的颜色混合
3. **最终除以 alpha**：`col.rgb / col.a` 这一步必须在所有 splat 累积完之后才能做，所以必须有一个中间 RT

---

## URP vs BiRP 的差异总结

| | BiRP | URP (Unity 6+) |
|---|---|---|
| **触发** | `Camera.onPreCull` | `ScriptableRendererFeature.OnCameraPreCull` |
| **RT 获取** | `CommandBuffer.GetTemporaryRT` | `RenderGraph.CreateRenderGraphTexture` |
| **合成** | `DrawProcedural` 全屏三角 | `Blitter.BlitCameraTexture` |
| **Pass 时机** | `CameraEvent.BeforeForwardAlpha` | `RenderPassEvent.BeforeRenderingTransparents` |
| **排序/CS/绘制** | 完全相同 | 完全相同 |

核心 GPU 计算（排序、视图数据、splat 绘制 shader）三条管线**零差异**。

---

## 关键源文件索引

| 文件 | 职责 |
|------|------|
| `package/Runtime/GaussianSplatRenderer.cs` | 主组件 + `GaussianSplatRenderSystem` 单例，驱动整个渲染流程 |
| `package/Runtime/GpuSorting.cs` | GPU 基数排序调度器 |
| `package/Shaders/SplatUtilities.compute` | 所有 Compute Shader kernel（排序距离计算、视图数据计算、编辑操作） |
| `package/Shaders/DeviceRadixSort.hlsl` | GPU radix sort 实现（Thomas Smith） |
| `package/Shaders/RenderGaussianSplats.shader` | Splat 绘制：vertex 生成四边形 + fragment 高斯衰减 |
| `package/Shaders/GaussianComposite.shader` | 离屏 RT → 屏幕合成（预乘 alpha 还原 + gamma 转换） |
| `package/Shaders/GaussianSplatting.hlsl` | 共享 HLSL：数据格式定义、协方差投影、SH 求值、数据解码 |
| `package/Runtime/GaussianSplatURPFeature.cs` | URP 接入层（RenderGraph / ScriptableRenderPass） |
| `package/Runtime/GaussianSplatHDRPPass.cs` | HDRP 接入层（CustomPass） |
