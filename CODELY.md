# UnityGaussianSplatting — CODELY.md

## Project Overview

A Unity package implementing **real-time 3D Gaussian Splatting rendering**, based on the SIGGRAPH 2023 paper *"3D Gaussian Splatting for Real-Time Radiance Field Rendering"* by Kerbl et al. It visualizes pre-trained Gaussian Splat models (PLY/SPZ files) inside Unity with GPU-accelerated sorting and rendering. Authored by Aras Pranckevicius.

- **Purpose**: Real-time visualization of 3D Gaussian Splatting models in Unity
- **Unity Version**: 2022.3 (tested up to 2022.3.47f1)
- **Render Pipeline**: Built-in (BiRP), URP (Unity 6+), HDRP — all supported
- **Required Graphics APIs**: D3D12, Metal, or Vulkan (D3D11/OpenGL/GLES will not work)
- **Target Platforms**: PC (Windows D3D12/Vulkan), Mac (Metal), Linux (Vulkan); some VR devices; mobile/web largely unsupported
- **License**: MIT (note: original paper training code has separate non-commercial license from INRIA)

## Repository Structure

```
UnityGaussianSplatting/
├── package/                    # Core Unity package (org.nesnausk.gaussian-splatting)
│   ├── Runtime/                # Runtime scripts & assembly
│   ├── Editor/                 # Editor tools, asset creator, inspectors & assembly
│   │   └── Utils/              # File readers (PLY, SPZ, JSON), k-means, screenshot
│   ├── Shaders/                # HLSL/compute shaders for rendering & sorting
│   └── Materials/              # Black skybox material
├── projects/
│   ├── GaussianExample/        # Built-in render pipeline example project
│   ├── GaussianExample-URP/    # URP example project (requires Unity 6+)
│   └── GaussianExample-HDRP/   # HDRP example project
├── docs/                       # Documentation (render pipeline integration, splat editing)
└── readme.md
```

## Key Scenes & Entry Point

| Project | Scene | Notes |
|---------|-------|-------|
| GaussianExample | `Assets/GSTestScene.unity` | Built-in pipeline demo |
| GaussianExample-URP | `Assets/GSTestScene.unity` | URP demo (Unity 6+ required) |
| GaussianExample-HDRP | `Assets/GSTestScene.unity` | HDRP demo |

Open any of the `projects/` directories as a Unity project. The Gaussian Splat assets are **not included** in the repo — they must be created via the asset creator tool (see below).

## Core Runtime Scripts (`package/Runtime/`)

| Script | Purpose |
|--------|---------|
| `GaussianSplatRenderer.cs` | Main component: attaches to a GameObject, holds a `GaussianSplatAsset` reference, drives the `GaussianSplatRenderSystem` singleton for GPU rendering |
| `GaussianSplatAsset.cs` | `ScriptableObject` storing splat data (positions, colors, SH, scale, rotation) with configurable compression formats (`VectorFormat`, `ColorFormat`, `SHFormat`) |
| `GaussianSplatRenderSystem` | Internal singleton in `GaussianSplatRenderer.cs` managing camera command buffers, sorting, view calc, and draw calls |
| `GaussianCutout.cs` | Component for volumetric splat culling (Ellipsoid/Box shapes, invertible) |
| `GaussianSplatURPFeature.cs` | URP `ScriptableRendererFeature` — gated by `GS_ENABLE_URP`; requires Unity 6+ with Render Graph |
| `GaussianSplatHDRPPass.cs` | HDRP `CustomPass` — gated by `GS_ENABLE_HDRP` |
| `GpuSorting.cs` | GPU radix sort (8-bit LSD, 4-pass) contributed by Thomas Smith |
| `GaussianUtils.cs` | Math utilities: Sigmoid, SH→color, rotation packing, etc. |

## Editor Scripts (`package/Editor/`)

| Script | Purpose |
|--------|---------|
| `GaussianSplatAssetCreator.cs` | `EditorWindow` for importing PLY/SPZ files into compressed GaussianSplat assets (`Tools > Gaussian Splats > Create GaussianSplatAsset`) |
| `GaussianSplatAssetEditor.cs` | Custom inspector for `GaussianSplatAsset` |
| `GaussianSplatRendererEditor.cs` | Custom inspector for `GaussianSplatRenderer` (edit mode, cutouts, export PLY) |
| `GaussianSplatValidator.cs` | Asset validation |
| `GaussianTool*.cs` | Splat editing tools (move, rotate, scale, context) |
| `Utils/PLYFileReader.cs` | PLY file parser |
| `Utils/SPZFileReader.cs` | Scaniverse SPZ format parser |
| `Utils/GaussianFileReader.cs` | Unified file reader dispatcher |
| `Utils/KMeansClustering.cs` | K-means for SH cluster compression |
| `Utils/TinyJsonParser.cs` | Minimal JSON parser (cameras.json) |

## Shaders (`package/Shaders/`)

