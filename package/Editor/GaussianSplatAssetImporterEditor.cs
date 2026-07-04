// SPDX-License-Identifier: MIT

using GaussianSplatting.Editor.Utils;
using GaussianSplatting.Runtime;
using UnityEditor;
using UnityEditor.AssetImporters;
using UnityEngine;

namespace GaussianSplatting.Editor
{
    [CustomEditor(typeof(GaussianSplatAssetImporter))]
    [CanEditMultipleObjects]
    public class GaussianSplatAssetImporterEditor : ScriptedImporterEditor
    {
        SerializedProperty m_QualityProp;
        SerializedProperty m_ImportCamerasProp;
        SerializedProperty m_SpzSourceProp;
        SerializedProperty m_FormatPosProp;
        SerializedProperty m_FormatScaleProp;
        SerializedProperty m_FormatColorProp;
        SerializedProperty m_FormatSHProp;

        public override void OnEnable()
        {
            base.OnEnable();
            m_QualityProp = serializedObject.FindProperty("m_Quality");
            m_ImportCamerasProp = serializedObject.FindProperty("m_ImportCameras");
            m_SpzSourceProp = serializedObject.FindProperty("m_SpzSource");
            m_FormatPosProp = serializedObject.FindProperty("m_FormatPos");
            m_FormatScaleProp = serializedObject.FindProperty("m_FormatScale");
            m_FormatColorProp = serializedObject.FindProperty("m_FormatColor");
            m_FormatSHProp = serializedObject.FindProperty("m_FormatSH");
        }

        public override void OnInspectorGUI()
        {
            serializedObject.Update();

            var prevQuality = (GaussianSplatAssetProcessor.DataQuality)m_QualityProp.intValue;

            // Source dropdown (SPZ only)
            var importer = (GaussianSplatAssetImporter)target;
            if (importer.assetPath.EndsWith(".spz", System.StringComparison.OrdinalIgnoreCase))
            {
                EditorGUILayout.PropertyField(m_SpzSourceProp, new GUIContent("Source"));
            }

            // Quality preset dropdown
            EditorGUILayout.PropertyField(m_QualityProp, new GUIContent("Quality"));

            var quality = (GaussianSplatAssetProcessor.DataQuality)m_QualityProp.intValue;

            // When quality changes to a preset, update format fields to reflect the preset
            if (quality != prevQuality && quality != GaussianSplatAssetProcessor.DataQuality.Custom)
            {
                var settings = new GaussianSplatAssetProcessor.ImportSettings
                {
                    FormatPos = (GaussianSplatAsset.VectorFormat)m_FormatPosProp.intValue,
                    FormatScale = (GaussianSplatAsset.VectorFormat)m_FormatScaleProp.intValue,
                    FormatColor = (GaussianSplatAsset.ColorFormat)m_FormatColorProp.intValue,
                    FormatSH = (GaussianSplatAsset.SHFormat)m_FormatSHProp.intValue,
                };
                GaussianSplatAssetProcessor.ApplyQualityLevel(quality, ref settings);
                m_FormatPosProp.intValue = (int)settings.FormatPos;
                m_FormatScaleProp.intValue = (int)settings.FormatScale;
                m_FormatColorProp.intValue = (int)settings.FormatColor;
                m_FormatSHProp.intValue = (int)settings.FormatSH;
            }

            // When Custom: show individual format overrides
            EditorGUI.BeginDisabledGroup(quality != GaussianSplatAssetProcessor.DataQuality.Custom);
            EditorGUI.indentLevel++;

            // Show format dropdowns with estimated sizes
            EditorGUILayout.PropertyField(m_FormatPosProp, new GUIContent("Position"));
            EditorGUILayout.PropertyField(m_FormatScaleProp, new GUIContent("Scale"));
            EditorGUILayout.PropertyField(m_FormatColorProp, new GUIContent("Color"));
            EditorGUILayout.PropertyField(m_FormatSHProp, new GUIContent("SH"));

            EditorGUI.indentLevel--;
            EditorGUI.EndDisabledGroup();

            // Import cameras toggle
            EditorGUILayout.PropertyField(m_ImportCamerasProp, new GUIContent("Import Cameras"));

            serializedObject.ApplyModifiedProperties();

            // Apply/Revert buttons from base class
            ApplyRevertGUI();
        }
    }
}
