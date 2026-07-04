// SPDX-License-Identifier: MIT

using System;
using System.IO;
using GaussianSplatting.Editor.Utils;
using GaussianSplatting.Runtime;
using Unity.Collections;
using Unity.Mathematics;
using UnityEditor;
using UnityEngine;

namespace GaussianSplatting.Editor
{
    public class GaussianSplatAssetCreator : EditorWindow
    {
        const string kProgressTitle = "Creating Gaussian Splat Asset";
        const string kPrefQuality = "nesnausk.GaussianSplatting.CreatorQuality";
        const string kPrefOutputFolder = "nesnausk.GaussianSplatting.CreatorOutputFolder";
        const string kPrefSpzSource = "nesnausk.GaussianSplatting.CreatorSpzSource";

        public enum SpzSource
        {
            Rodin,
            Marble,
        }

        readonly FilePickerControl m_FilePicker = new();

        [SerializeField] string m_InputFile;
        [SerializeField] bool m_ImportCameras = true;
        [SerializeField] SpzSource m_SpzSource = SpzSource.Rodin;

        [SerializeField] string m_OutputFolder = "Assets/GaussianAssets";
        [SerializeField] GaussianSplatAssetProcessor.DataQuality m_Quality = GaussianSplatAssetProcessor.DataQuality.Medium;
        [SerializeField] GaussianSplatAsset.VectorFormat m_FormatPos;
        [SerializeField] GaussianSplatAsset.VectorFormat m_FormatScale;
        [SerializeField] GaussianSplatAsset.ColorFormat m_FormatColor;
        [SerializeField] GaussianSplatAsset.SHFormat m_FormatSH;

        string m_ErrorMessage;
        string m_PrevFilePath;
        int m_PrevVertexCount;
        long m_PrevFileSize;

        [MenuItem("Tools/Gaussian Splats/Create GaussianSplatAsset")]
        public static void Init()
        {
            var window = GetWindowWithRect<GaussianSplatAssetCreator>(new Rect(50, 50, 360, 340), false, "Gaussian Splat Creator", true);
            window.minSize = new Vector2(320, 320);
            window.maxSize = new Vector2(1500, 1500);
            window.Show();
        }

        void Awake()
        {
            m_Quality = (GaussianSplatAssetProcessor.DataQuality)EditorPrefs.GetInt(kPrefQuality, (int)GaussianSplatAssetProcessor.DataQuality.Medium);
            m_OutputFolder = EditorPrefs.GetString(kPrefOutputFolder, "Assets/GaussianAssets");
            m_SpzSource = (SpzSource)EditorPrefs.GetInt(kPrefSpzSource, (int)SpzSource.Rodin);
        }

        void OnEnable()
        {
            ApplyQualityLevel();
        }

