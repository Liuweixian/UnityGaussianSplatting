/******************************************************************************
 * SortCommon
 * Common functions for GPUSorting 
 *
 * SPDX-License-Identifier: MIT
 * Copyright Thomas Smith 5/17/2024
 * https://github.com/b0nes164/GPUSorting
 *  
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 ******************************************************************************/
#define KEYS_PER_THREAD     15U 
#define D_DIM               256U
#define PART_SIZE           3840U
#define D_TOTAL_SMEM        4096U

#define RADIX               256U    //Number of digit bins
#define RADIX_MASK          255U    //Mask of digit bins
#define HALF_RADIX          128U    //For smaller waves where bit packing is necessary
#define HALF_MASK           127U    // '' 
#define RADIX_LOG           8U      //log2(RADIX)
#define RADIX_PASSES        4U      //(Key width) / RADIX_LOG

cbuffer cbGpuSorting : register(b0)
{
    uint e_numKeys;
    uint e_radixShift;
    uint e_threadBlocks;
    uint padding;
};

#if defined(KEY_UINT)
RWStructuredBuffer<uint> b_sort;
RWStructuredBuffer<uint> b_alt;
#elif defined(KEY_INT)
RWStructuredBuffer<int> b_sort;
RWStructuredBuffer<int> b_alt;
#elif defined(KEY_FLOAT)
RWStructuredBuffer<float> b_sort;
RWStructuredBuffer<float> b_alt;
#endif

#if defined(PAYLOAD_UINT)
RWStructuredBuffer<uint> b_sortPayload;
RWStructuredBuffer<uint> b_altPayload;
#elif defined(PAYLOAD_INT)
RWStructuredBuffer<int> b_sortPayload;
RWStructuredBuffer<int> b_altPayload;
#elif defined(PAYLOAD_FLOAT)
RWStructuredBuffer<float> b_sortPayload;
RWStructuredBuffer<float> b_altPayload;
#endif

groupshared uint g_d[D_TOTAL_SMEM]; //Shared memory for DigitBinningPass and DownSweep kernels
groupshared uint g_waveMem[D_DIM];  //Shared memory for wave operation emulation

struct KeyStruct
{
    uint k[KEYS_PER_THREAD];
};

struct OffsetStruct
{
#if defined(ENABLE_16_BIT)
    uint16_t o[KEYS_PER_THREAD];
#else
    uint o[KEYS_PER_THREAD];
#endif
};

struct DigitStruct
{
#if defined(ENABLE_16_BIT)
    uint16_t d[KEYS_PER_THREAD];
#else
    uint d[KEYS_PER_THREAD];
#endif
};

//*****************************************************************************
//HELPER FUNCTIONS
//*****************************************************************************

// Wave size for subgroup emulation via shared memory.
// Override with -DWAVE_SIZE=64 for devices with 64-wide subgroups.
// Adreno 690 on Vulkan: subgroup size is 32.
#ifndef WAVE_SIZE
#define WAVE_SIZE 32
#endif

inline uint TJWaveGetLaneCount()
{
    return WAVE_SIZE;
}

// Wave size is now a compile-time constant, no runtime detection needed.
inline uint getWaveSize()
{
    return WAVE_SIZE;
}

inline uint getWaveIndex(uint gtid, uint waveSize)
{
    return gtid / waveSize;
}

// Shared memory based WaveReadLaneAt: broadcasts val from the given lane
// to all lanes within the wave. Must be called by ALL threads in the group.
inline uint TJWaveReadLaneAt(uint gtid, uint val, uint lane)
{
    g_waveMem[gtid] = val;
    GroupMemoryBarrierWithGroupSync();
    const uint base = gtid - (gtid & (WAVE_SIZE - 1));
    uint result = g_waveMem[base + lane];
    GroupMemoryBarrierWithGroupSync();
    return result;
}

// Shared memory based exclusive WavePrefixSum.
// Must be called by ALL threads in the group.
// Non-participating threads should pass 0 as val.
inline uint TJWavePrefixSum(uint gtid, uint val)
{
    const uint laneIndex = gtid & (WAVE_SIZE - 1);
    const uint base = gtid - laneIndex;
    g_waveMem[gtid] = val;
    GroupMemoryBarrierWithGroupSync();
    uint sum = 0;
    for (uint i = 0; i < laneIndex; i++)
    {
        sum += g_waveMem[base + i];
    }
    GroupMemoryBarrierWithGroupSync();
    return sum;
}

