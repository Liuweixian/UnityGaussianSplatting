// SPDX-License-Identifier: MIT
#ifndef SPLAT_COMPUTE_COMMON_HLSL
#define SPLAT_COMPUTE_COMMON_HLSL

float4x4 _MatrixObjectToWorld;
float4x4 _MatrixWorldToObject;
float4x4 _MatrixMV;
float4 _VecScreenParams;
float4 _VecWorldSpaceCameraPos;

uint _SplatCount;
uint _SplatCutoutsCount;
uint _SplatBitsValid;

#define SPLAT_CUTOUT_TYPE_ELLIPSOID 0
#define SPLAT_CUTOUT_TYPE_BOX 1

struct GaussianCutoutShaderData // match GaussianCutout.ShaderData in C#
{
    float4x4 mat;
    uint typeAndFlags;
};
StructuredBuffer<GaussianCutoutShaderData> _SplatCutouts;

ByteAddressBuffer _SplatDeletedBits;

bool IsSplatCut(float3 pos)
{
    bool finalCut = false;
    for (uint i = 0; i < _SplatCutoutsCount; ++i)
    {
        GaussianCutoutShaderData cutData = _SplatCutouts[i];
        uint type = cutData.typeAndFlags & 0xFF;
        if (type == 0xFF) // invalid/null cutout, ignore
            continue;
        bool invert = (cutData.typeAndFlags & 0xFF00) != 0;

        float3 cutoutPos = mul(cutData.mat, float4(pos, 1)).xyz;
        if (type == SPLAT_CUTOUT_TYPE_ELLIPSOID)
        {
            if (dot(cutoutPos, cutoutPos) <= 1) return invert;
        }
        if (type == SPLAT_CUTOUT_TYPE_BOX)
        {
            if (all(abs(cutoutPos) <= 1)) return invert;
        }
        finalCut = finalCut || !invert;
    }
    return finalCut;
}

#endif // SPLAT_COMPUTE_COMMON_HLSL