| File | Purpose |
|------|---------|
| `RenderGaussianSplats.shader` | Main splat rendering (vertex + fragment) |
| `GaussianComposite.shader` | Composites splat RT onto screen |
| `GaussianDebugRenderBoxes.shader` | Debug bounding-box visualization |
| `GaussianDebugRenderPoints.shader` | Debug point-cloud visualization |
| `GaussianSplatting.hlsl` | Shared HLSL include (data formats, constants) |
| `SphericalHarmonics.hlsl` | SH evaluation utilities |
| `DeviceRadixSort.hlsl` | GPU radix sort kernels |
| `SortCommon.hlsl` | Sort shared definitions |
| `SplatUtilities.compute` | Compute shader: view-dependent data calc, cutout application |
| `BlackSkybox.shader` | Simple black background skybox |

## Assembly Definitions

| Assembly | Namespace | Platform | Notes |
|----------|-----------|----------|-------|
| `GaussianSplatting` | `GaussianSplatting.Runtime` | All | `allowUnsafeCode: true`; version defines `GS_ENABLE_URP` / `GS_ENABLE_HDRP` |
| `GaussianSplattingEditor` | `GaussianSplatting.Editor` | Editor only | `allowUnsafeCode: true`; references Runtime assembly |

## Package Dependencies

From `package/package.json` (Unity Package Manager format):

- `com.unity.burst`: 1.8.8
- `com.unity.collections`: 2.1.4
- `com.unity.mathematics`: 1.2.6

The example projects reference this package via local path: `"org.nesnausk.gaussian-splatting": "file:../../../package"`.

## Render Pipeline Integration

| Pipeline | Setup Required | Notes |
|----------|---------------|-------|
| **Built-in (BiRP)** | None — just add `GaussianSplatRenderer` | Primary development target |
| **URP** | Add `GaussianSplatURPFeature` to URP renderer settings | Requires Unity 6+; Render Graph "Compatibility Mode" must be **off** |
| **HDRP** | Add CustomPass volume with `GaussianSplatHDRPPass` | Can render before transparencies or after post-process |

Splats render after opaque objects (tested against Z buffer) but before transparencies (do not write Z). They are unaffected by lights, shadows, or reflection probes. MSAA does not work.

## Asset Creation Workflow

1. Open **Tools → Gaussian Splats → Create GaussianSplatAsset**
2. Point `Input PLY/SPZ File` to a Gaussian Splat file (PLY from official 3DGS, or Scaniverse SPZ)
3. Optionally place `cameras.json` alongside the input file
4. Choose compression quality: VeryHigh / High / Medium / Low / VeryLow / Custom
5. Click **Create Asset** — produces a `GaussianSplatAsset` with companion data files
6. Assign the asset to a `GaussianSplatRenderer` component's `Asset` field

## Splat Editing

- **Manual editing**: Select a `GaussianSplatRenderer`, click **Edit** in inspector or use the scene-view toolbar "blob" icon. Rectangle-select, shift-add, ctrl-remove. `Delete`/`Backspace` to remove. `W` to move. No Undo (disable/re-enable component to revert).
- **Cutouts**: `GaussianCutout` component (Ellipsoid/Box, invertible) to virtually delete splat regions.
- **Export**: Edited splats can be exported back to PLY (optionally baking transform into world space).
- **Merging**: Multiple `GaussianSplatRenderer` objects can be merged via inspector.

## Building & Running

- **Editor**: Open any `projects/GaussianExample*` folder → open `GSTestScene` → press **Play**
- **No custom build scripts** are present in this repo
- **No automated test suite** is included

## Development Conventions

- **Language**: C# with `unsafe` blocks enabled; Burst-compiled jobs where applicable
- **Namespaces**: `GaussianSplatting.Runtime` (runtime), `GaussianSplatting.Editor` (editor)
- **Naming**: PascalCase for classes/methods; `m_` prefix for serialized fields; `s_` for statics
- **Shaders**: HLSL included via `.hlsl` files; compute shaders in `.compute`; Unity shader files in `.shader`
- **Conditional compilation**: `GS_ENABLE_URP` / `GS_ENABLE_HDRP` via assembly definition version defines
- **File headers**: All source files start with `// SPDX-License-Identifier: MIT`
- **Code style**: ReSharper hints present (`// ReSharper disable`); XML doc comments rare

## Version Control

Ignored per `.gitignore`:
- `Library/`, `Temp/`, `Logs/`, `obj/`, `UserSettings/` (per project)
- `Assets/GaussianAssets/` (generated runtime data — large)
- `Assets/Models~/`
- `build/`, `builds/`, `images/`
- IDE files (`.idea`, `.DS_Store`, `.csproj`, `.sln`)

## Known Limitations

- D3D11, OpenGL, OpenGL ES, WebGPU are **not supported**
- Mobile support is partial/unreliable (some iOS/Android devices fail)
- MSAA anti-aliasing does not work with gaussian splats
- URP: HDR off + Intermediate Texture "Auto" causes upside-down rendering
- No Undo for manual splat editing operations
- Project status: **not actively developed** (as of Dec 2023)

## TODO / Open Questions

- No automated tests exist
- No CI/CD or build pipeline configured
- VR support is experimental (some headsets work, AVP does not)
- WebGPU support pending browser/graphics API feature availability