inline uint TJWaveGetLaneIndex(uint gtid, uint waveSize)
{
    return gtid & (waveSize - 1); //WaveGetLaneIndex();Ensure different build target render as same in Editor
}

// Shared memory based WaveActiveBallot: returns a uint4 bitmask where bit i
// is set if lane i's predicate is true. Must be called by ALL threads in the group.
inline uint4 TJWaveActiveBallot(uint gtid, bool pred)
{
    g_waveMem[gtid] = pred ? 1 : 0;
    GroupMemoryBarrierWithGroupSync();
    const uint base = gtid - (gtid & (WAVE_SIZE - 1));
    uint4 result = uint4(0, 0, 0, 0);
    [unroll]
    for (uint i = 0; i < WAVE_SIZE; i++)
    {
        if (g_waveMem[base + i])
        {
            result[i >> 5] |= (1u << (i & 31));
        }
    }
    GroupMemoryBarrierWithGroupSync();
    return result;
}

//Radix Tricks by Michael Herf
//http://stereopsis.com/radix.html
inline uint FloatToUint(float f)
{
    uint mask = -((int) (asuint(f) >> 31)) | 0x80000000;
    return asuint(f) ^ mask;
}

inline float UintToFloat(uint u)
{
    uint mask = ((u >> 31) - 1) | 0x80000000;
    return asfloat(u ^ mask);
}

inline uint IntToUint(int i)
{
    return asuint(i ^ 0x80000000);
}

inline int UintToInt(uint u)
{
    return asint(u ^ 0x80000000);
}

inline uint getWaveCountPass(uint waveSize)
{
    return D_DIM / waveSize;
}

inline uint ExtractDigit(uint key)
{
    return key >> e_radixShift & RADIX_MASK;
}

inline uint ExtractDigit(uint key, uint shift)
{
    return key >> shift & RADIX_MASK;
}

inline uint ExtractPackedIndex(uint key)
{
    return key >> (e_radixShift + 1) & HALF_MASK;
}

inline uint ExtractPackedShift(uint key)
{
    return (key >> e_radixShift & 1) ? 16 : 0;
}

inline uint ExtractPackedValue(uint packed, uint key)
{
    return packed >> ExtractPackedShift(key) & 0xffff;
}

inline uint SubPartSizeWGE16(uint waveSize)
{
    return KEYS_PER_THREAD * waveSize;
}

inline uint SharedOffsetWGE16(uint gtid, uint waveSize)
{
    return TJWaveGetLaneIndex(gtid, waveSize) + getWaveIndex(gtid, waveSize) * SubPartSizeWGE16(waveSize);
}

inline uint SubPartSizeWLT16(uint waveSize, uint _serialIterations)
{
    return KEYS_PER_THREAD * waveSize * _serialIterations;
}

inline uint SharedOffsetWLT16(uint gtid, uint waveSize, uint _serialIterations)
{
    return TJWaveGetLaneIndex(gtid, waveSize) +
        (getWaveIndex(gtid, waveSize) / _serialIterations * SubPartSizeWLT16(waveSize, _serialIterations)) +
        (getWaveIndex(gtid, waveSize) % _serialIterations * waveSize);
}

inline uint DeviceOffsetWGE16(uint gtid, uint waveSize, uint partIndex)
{
    return SharedOffsetWGE16(gtid, waveSize) + partIndex * PART_SIZE;
}

inline uint DeviceOffsetWLT16(uint gtid, uint waveSize, uint partIndex, uint serialIterations)
{
    return SharedOffsetWLT16(gtid, waveSize, serialIterations) + partIndex * PART_SIZE;
}

inline uint GlobalHistOffset()
{
    return e_radixShift << 5;
}

inline uint WaveHistsSizeWGE16(uint waveSize)
{
    return D_DIM / waveSize * RADIX;
}

inline uint WaveHistsSizeWLT16()
{
    return D_TOTAL_SMEM;
}

