// SPDX-License-Identifier: MIT

using System;
using GaussianSplatting.Editor.Utils;
using GaussianSplatting.Runtime;
using Unity.Collections;
using Unity.Mathematics;
using UnityEditor;
using UnityEditor.AssetImporters;
using UnityEngine;

namespace GaussianSplatting.Editor
{
    [ScriptedImporter(1, new[] { "ply", "spz" }, new[] { "ply", "spz" })]
    public class GaussianSplatAssetImporter : ScriptedImporter
    {
        const string kProgressTitle = "Importing Gaussian Splat";

        public enum SpzSource
        {
            Rodin,
            Marble,
        }

        [SerializeField] GaussianSplatAssetProcessor.DataQuality m_Quality = GaussianSplatAssetProcessor.DataQuality.Medium;
        [SerializeField] bool m_ImportCameras = true;
        [SerializeField] SpzSource m_SpzSource = SpzSource.Rodin;

        [SerializeField] GaussianSplatAsset.VectorFormat m_FormatPos = GaussianSplatAsset.VectorFormat.Norm11;
        [SerializeField] GaussianSplatAsset.VectorFormat m_FormatScale = GaussianSplatAsset.VectorFormat.Norm11;
        [SerializeField] GaussianSplatAsset.ColorFormat m_FormatColor = GaussianSplatAsset.ColorFormat.Norm8x4;
        [SerializeField] GaussianSplatAsset.SHFormat m_FormatSH = GaussianSplatAsset.SHFormat.Norm6;

        public override void OnImportAsset(AssetImportContext ctx)
        {
            string assetPath = ctx.assetPath;
            var settings = GetImportSettings();

            if (m_Quality != GaussianSplatAssetProcessor.DataQuality.Custom)
                GaussianSplatAssetProcessor.ApplyQualityLevel(m_Quality, ref settings);

            NativeArray<InputSplatData> inputSplats;
            try
            {
                CoordinateSystem spzFrom = m_SpzSource == SpzSource.Marble
                    ? CoordinateSystem.LDF
                    : CoordinateSystem.RUB;
                GaussianFileReader.ReadFile(assetPath, out inputSplats, spzFrom);
            }
            catch (Exception ex)
            {
                ctx.LogImportError($"Failed to read Gaussian Splat file: {ex.Message}");
                return;
            }

            if (inputSplats.Length == 0)
            {
                ctx.LogImportError("Gaussian Splat file contains no data");
                inputSplats.Dispose();
                return;
            }

            EditorUtility.DisplayProgressBar(kProgressTitle, "Calculating bounds", 0.02f);
            GaussianSplatAssetProcessor.CalculateBounds(inputSplats, out float3 boundsMin, out float3 boundsMax);

            EditorUtility.DisplayProgressBar(kProgressTitle, "Morton reordering", 0.05f);
            GaussianSplatAssetProcessor.ReorderMorton(inputSplats, boundsMin, boundsMax);

            NativeArray<int> splatSHIndices = default;
            NativeArray<GaussianSplatAsset.SHTableItemFloat16> clusteredSHs = default;
            if (settings.FormatSH >= GaussianSplatAsset.SHFormat.Cluster64k)
            {
                EditorUtility.DisplayProgressBar(kProgressTitle, "Cluster SHs", 0.2f);
                GaussianSplatAssetProcessor.ClusterSHs(inputSplats, settings.FormatSH, kProgressTitle, out clusteredSHs, out splatSHIndices);
            }

            string baseName = System.IO.Path.GetFileNameWithoutExtension(assetPath);
            GaussianSplatAsset.CameraInfo[] cameras = GaussianSplatAssetProcessor.LoadJsonCamerasFile(assetPath, m_ImportCameras);

            EditorUtility.DisplayProgressBar(kProgressTitle, "Creating asset", 0.7f);
            GaussianSplatAsset asset = ScriptableObject.CreateInstance<GaussianSplatAsset>();
            asset.Initialize(inputSplats.Length, settings.FormatPos, settings.FormatScale, settings.FormatColor, settings.FormatSH, boundsMin, boundsMax, cameras);
            asset.name = baseName;

            var dataHash = new Hash128((uint)asset.splatCount, (uint)asset.formatVersion, 0, 0);

            byte[] chunkBytes = null;
            if (settings.IsUsingChunks)
                chunkBytes = GaussianSplatAssetProcessor.CreateChunkBytes(inputSplats, ref dataHash);
            byte[] posBytes = GaussianSplatAssetProcessor.CreatePositionsBytes(inputSplats, settings.FormatPos, ref dataHash);
            byte[] otherBytes = GaussianSplatAssetProcessor.CreateOtherBytes(inputSplats, splatSHIndices, settings.FormatScale, ref dataHash);
            byte[] colorBytes = GaussianSplatAssetProcessor.CreateColorBytes(inputSplats, settings.FormatColor, ref dataHash);
            byte[] shBytes = GaussianSplatAssetProcessor.CreateSHBytes(inputSplats, clusteredSHs, settings.FormatSH, ref dataHash);

            asset.SetDataHash(dataHash);
            asset.SetDataBytes(chunkBytes, posBytes, otherBytes, colorBytes, shBytes);

            splatSHIndices.Dispose();
            clusteredSHs.Dispose();
            inputSplats.Dispose();

            ctx.AddObjectToAsset("main", asset);
            ctx.SetMainObject(asset);

            EditorUtility.ClearProgressBar();
        }

        GaussianSplatAssetProcessor.ImportSettings GetImportSettings()
        {
            return new GaussianSplatAssetProcessor.ImportSettings
            {
                FormatPos = m_FormatPos,
                FormatScale = m_FormatScale,
                FormatColor = m_FormatColor,
                FormatSH = m_FormatSH,
            };
        }
    }
}
