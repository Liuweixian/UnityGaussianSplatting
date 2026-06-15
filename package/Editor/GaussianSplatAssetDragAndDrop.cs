// SPDX-License-Identifier: MIT

using GaussianSplatting.Runtime;
using UnityEditor;
using UnityEngine;
using System.Collections.Generic;

namespace GaussianSplatting.Editor
{
    /// <summary>
    /// Handles drag-and-drop of GaussianSplatAsset files into the hierarchy or scene view.
    /// Automatically creates a GameObject with GaussianSplatRenderer component and all shader resources.
    /// </summary>
    [InitializeOnLoad]
    public static class GaussianSplatAssetDragAndDrop
    {
        // Shader GUIDs from package/Shaders/
        static readonly string s_ShaderSplatsGuid = "ed800126ae8844a67aad1974ddddd59c";
        static readonly string s_ShaderCompositeGuid = "7e184af7d01193a408eb916d8acafff9";
        static readonly string s_ShaderDebugPointsGuid = "b44409fc67214394f8f47e4e2648425e";
        static readonly string s_ShaderDebugBoxesGuid = "4006f2680fd7c8b4cbcb881454c782be";
        static readonly string s_CSSplatUtilitiesGuid = "ec84f78b836bd4f96a105d6b804f08bd";
        static readonly string s_CSSplatCalcViewPath = "829C72C180644AE3AF769BE869F12FD8";

        static GaussianSplatAssetDragAndDrop()
        {
            // Adds a callback for when the hierarchy window processes GUI events
            EditorApplication.hierarchyWindowItemOnGUI += HandleHierarchyDragAndDrop;
        }

        static void HandleHierarchyDragAndDrop(int instanceID, Rect rect)
        {
            // Happens when an acceptable item is released over the GUI window
            if (Event.current.type == EventType.DragPerform)
            {
                // Get all the drag and drop information ready for processing
                DragAndDrop.AcceptDrag();
                
                // Used to emulate selection of new objects
                var selectedObjects = new List<GameObject>();
                
                // Run through each object that was dragged in
                foreach (var objectRef in DragAndDrop.objectReferences)
                {
                    // If the object is a GaussianSplatAsset
                    if (objectRef is GaussianSplatAsset asset)
                    {
                        var gameObject = CreateGaussianSplatObject(asset);
                        selectedObjects.Add(gameObject);
                    }
                }
                
                // We didn't drag any GaussianSplatAsset files, so do nothing
                if (selectedObjects.Count == 0) return;
                
                // Emulate selection of newly created objects
                Selection.objects = selectedObjects.ToArray();
                
                // Make sure this call is the only one that processes the event
                Event.current.Use();
            }
            
            // Handle DragUpdated to show proper cursor feedback
            if (Event.current.type == EventType.DragUpdated)
            {
                bool hasGaussianAsset = false;
                foreach (var objectRef in DragAndDrop.objectReferences)
                {
                    if (objectRef is GaussianSplatAsset)
                    {
                        hasGaussianAsset = true;
                        break;
                    }
                }
                
                if (hasGaussianAsset)
                {
                    DragAndDrop.visualMode = DragAndDropVisualMode.Copy;
                    Event.current.Use();
                }
            }
        }

        static GameObject CreateGaussianSplatObject(GaussianSplatAsset asset)
        {
            // Create new GameObject
            var go = new GameObject(asset.name);
            
            // Add GaussianSplatRenderer component
            var renderer = go.AddComponent<GaussianSplatRenderer>();
            
            // Assign the asset
            renderer.m_Asset = asset;
            
            // Auto-assign shader resources
            renderer.m_ShaderSplats = LoadShader(s_ShaderSplatsGuid);
            renderer.m_ShaderComposite = LoadShader(s_ShaderCompositeGuid);
            renderer.m_ShaderDebugPoints = LoadShader(s_ShaderDebugPointsGuid);
            renderer.m_ShaderDebugBoxes = LoadShader(s_ShaderDebugBoxesGuid);
            renderer.m_CSSplatUtilities = LoadComputeShader(s_CSSplatUtilitiesGuid);
            renderer.m_CSSplatCalcView = LoadComputeShader(s_CSSplatCalcViewPath);
            
            // Position at origin
            go.transform.position = Vector3.zero;
            
            // Position Camera.main: use camera data from asset, or fall back to bounds framing
            var mainCam = Camera.main;
            if (mainCam != null)
            {
                if (asset.cameras != null && asset.cameras.Length > 0)
                {
                    var cam = asset.cameras[0];
                    var camTr = mainCam.transform;
                    var prevParent = camTr.parent;
                    camTr.parent = go.transform;
                    camTr.localPosition = cam.pos;
                    camTr.localRotation = Quaternion.LookRotation(cam.axisZ, cam.axisY);
                    camTr.parent = prevParent;
                    camTr.localScale = Vector3.one;
                    EditorUtility.SetDirty(camTr);
                }
                else
                {
                    var bounds = new Bounds();
                    bounds.SetMinMax(asset.boundsMin, asset.boundsMax);
                    if (bounds.extents != Vector3.zero)
                    {
                        mainCam.transform.position = bounds.center + Vector3.back * bounds.size.magnitude;
                        mainCam.transform.LookAt(bounds.center);
                    }
                }
            }
            
            Debug.Log($"Created Gaussian Splat object '{go.name}' with {asset.splatCount:N0} splats");
            return go;
        }

        static Shader LoadShader(string guid)
        {
            var path = AssetDatabase.GUIDToAssetPath(guid);
            if (!string.IsNullOrEmpty(path))
            {
                return AssetDatabase.LoadAssetAtPath<Shader>(path);
            }
            return null;
        }

        static ComputeShader LoadComputeShader(string guid)
        {
            var path = AssetDatabase.GUIDToAssetPath(guid);
            if (!string.IsNullOrEmpty(path))
            {
                return AssetDatabase.LoadAssetAtPath<ComputeShader>(path);
            }
            return null;
        }
    }
}