//*****************************************************************************
//FUNCTIONS COMMON TO THE DOWNSWEEP / DIGIT BINNING PASS
//*****************************************************************************
//If the size of  a wave is too small, we do not have enough space in
//shared memory to assign a histogram to each wave, so instead,
//some operations are peformed serially.
inline uint SerialIterations(uint waveSize)
{
    return (D_DIM / waveSize + 31) >> 5;
}

inline void ClearWaveHists(uint gtid, uint waveSize)
{
    const uint histsEnd = waveSize >= 16 ?
        WaveHistsSizeWGE16(waveSize) : WaveHistsSizeWLT16();
    for (uint i = gtid; i < histsEnd; i += D_DIM)
        g_d[i] = 0;
}

inline void LoadKey(inout uint key, uint index)
{
#if defined(KEY_UINT)
    key = b_sort[index];
#elif defined(KEY_INT)
    key = UintToInt(b_sort[index]);
#elif defined(KEY_FLOAT)
    key = FloatToUint(b_sort[index]);
#endif
}

inline void LoadDummyKey(inout uint key)
{
    key = 0xffffffff;
}

inline KeyStruct LoadKeysWGE16(uint gtid, uint waveSize, uint partIndex)
{
    KeyStruct keys;
    [unroll]
    for (uint i = 0, t = DeviceOffsetWGE16(gtid, waveSize, partIndex);
        i < KEYS_PER_THREAD;
        ++i, t += waveSize)
    {
        LoadKey(keys.k[i], t);
    }
    return keys;
}

inline KeyStruct LoadKeysWLT16(uint gtid, uint waveSize, uint partIndex, uint serialIterations)
{
    KeyStruct keys;
    [unroll]
    for (uint i = 0, t = DeviceOffsetWLT16(gtid, waveSize, partIndex, serialIterations);
        i < KEYS_PER_THREAD;
        ++i, t += waveSize * serialIterations)
    {
        LoadKey(keys.k[i], t);
    }
    return keys;
}

inline KeyStruct LoadKeysPartialWGE16(uint gtid, uint waveSize, uint partIndex)
{
    KeyStruct keys;
    [unroll]
    for (uint i = 0, t = DeviceOffsetWGE16(gtid, waveSize, partIndex);
        i < KEYS_PER_THREAD;
        ++i, t += waveSize)
    {
        if (t < e_numKeys)
            LoadKey(keys.k[i], t);
        else
            LoadDummyKey(keys.k[i]);
    }
    return keys;
}

inline KeyStruct LoadKeysPartialWLT16(uint gtid, uint waveSize, uint partIndex, uint serialIterations)
{
    KeyStruct keys;
    [unroll]
    for (uint i = 0, t = DeviceOffsetWLT16(gtid, waveSize, partIndex, serialIterations);
        i < KEYS_PER_THREAD;
        ++i, t += waveSize * serialIterations)
    {
        if (t < e_numKeys)
            LoadKey(keys.k[i], t);
        else
            LoadDummyKey(keys.k[i]);
    }
    return keys;
}

inline uint WaveFlagsWGE16(uint waveSize)
{
    return (waveSize & 31) ? (1U << waveSize) - 1 : 0xffffffff;
}

inline uint WaveFlagsWLT16(uint waveSize)
{
    return (1U << waveSize) - 1;;
}

inline void WarpLevelMultiSplitWGE16(uint gtid, uint key, inout uint4 waveFlags)
{
    [unroll]
    for (uint k = 0; k < RADIX_LOG; ++k)
    {
        const uint currentBit = 1 << k + e_radixShift;
        const bool t = (key & currentBit) != 0;
        GroupMemoryBarrierWithGroupSync();  //Play on the safe side, throw in a barrier for convergence
        const uint4 ballot = TJWaveActiveBallot(gtid, t);
        if(t)
            waveFlags &= ballot;
        else
            waveFlags &= (~ballot);
    }
}

inline uint2 CountBitsWGE16(uint gtid, uint waveSize, uint ltMask, uint4 waveFlags)
{
    uint2 count = uint2(0, 0);
    
    for(uint wavePart = 0; wavePart < waveSize; wavePart += 32)
    {
        uint t = countbits(waveFlags[wavePart >> 5]);
        if (TJWaveGetLaneIndex(gtid, waveSize) >= wavePart)
        {
            if (TJWaveGetLaneIndex(gtid, waveSize) >= wavePart + 32)
                count.x += t;
            else
                count.x += countbits(waveFlags[wavePart >> 5] & ltMask);
        }
        count.y += t;
    }
    
    return count;
}