        void OnGUI()
        {
            var settings = GetImportSettings();

            EditorGUILayout.Space();
            GUILayout.Label("Input data", EditorStyles.boldLabel);
            var rect = EditorGUILayout.GetControlRect(true);
            m_InputFile = m_FilePicker.PathFieldGUI(rect, new GUIContent("Input PLY/SPZ File"), m_InputFile, "ply,spz", "PointCloudFile");
            m_ImportCameras = EditorGUILayout.Toggle("Import Cameras", m_ImportCameras);

            if (m_InputFile != m_PrevFilePath && !string.IsNullOrWhiteSpace(m_InputFile))
            {
                m_PrevVertexCount = 0;
                m_ErrorMessage = null;
                try
                {
                    m_PrevVertexCount = GaussianFileReader.ReadFileHeader(m_InputFile);
                }
                catch (Exception ex)
                {
                    m_ErrorMessage = ex.Message;
                }

                m_PrevFileSize = File.Exists(m_InputFile) ? new FileInfo(m_InputFile).Length : 0;
                m_PrevFilePath = m_InputFile;
            }

            if (m_PrevVertexCount > 0)
                EditorGUILayout.LabelField("File Size", $"{EditorUtility.FormatBytes(m_PrevFileSize)} - {m_PrevVertexCount:N0} splats");
            else
                GUILayout.Space(EditorGUIUtility.singleLineHeight);

            EditorGUILayout.Space();
            GUILayout.Label("Output", EditorStyles.boldLabel);
            rect = EditorGUILayout.GetControlRect(true);
            string newOutputFolder = m_FilePicker.PathFieldGUI(rect, new GUIContent("Output Folder"), m_OutputFolder, null, "GaussianAssetOutputFolder");
            if (newOutputFolder != m_OutputFolder)
            {
                m_OutputFolder = newOutputFolder;
                EditorPrefs.SetString(kPrefOutputFolder, m_OutputFolder);
            }

            bool isSpz = !string.IsNullOrEmpty(m_InputFile) && m_InputFile.EndsWith(".spz", StringComparison.OrdinalIgnoreCase);
            if (isSpz)
            {
                var newSpzSource = (SpzSource)EditorGUILayout.EnumPopup("Source", m_SpzSource);
                if (newSpzSource != m_SpzSource)
                {
                    m_SpzSource = newSpzSource;
                    EditorPrefs.SetInt(kPrefSpzSource, (int)m_SpzSource);
                }
            }

            var newQuality = (GaussianSplatAssetProcessor.DataQuality)EditorGUILayout.EnumPopup("Quality", m_Quality);
            if (newQuality != m_Quality)
            {
                m_Quality = newQuality;
                EditorPrefs.SetInt(kPrefQuality, (int)m_Quality);
                ApplyQualityLevel();
                settings = GetImportSettings();
            }

            long sizePos = 0, sizeOther = 0, sizeCol = 0, sizeSHs = 0, totalSize = 0;
            if (m_PrevVertexCount > 0)
            {
                sizePos = GaussianSplatAsset.CalcPosDataSize(m_PrevVertexCount, settings.FormatPos);
                sizeOther = GaussianSplatAsset.CalcOtherDataSize(m_PrevVertexCount, settings.FormatScale);
                sizeCol = GaussianSplatAsset.CalcColorDataSize(m_PrevVertexCount, settings.FormatColor);
                sizeSHs = GaussianSplatAsset.CalcSHDataSize(m_PrevVertexCount, settings.FormatSH);
                long sizeChunk = settings.IsUsingChunks ? GaussianSplatAsset.CalcChunkDataSize(m_PrevVertexCount) : 0;
                totalSize = sizePos + sizeOther + sizeCol + sizeSHs + sizeChunk;
            }

            const float kSizeColWidth = 70;
            EditorGUI.BeginDisabledGroup(m_Quality != GaussianSplatAssetProcessor.DataQuality.Custom);
            EditorGUI.indentLevel++;
            GUILayout.BeginHorizontal();
            m_FormatPos = (GaussianSplatAsset.VectorFormat)EditorGUILayout.EnumPopup("Position", m_FormatPos);
            GUILayout.Label(sizePos > 0 ? EditorUtility.FormatBytes(sizePos) : string.Empty, GUILayout.Width(kSizeColWidth));
            GUILayout.EndHorizontal();
            GUILayout.BeginHorizontal();
            m_FormatScale = (GaussianSplatAsset.VectorFormat)EditorGUILayout.EnumPopup("Scale", m_FormatScale);
            GUILayout.Label(sizeOther > 0 ? EditorUtility.FormatBytes(sizeOther) : string.Empty, GUILayout.Width(kSizeColWidth));
            GUILayout.EndHorizontal();
            GUILayout.BeginHorizontal();
            m_FormatColor = (GaussianSplatAsset.ColorFormat)EditorGUILayout.EnumPopup("Color", m_FormatColor);
            GUILayout.Label(sizeCol > 0 ? EditorUtility.FormatBytes(sizeCol) : string.Empty, GUILayout.Width(kSizeColWidth));
            GUILayout.EndHorizontal();
            GUILayout.BeginHorizontal();
            m_FormatSH = (GaussianSplatAsset.SHFormat)EditorGUILayout.EnumPopup("SH", m_FormatSH);
            GUIContent shGC = new GUIContent();
            shGC.text = sizeSHs > 0 ? EditorUtility.FormatBytes(sizeSHs) : string.Empty;
            if (m_FormatSH >= GaussianSplatAsset.SHFormat.Cluster64k)
            {
                shGC.tooltip = "Note that SH clustering is not fast! (3-10 minutes for 6M splats)";
                shGC.image = EditorGUIUtility.IconContent("console.warnicon.sml").image;
            }
            GUILayout.Label(shGC, GUILayout.Width(kSizeColWidth));
            GUILayout.EndHorizontal();
            EditorGUI.indentLevel--;
            EditorGUI.EndDisabledGroup();
            if (totalSize > 0)
                EditorGUILayout.LabelField("Asset Size", $"{EditorUtility.FormatBytes(totalSize)} - {(double)m_PrevFileSize / totalSize:F2}x smaller");
            else
                GUILayout.Space(EditorGUIUtility.singleLineHeight);

            EditorGUILayout.Space();
            GUILayout.BeginHorizontal();
            GUILayout.Space(30);
            if (GUILayout.Button("Create Asset"))
            {
                CreateAsset();
            }
            GUILayout.Space(30);
            GUILayout.EndHorizontal();

            if (!string.IsNullOrWhiteSpace(m_ErrorMessage))
            {
                EditorGUILayout.HelpBox(m_ErrorMessage, MessageType.Error);
            }
        }

