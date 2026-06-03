/******************************************************************************
 * DeviceRadixSort
 * Device Level 8-bit LSD Radix Sort using reduce then scan
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
#include "SortCommon.hlsl"

#define US_DIM          128U        //The number of threads in a Upsweep threadblock
#define SCAN_DIM        128U        //The number of threads in a Scan threadblock

RWStructuredBuffer<uint> b_globalHist;  //buffer holding device level offsets for each binning pass
RWStructuredBuffer<uint> b_passHist;    //buffer used to store reduced sums of partition tiles

groupshared uint g_us[RADIX * 2];   //Shared memory for upsweep
groupshared uint g_scan[SCAN_DIM];  //Shared memory for the scan

//*****************************************************************************
//INIT KERNEL
//*****************************************************************************
//Clear the global histogram, as we will be adding to it atomically
[numthreads(1024, 1, 1)]
void InitDeviceRadixSort(int3 id : SV_DispatchThreadID)
{
    b_globalHist[id.x] = 0;
}

//*****************************************************************************
//UPSWEEP KERNEL
//*****************************************************************************
//histogram, 64 threads to a histogram
inline void HistogramDigitCounts(uint gtid, uint gid)
{
    const uint histOffset = gtid / 64 * RADIX;
    const uint partitionEnd = gid == e_threadBlocks - 1 ?
        e_numKeys : (gid + 1) * PART_SIZE;
    for (uint i = gtid + gid * PART_SIZE; i < partitionEnd; i += US_DIM)
    {
#if defined(KEY_UINT)
        InterlockedAdd(g_us[ExtractDigit(b_sort[i]) + histOffset], 1);
#elif defined(KEY_INT)
        InterlockedAdd(g_us[ExtractDigit(IntToUint(b_sort[i])) + histOffset], 1);
#elif defined(KEY_FLOAT)
        InterlockedAdd(g_us[ExtractDigit(FloatToUint(b_sort[i])) + histOffset], 1);
#endif
    }
}

//reduce and pass to tile histogram
//Leaves g_us[0 .. RADIX - 1] holding the raw per-digit counts for this tile.
//The exclusive prefix sum over those counts is computed separately in
//GlobalHistExclusiveScan(), which no longer depends on any wave behaviour.
inline void ReduceWriteDigitCounts(uint gtid, uint gid)
{
    for (uint i = gtid; i < RADIX; i += US_DIM)
    {
        g_us[i] += g_us[i + RADIX];
        b_passHist[i * e_threadBlocks + gid] = g_us[i];
    }
}

//Exclusive scan over the RADIX per-digit counts, then atomically accumulate the
//result into the device-wide histogram.
//
//This replaces the previous wave-size specialised GlobalHistExclusiveScanWGE16 /
//WLT16 implementations: it uses no wave intrinsic and no hardware lane index, so
//it produces identical results on every backend (the original code broke on
//drivers where WaveGetLaneIndex() lives in a different coordinate system than
//WaveGetLaneCount()), and it cannot hit the laneLog == 0 infinite loop that the
//old WLT16 path suffered from at very small (emulated) wave sizes.
//
//On entry g_us[0 .. RADIX - 1] holds this tile's raw per-digit counts. We compute
//the exclusive prefix sum E[d] = sum(count[0 .. d - 1]) into the upper, now-unused
//scratch half (g_us[RADIX .. 2 * RADIX - 1]) and atomically add E[d] to
//b_globalHist[d]. RADIX is small (256) and this runs once per tile, so a single
//thread performs the scan for maximum simplicity and determinism.
inline void GlobalHistExclusiveScan(uint gtid)
{
    GroupMemoryBarrierWithGroupSync();

    if (gtid == 0)
    {
        uint sum = 0;
        [loop]
        for (uint d = 0; d < RADIX; ++d)
        {
            const uint c = g_us[d];
            g_us[d + RADIX] = sum;
            sum += c;
        }
    }
    GroupMemoryBarrierWithGroupSync();

    const uint globalHistOffset = GlobalHistOffset();
    for (uint i = gtid; i < RADIX; i += US_DIM)
        InterlockedAdd(b_globalHist[i + globalHistOffset], g_us[i + RADIX]);
}

[numthreads(US_DIM, 1, 1)]
void Upsweep(uint3 gtid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    //clear shared memory
    const uint histsEnd = RADIX * 2;
    for (uint i = gtid.x; i < histsEnd; i += US_DIM)
        g_us[i] = 0;
    GroupMemoryBarrierWithGroupSync();

    HistogramDigitCounts(gtid.x, gid.x);
    GroupMemoryBarrierWithGroupSync();
    
    ReduceWriteDigitCounts(gtid.x, gid.x);
    
    GlobalHistExclusiveScan(gtid.x);
}

//*****************************************************************************
//SCAN KERNEL
//*****************************************************************************
//Exclusive prefix sum over the e_threadBlocks per-tile counts that belong to a
//single digit (one digit per threadblock / gid), written back in place to
//b_passHist. The Downsweep then uses these values as the per-tile starting
//offset for each digit.
//
//This replaces the previous wave-size specialised ExclusiveThreadBlockScan
//WGE16 / WLT16 family. It is a Hillis-Steele scan performed in chunks of
//SCAN_DIM elements with a running reduction carried between chunks. It uses no
//wave intrinsic and no hardware lane index, so it is correct and identical on
//every backend, and it cannot hit the laneLog == 0 infinite loop that the old
//WLT16 path suffered from at very small (emulated) wave sizes.
inline void ExclusiveThreadBlockScan(uint gtid, uint gid)
{
    const uint deviceOffset = gid * e_threadBlocks;
    uint reduction = 0;

    for (uint chunkStart = 0; chunkStart < e_threadBlocks; chunkStart += SCAN_DIM)
    {
        const uint idx = chunkStart + gtid;
        const bool inRange = idx < e_threadBlocks;
        const uint v = inRange ? b_passHist[deviceOffset + idx] : 0;

        g_scan[gtid] = v;
        GroupMemoryBarrierWithGroupSync();

        //Inclusive Hillis-Steele scan across the SCAN_DIM lanes of this chunk.
        //The read of g_scan[gtid - offset] into a register is separated from the
        //write back into g_scan[gtid] by a barrier, so the pass is race free.
        [unroll]
        for (uint offset = 1; offset < SCAN_DIM; offset <<= 1)
        {
            const uint t = (gtid >= offset) ? g_scan[gtid - offset] : 0;
            GroupMemoryBarrierWithGroupSync();
            g_scan[gtid] += t;
            GroupMemoryBarrierWithGroupSync();
        }

        //g_scan[gtid] now holds the inclusive prefix sum within the chunk.
        //Subtract the lane's own value to make it exclusive, then add the totals
        //of all preceding chunks.
        if (inRange)
            b_passHist[deviceOffset + idx] = (g_scan[gtid] - v) + reduction;

        //Carry the inclusive total of this chunk (held by the last valid lane)
        //into the running reduction for the following chunks.
        const uint validInChunk = min(SCAN_DIM, e_threadBlocks - chunkStart);
        reduction += g_scan[validInChunk - 1];
        GroupMemoryBarrierWithGroupSync();
    }
}

//Scan does not need flattening of gids
[numthreads(SCAN_DIM, 1, 1)]
void Scan(uint3 gtid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    ExclusiveThreadBlockScan(gtid.x, gid.x);
}

//*****************************************************************************
//DOWNSWEEP KERNEL
//*****************************************************************************
inline void LoadThreadBlockReductions(uint gtid, uint gid, uint exclusiveHistReduction)
{
    if (gtid < RADIX)
    {
        g_d[gtid + PART_SIZE] = b_globalHist[gtid + GlobalHistOffset()] +
            b_passHist[gtid * e_threadBlocks + gid] - exclusiveHistReduction;
    }
}

[numthreads(D_DIM, 1, 1)]
void Downsweep(uint3 gtid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    KeyStruct keys;
    OffsetStruct offsets;
    const uint waveSize = getWaveSize();
    
    ClearWaveHists(gtid.x, waveSize);
    GroupMemoryBarrierWithGroupSync();
    
    if (gid.x < e_threadBlocks - 1)
    {
        if (waveSize >= 16)
            keys = LoadKeysWGE16(gtid.x, waveSize, gid.x);
        
        if (waveSize < 16)
            keys = LoadKeysWLT16(gtid.x, waveSize, gid.x, SerialIterations(waveSize));
    }
        
    if (gid.x == e_threadBlocks - 1)
    {
        if (waveSize >= 16)
            keys = LoadKeysPartialWGE16(gtid.x, waveSize, gid.x);
        
        if (waveSize < 16)
            keys = LoadKeysPartialWLT16(gtid.x, waveSize, gid.x, SerialIterations(waveSize));
    }
    
    uint exclusiveHistReduction;
    
    if (waveSize >= 16)
    {
        offsets = RankKeysWGE16(gtid.x, waveSize, getWaveIndex(gtid.x, waveSize) * RADIX, keys);
        GroupMemoryBarrierWithGroupSync();
        
        uint histReduction;
        if (gtid.x < RADIX)
        {
            histReduction = WaveHistInclusiveScanCircularShiftWGE16(gtid.x, waveSize);
            histReduction += TJWavePrefixSum(gtid.x, histReduction); //take advantage of barrier to begin scan
        }
        GroupMemoryBarrierWithGroupSync();
        
        WaveHistReductionExclusiveScanWGE16(gtid.x, waveSize, histReduction);
        GroupMemoryBarrierWithGroupSync();
            
        UpdateOffsetsWGE16(gtid.x, waveSize, offsets, keys);
        if (gtid.x < RADIX)
            exclusiveHistReduction = g_d[gtid.x]; //take advantage of barrier to grab value
        GroupMemoryBarrierWithGroupSync();
    }
    
    if (waveSize < 16)
    {
        offsets = RankKeysWLT16(gtid.x, waveSize, getWaveIndex(gtid.x, waveSize), keys, SerialIterations(waveSize));
            
        if (gtid.x < HALF_RADIX)
        {
            uint histReduction = WaveHistInclusiveScanCircularShiftWLT16(gtid.x);
            g_d[gtid.x] = histReduction + (histReduction << 16); //take advantage of barrier to begin scan
        }
            
        WaveHistReductionExclusiveScanWLT16(gtid.x);
        GroupMemoryBarrierWithGroupSync();
            
        UpdateOffsetsWLT16(gtid.x, waveSize, SerialIterations(waveSize), offsets, keys);
        if (gtid.x < RADIX) //take advantage of barrier to grab value
            exclusiveHistReduction = g_d[gtid.x >> 1] >> ((gtid.x & 1) ? 16 : 0) & 0xffff;
        GroupMemoryBarrierWithGroupSync();
    }
    
    ScatterKeysShared(offsets, keys);
    LoadThreadBlockReductions(gtid.x, gid.x, exclusiveHistReduction);
    GroupMemoryBarrierWithGroupSync();
    
    if (gid.x < e_threadBlocks - 1)
        ScatterDevice(gtid.x, waveSize, gid.x, offsets);
        
    if (gid.x == e_threadBlocks - 1)
        ScatterDevicePartial(gtid.x, waveSize, gid.x, offsets);
}