inline void WarpLevelMultiSplitWLT16(uint gtid, uint key, inout uint waveFlags)
{
    [unroll]
    for (uint k = 0; k < RADIX_LOG; ++k)
    {
        const bool t = key >> (k + e_radixShift) & 1;
        waveFlags &= (t ? 0 : 0xffffffff) ^ (uint) TJWaveActiveBallot(gtid, t);
    }
}

inline OffsetStruct RankKeysWGE16(
    uint gtid,
    uint waveSize,
    uint waveOffset,
    KeyStruct keys)
{
    OffsetStruct offsets;
    const uint initialFlags = WaveFlagsWGE16(waveSize);
    const uint ltMask = (1U << (TJWaveGetLaneIndex(gtid, waveSize) & 31)) - 1;
    
    [unroll]
    for (uint i = 0; i < KEYS_PER_THREAD; ++i)
    {
        uint4 waveFlags = initialFlags;
        WarpLevelMultiSplitWGE16(gtid, keys.k[i], waveFlags);
        
        const uint index = ExtractDigit(keys.k[i]) + waveOffset;
        const uint2 bitCount = CountBitsWGE16(gtid, waveSize, ltMask, waveFlags);
        
        offsets.o[i] = g_d[index] + bitCount.x;
        GroupMemoryBarrierWithGroupSync();
        if (bitCount.x == 0)
            g_d[index] += bitCount.y;
        GroupMemoryBarrierWithGroupSync();
    }
    
    return offsets;
}

inline OffsetStruct RankKeysWLT16(uint gtid, uint waveSize, uint waveIndex, KeyStruct keys, uint serialIterations)
{
    OffsetStruct offsets;
    const uint ltMask = (1U << TJWaveGetLaneIndex(gtid, waveSize)) - 1;
    const uint initialFlags = WaveFlagsWLT16(waveSize);
    
    [unroll]
    for (uint i = 0; i < KEYS_PER_THREAD; ++i)
    {
        uint waveFlags = initialFlags;
        WarpLevelMultiSplitWLT16(gtid, keys.k[i], waveFlags);
        
        const uint index = ExtractPackedIndex(keys.k[i]) +
                (waveIndex / serialIterations * HALF_RADIX);
        
        const uint peerBits = countbits(waveFlags & ltMask);
        for (uint k = 0; k < serialIterations; ++k)
        {
            if (waveIndex % serialIterations == k)
                offsets.o[i] = ExtractPackedValue(g_d[index], keys.k[i]) + peerBits;
            
            GroupMemoryBarrierWithGroupSync();
            if (waveIndex % serialIterations == k && peerBits == 0)
            {
                InterlockedAdd(g_d[index],
                    countbits(waveFlags) << ExtractPackedShift(keys.k[i]));
            }
            GroupMemoryBarrierWithGroupSync();
        }
    }
    
    return offsets;
}

inline uint WaveHistInclusiveScanCircularShiftWGE16(uint gtid, uint waveSize)
{
    uint histReduction = g_d[gtid];
    for (uint i = gtid + RADIX; i < WaveHistsSizeWGE16(waveSize); i += RADIX)
    {
        histReduction += g_d[i];
        g_d[i] = histReduction - g_d[i];
    }
    return histReduction;
}

inline uint WaveHistInclusiveScanCircularShiftWLT16(uint gtid)
{
    uint histReduction = g_d[gtid];
    for (uint i = gtid + HALF_RADIX; i < WaveHistsSizeWLT16(); i += HALF_RADIX)
    {
        histReduction += g_d[i];
        g_d[i] = histReduction - g_d[i];
    }
    return histReduction;
}