        void ApplyQualityLevel()
        {
            var settings = GetImportSettings();
            GaussianSplatAssetProcessor.ApplyQualityLevel(m_Quality, ref settings);
            SetImportSettings(settings);
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

        void SetImportSettings(GaussianSplatAssetProcessor.ImportSettings settings)
        {
            m_FormatPos = settings.FormatPos;
            m_FormatScale = settings.FormatScale;
            m_FormatColor = settings.FormatColor;
            m_FormatSH = settings.FormatSH;
        }

        static T CreateOrReplaceAsset<T>(T asset, string path) where T : UnityEngine.Object
        {
            T result = AssetDatabase.LoadAssetAtPath<T>(path);
            if (result == null)
            {
                AssetDatabase.CreateAsset(asset, path);
                result = asset;
            }
            else
            {
                if (typeof(Mesh).IsAssignableFrom(typeof(T))) { (result as Mesh)?.Clear(); }
                EditorUtility.CopySerialized(asset, result);
            }
            return result;
        }

        void CreateAsset()
        {
            m_ErrorMessage = null;
            if (string.IsNullOrWhiteSpace(m_InputFile))
            {
                m_ErrorMessage = "Select input PLY/SPZ file";
                return;
            }

            if (string.IsNullOrWhiteSpace(m_OutputFolder) || !m_OutputFolder.StartsWith("Assets/"))
            {
                m_ErrorMessage = $"Output folder must be within project, was '{m_OutputFolder}'";
                return;
            }
            Directory.CreateDirectory(m_OutputFolder);

            var settings = GetImportSettings();

            EditorUtility.DisplayProgressBar(kProgressTitle, "Reading data files", 0.0f);
            GaussianSplatAsset.CameraInfo[] cameras = GaussianSplatAssetProcessor.LoadJsonCamerasFile(m_InputFile, m_ImportCameras);
            using NativeArray<InputSplatData> inputSplats = LoadInputSplatFile(m_InputFile);
            if (inputSplats.Length == 0)
            {
                EditorUtility.ClearProgressBar();
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

            string baseName = Path.GetFileNameWithoutExtension(FilePickerControl.PathToDisplayString(m_InputFile));

            EditorUtility.DisplayProgressBar(kProgressTitle, "Creating data objects", 0.7f);
            GaussianSplatAsset asset = ScriptableObject.CreateInstance<GaussianSplatAsset>();
            asset.Initialize(inputSplats.Length, settings.FormatPos, settings.FormatScale, settings.FormatColor, settings.FormatSH, boundsMin, boundsMax, cameras);
            asset.name = baseName;

            var dataHash = new Hash128((uint)asset.splatCount, (uint)asset.formatVersion, 0, 0);
            string pathChunk = $"{m_OutputFolder}/{baseName}_chk.bytes";
            string pathPos = $"{m_OutputFolder}/{baseName}_pos.bytes";
            string pathOther = $"{m_OutputFolder}/{baseName}_oth.bytes";
            string pathCol = $"{m_OutputFolder}/{baseName}_col.bytes";
            string pathSh = $"{m_OutputFolder}/{baseName}_shs.bytes";

            bool useChunks = settings.IsUsingChunks;
            if (useChunks)
                GaussianSplatAssetProcessor.WriteBytesToFile(GaussianSplatAssetProcessor.CreateChunkBytes(inputSplats, ref dataHash), pathChunk);
            GaussianSplatAssetProcessor.WriteBytesToFile(GaussianSplatAssetProcessor.CreatePositionsBytes(inputSplats, settings.FormatPos, ref dataHash), pathPos);
            GaussianSplatAssetProcessor.WriteBytesToFile(GaussianSplatAssetProcessor.CreateOtherBytes(inputSplats, splatSHIndices, settings.FormatScale, ref dataHash), pathOther);
            GaussianSplatAssetProcessor.WriteBytesToFile(GaussianSplatAssetProcessor.CreateColorBytes(inputSplats, settings.FormatColor, ref dataHash), pathCol);
            GaussianSplatAssetProcessor.WriteBytesToFile(GaussianSplatAssetProcessor.CreateSHBytes(inputSplats, clusteredSHs, settings.FormatSH, ref dataHash), pathSh);
            asset.SetDataHash(dataHash);

            splatSHIndices.Dispose();
            clusteredSHs.Dispose();

            EditorUtility.DisplayProgressBar(kProgressTitle, "Initial texture import", 0.85f);
            AssetDatabase.Refresh(ImportAssetOptions.ForceUncompressedImport);

            EditorUtility.DisplayProgressBar(kProgressTitle, "Setup data onto asset", 0.95f);
            asset.SetAssetFiles(
                useChunks ? AssetDatabase.LoadAssetAtPath<TextAsset>(pathChunk) : null,
                AssetDatabase.LoadAssetAtPath<TextAsset>(pathPos),
                AssetDatabase.LoadAssetAtPath<TextAsset>(pathOther),
                AssetDatabase.LoadAssetAtPath<TextAsset>(pathCol),
                AssetDatabase.LoadAssetAtPath<TextAsset>(pathSh));

            var assetPath = $"{m_OutputFolder}/{baseName}.asset";
            var savedAsset = CreateOrReplaceAsset(asset, assetPath);

            EditorUtility.DisplayProgressBar(kProgressTitle, "Saving assets", 0.99f);
            AssetDatabase.SaveAssets();
            EditorUtility.ClearProgressBar();

            Selection.activeObject = savedAsset;
        }

        NativeArray<InputSplatData> LoadInputSplatFile(string filePath)
        {
            NativeArray<InputSplatData> data = default;
            if (!File.Exists(filePath))
            {
                m_ErrorMessage = $"Did not find {filePath} file";
                return data;
            }
            try
            {
                CoordinateSystem spzFrom = m_SpzSource == SpzSource.Marble
                    ? CoordinateSystem.LDF
                    : CoordinateSystem.RUB;
                GaussianFileReader.ReadFile(filePath, out data, spzFrom);
            }
            catch (Exception ex)
            {
                m_ErrorMessage = ex.Message;
            }
            return data;
        }
    }
}