inline void WaveHistReductionExclusiveScanWGE16(uint gtid, uint waveSize, uint histReduction)
{
    if (gtid < RADIX)
    {
        const uint laneMask = waveSize - 1;
        g_d[((TJWaveGetLaneIndex(gtid, waveSize) + 1) & laneMask) + (gtid & ~laneMask)] = histReduction;
    }
    GroupMemoryBarrierWithGroupSync();
                
    // All threads call TJWavePrefixSum to satisfy barrier requirements.
    // Non-participating threads pass 0 so they don't affect the prefix sum.
    uint prefixInput = (gtid < RADIX / waveSize) ? g_d[gtid * waveSize] : 0;
    uint prefixResult = TJWavePrefixSum(gtid, prefixInput);
    if (gtid < RADIX / waveSize)
    {
        g_d[gtid * waveSize] = prefixResult;
    }
    GroupMemoryBarrierWithGroupSync();
    
    uint t = TJWaveReadLaneAt(gtid, g_d[gtid], 0);
    if (gtid < RADIX && TJWaveGetLaneIndex(gtid, waveSize))
        g_d[gtid] += t;
}

//inclusive/exclusive prefix sum up the histograms,
//use a blelloch scan for in place packed exclusive
inline void WaveHistReductionExclusiveScanWLT16(uint gtid)
{
    uint shift = 1;
    for (uint j = RADIX >> 2; j > 0; j >>= 1)
    {
        GroupMemoryBarrierWithGroupSync();
        if (gtid < j)
        {
            g_d[((((gtid << 1) + 2) << shift) - 1) >> 1] +=
                g_d[((((gtid << 1) + 1) << shift) - 1) >> 1] & 0xffff0000;
        }
        shift++;
    }
    GroupMemoryBarrierWithGroupSync();
                
    if (gtid == 0)
        g_d[HALF_RADIX - 1] &= 0xffff;
                
    for (uint j = 1; j < RADIX >> 1; j <<= 1)
    {
        --shift;
        GroupMemoryBarrierWithGroupSync();
        if (gtid < j)
        {
            const uint t = ((((gtid << 1) + 1) << shift) - 1) >> 1;
            const uint t2 = ((((gtid << 1) + 2) << shift) - 1) >> 1;
            const uint t3 = g_d[t];
            g_d[t] = (g_d[t] & 0xffff) | (g_d[t2] & 0xffff0000);
            g_d[t2] += t3 & 0xffff0000;
        }
    }

    GroupMemoryBarrierWithGroupSync();
    if (gtid < HALF_RADIX)
    {
        const uint t = g_d[gtid];
        g_d[gtid] = (t >> 16) + (t << 16) + (t & 0xffff0000);
    }
}

inline void UpdateOffsetsWGE16(
    uint gtid,
    uint waveSize,
    inout OffsetStruct offsets,
    KeyStruct keys)
{
    if (gtid >= waveSize)
    {
        const uint t = getWaveIndex(gtid, waveSize) * RADIX;
        [unroll]
        for (uint i = 0; i < KEYS_PER_THREAD; ++i)
        {
            const uint t2 = ExtractDigit(keys.k[i]);
            offsets.o[i] += g_d[t2 + t] + g_d[t2];
        }
    }
    else
    {
        [unroll]
        for (uint i = 0; i < KEYS_PER_THREAD; ++i)
            offsets.o[i] += g_d[ExtractDigit(keys.k[i])];
    }
}

inline void UpdateOffsetsWLT16(
    uint gtid,
    uint waveSize,
    uint serialIterations,
    inout OffsetStruct offsets,
    KeyStruct keys)
{
    if (gtid >= waveSize * serialIterations)
    {
        const uint t = getWaveIndex(gtid, waveSize) / serialIterations * HALF_RADIX;
        [unroll]
        for (uint i = 0; i < KEYS_PER_THREAD; ++i)
        {
            const uint t2 = ExtractPackedIndex(keys.k[i]);
            offsets.o[i] += ExtractPackedValue(g_d[t2 + t] + g_d[t2], keys.k[i]);
        }
    }
    else
    {
        [unroll]
        for (uint i = 0; i < KEYS_PER_THREAD; ++i)
            offsets.o[i] += ExtractPackedValue(g_d[ExtractPackedIndex(keys.k[i])], keys.k[i]);
    }
}

inline void ScatterKeysShared(OffsetStruct offsets, KeyStruct keys)
{
    [unroll]
    for (uint i = 0; i < KEYS_PER_THREAD; ++i)
        g_d[offsets.o[i]] = keys.k[i];
}

inline uint DescendingIndex(uint deviceIndex)
{
    return e_numKeys - deviceIndex - 1;
}

inline void WriteKey(uint deviceIndex, uint groupSharedIndex)
{
#if defined(KEY_UINT)
    b_alt[deviceIndex] = g_d[groupSharedIndex];
#elif defined(KEY_INT)
    b_alt[deviceIndex] = UintToInt(g_d[groupSharedIndex]);
#elif defined(KEY_FLOAT)
    b_alt[deviceIndex] = UintToFloat(g_d[groupSharedIndex]);
#endif
}

inline void LoadPayload(inout uint payload, uint deviceIndex)
{
#if defined(PAYLOAD_UINT)
    payload = b_sortPayload[deviceIndex];
#elif defined(PAYLOAD_INT) || defined(PAYLOAD_FLOAT)
    payload = asuint(b_sortPayload[deviceIndex]);
#endif
}

inline void ScatterPayloadsShared(OffsetStruct offsets, KeyStruct payloads)
{
    ScatterKeysShared(offsets, payloads);
}

inline void WritePayload(uint deviceIndex, uint groupSharedIndex)
{
#if defined(PAYLOAD_UINT)
    b_altPayload[deviceIndex] = g_d[groupSharedIndex];
#elif defined(PAYLOAD_INT)
    b_altPayload[deviceIndex] = asint(g_d[groupSharedIndex]);
#elif defined(PAYLOAD_FLOAT)
    b_altPayload[deviceIndex] = asfloat(g_d[groupSharedIndex]);
#endif
}

//*****************************************************************************
//SCATTERING: FULL PARTITIONS
//*****************************************************************************
//KEYS ONLY
inline void ScatterKeysOnlyDeviceAscending(uint gtid)
{
    for (uint i = gtid; i < PART_SIZE; i += D_DIM)
        WriteKey(g_d[ExtractDigit(g_d[i]) + PART_SIZE] + i, i);
}

inline void ScatterKeysOnlyDeviceDescending(uint gtid)
{
    if (e_radixShift == 24)
    {
        for (uint i = gtid; i < PART_SIZE; i += D_DIM)
            WriteKey(DescendingIndex(g_d[ExtractDigit(g_d[i]) + PART_SIZE] + i), i);
    }
    else
    {
        ScatterKeysOnlyDeviceAscending(gtid);
    }
}

inline void ScatterKeysOnlyDevice(uint gtid)
{
#if defined(SHOULD_ASCEND)
    ScatterKeysOnlyDeviceAscending(gtid);
#else
    ScatterKeysOnlyDeviceDescending(gtid);
#endif
}

//KEY VALUE PAIRS
inline void ScatterPairsKeyPhaseAscending(
    uint gtid,
    inout DigitStruct digits)
{
    [unroll]
    for (uint i = 0, t = gtid; i < KEYS_PER_THREAD; ++i, t += D_DIM)
    {
        digits.d[i] = ExtractDigit(g_d[t]);
        WriteKey(g_d[digits.d[i] + PART_SIZE] + t, t);
    }
}

inline void ScatterPairsKeyPhaseDescending(
    uint gtid,
    inout DigitStruct digits)
{
    if (e_radixShift == 24)
    {
        [unroll]
        for (uint i = 0, t = gtid; i < KEYS_PER_THREAD; ++i, t += D_DIM)
        {
            digits.d[i] = ExtractDigit(g_d[t]);
            WriteKey(DescendingIndex(g_d[digits.d[i] + PART_SIZE] + t), t);
        }
    }
    else
    {
        ScatterPairsKeyPhaseAscending(gtid, digits);
    }
}

inline void LoadPayloadsWGE16(
    uint gtid,
    uint waveSize,
    uint partIndex,
    inout KeyStruct payloads)
{
    [unroll]
    for (uint i = 0, t = DeviceOffsetWGE16(gtid, waveSize, partIndex);
        i < KEYS_PER_THREAD;
        ++i, t += waveSize)
    {
        LoadPayload(payloads.k[i], t);
    }
}

inline void LoadPayloadsWLT16(
    uint gtid,
    uint waveSize,
    uint partIndex,
    uint serialIterations,
    inout KeyStruct payloads)
{
    [unroll]
    for (uint i = 0, t = DeviceOffsetWLT16(gtid, waveSize, partIndex, serialIterations);
        i < KEYS_PER_THREAD;
        ++i, t += waveSize * serialIterations)
    {
        LoadPayload(payloads.k[i], t);
    }
}

inline void ScatterPayloadsAscending(uint gtid, DigitStruct digits)
{
    [unroll]
    for (uint i = 0, t = gtid; i < KEYS_PER_THREAD; ++i, t += D_DIM)
        WritePayload(g_d[digits.d[i] + PART_SIZE] + t, t);
}

inline void ScatterPayloadsDescending(uint gtid, DigitStruct digits)
{
    if (e_radixShift == 24)
    {
        [unroll]
        for (uint i = 0, t = gtid; i < KEYS_PER_THREAD; ++i, t += D_DIM)
            WritePayload(DescendingIndex(g_d[digits.d[i] + PART_SIZE] + t), t);
    }
    else
    {
        ScatterPayloadsAscending(gtid, digits);
    }
}

inline void ScatterPairsDevice(
    uint gtid,
    uint waveSize,
    uint partIndex,
    OffsetStruct offsets)
{
    DigitStruct digits;
#if defined(SHOULD_ASCEND)
    ScatterPairsKeyPhaseAscending(gtid, digits);
#else
    ScatterPairsKeyPhaseDescending(gtid, digits);
#endif
    GroupMemoryBarrierWithGroupSync();
    
    KeyStruct payloads;
    if (waveSize >= 16)
        LoadPayloadsWGE16(gtid, waveSize, partIndex, payloads);
    else
        LoadPayloadsWLT16(gtid, waveSize, partIndex, SerialIterations(waveSize), payloads);
    ScatterPayloadsShared(offsets, payloads);
    GroupMemoryBarrierWithGroupSync();
    
#if defined(SHOULD_ASCEND)
    ScatterPayloadsAscending(gtid, digits);
#else
    ScatterPayloadsDescending(gtid, digits);
#endif
}

inline void ScatterDevice(
    uint gtid,
    uint waveSize,
    uint partIndex,
    OffsetStruct offsets)
{
#if defined(SORT_PAIRS)
    ScatterPairsDevice(
        gtid,
        waveSize,
        partIndex,
        offsets);
#else
    ScatterKeysOnlyDevice(gtid);
#endif
}

//*****************************************************************************
//SCATTERING: PARTIAL PARTITIONS
//*****************************************************************************
//KEYS ONLY
inline void ScatterKeysOnlyDevicePartialAscending(uint gtid, uint finalPartSize)
{
    for (uint i = gtid; i < PART_SIZE; i += D_DIM)
    {
        if (i < finalPartSize)
            WriteKey(g_d[ExtractDigit(g_d[i]) + PART_SIZE] + i, i);
    }
}

inline void ScatterKeysOnlyDevicePartialDescending(uint gtid, uint finalPartSize)
{
    if (e_radixShift == 24)
    {
        for (uint i = gtid; i < PART_SIZE; i += D_DIM)
        {
            if (i < finalPartSize)
                WriteKey(DescendingIndex(g_d[ExtractDigit(g_d[i]) + PART_SIZE] + i), i);
        }
    }
    else
    {
        ScatterKeysOnlyDevicePartialAscending(gtid, finalPartSize);
    }
}

inline void ScatterKeysOnlyDevicePartial(uint gtid, uint partIndex)
{
    const uint finalPartSize = e_numKeys - partIndex * PART_SIZE;
#if defined(SHOULD_ASCEND)
    ScatterKeysOnlyDevicePartialAscending(gtid, finalPartSize);
#else
    ScatterKeysOnlyDevicePartialDescending(gtid, finalPartSize);
#endif
}

//KEY VALUE PAIRS
inline void ScatterPairsKeyPhaseAscendingPartial(
    uint gtid,
    uint finalPartSize,
    inout DigitStruct digits)
{
    [unroll]
    for (uint i = 0, t = gtid; i < KEYS_PER_THREAD; ++i, t += D_DIM)
    {
        if (t < finalPartSize)
        {
            digits.d[i] = ExtractDigit(g_d[t]);
            WriteKey(g_d[digits.d[i] + PART_SIZE] + t, t);
        }
    }
}

inline void ScatterPairsKeyPhaseDescendingPartial(
    uint gtid,
    uint finalPartSize,
    inout DigitStruct digits)
{
    if (e_radixShift == 24)
    {
        [unroll]
        for (uint i = 0, t = gtid; i < KEYS_PER_THREAD; ++i, t += D_DIM)
        {
            if (t < finalPartSize)
            {
                digits.d[i] = ExtractDigit(g_d[t]);
                WriteKey(DescendingIndex(g_d[digits.d[i] + PART_SIZE] + t), t);
            }
        }
    }
    else
    {
        ScatterPairsKeyPhaseAscendingPartial(gtid, finalPartSize, digits);
    }
}

inline void LoadPayloadsPartialWGE16(
    uint gtid,
    uint waveSize,
    uint partIndex,
    inout KeyStruct payloads)
{
    [unroll]
    for (uint i = 0, t = DeviceOffsetWGE16(gtid, waveSize, partIndex);
        i < KEYS_PER_THREAD;
        ++i, t += waveSize)
    {
        if (t < e_numKeys)
            LoadPayload(payloads.k[i], t);
    }
}

inline void LoadPayloadsPartialWLT16(
    uint gtid,
    uint waveSize,
    uint partIndex,
    uint serialIterations,
    inout KeyStruct payloads)
{
    [unroll]
    for (uint i = 0, t = DeviceOffsetWLT16(gtid, waveSize, partIndex, serialIterations);
        i < KEYS_PER_THREAD;
        ++i, t += waveSize * serialIterations)
    {
        if (t < e_numKeys)
            LoadPayload(payloads.k[i], t);
    }
}

inline void ScatterPayloadsAscendingPartial(
    uint gtid,
    uint finalPartSize,
    DigitStruct digits)
{
    [unroll]
    for (uint i = 0, t = gtid; i < KEYS_PER_THREAD; ++i, t += D_DIM)
    {
        if (t < finalPartSize)
            WritePayload(g_d[digits.d[i] + PART_SIZE] + t, t);
    }
}

inline void ScatterPayloadsDescendingPartial(
    uint gtid,
    uint finalPartSize,
    DigitStruct digits)
{
    if (e_radixShift == 24)
    {
        [unroll]
        for (uint i = 0, t = gtid; i < KEYS_PER_THREAD; ++i, t += D_DIM)
        {
            if (t < finalPartSize)
                WritePayload(DescendingIndex(g_d[digits.d[i] + PART_SIZE] + t), t);
        }
    }
    else
    {
        ScatterPayloadsAscendingPartial(gtid, finalPartSize, digits);
    }
}

inline void ScatterPairsDevicePartial(
    uint gtid,
    uint waveSize,
    uint partIndex,
    OffsetStruct offsets)
{
    DigitStruct digits;
    const uint finalPartSize = e_numKeys - partIndex * PART_SIZE;
#if defined(SHOULD_ASCEND)
    ScatterPairsKeyPhaseAscendingPartial(gtid, finalPartSize, digits);
#else
    ScatterPairsKeyPhaseDescendingPartial(gtid, finalPartSize, digits);
#endif
    GroupMemoryBarrierWithGroupSync();
    
    KeyStruct payloads;
    if (waveSize >= 16)
        LoadPayloadsPartialWGE16(gtid, waveSize, partIndex, payloads);
    else
        LoadPayloadsPartialWLT16(gtid, waveSize, partIndex, SerialIterations(waveSize), payloads);
    ScatterPayloadsShared(offsets, payloads);
    GroupMemoryBarrierWithGroupSync();
    
#if defined(SHOULD_ASCEND)
    ScatterPayloadsAscendingPartial(gtid, finalPartSize, digits);
#else
    ScatterPayloadsDescendingPartial(gtid, finalPartSize, digits);
#endif
}

inline void ScatterDevicePartial(
    uint gtid,
    uint waveSize,
    uint partIndex,
    OffsetStruct offsets)
{
#if defined(SORT_PAIRS)
    ScatterPairsDevicePartial(
        gtid,
        waveSize,
        partIndex,
        offsets);
#else
    ScatterKeysOnlyDevicePartial(gtid, partIndex);
#endif
}