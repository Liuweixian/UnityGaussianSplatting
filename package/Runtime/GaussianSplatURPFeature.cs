// SPDX-License-Identifier: MIT
#if GS_ENABLE_URP

#if UNITY_6000_0_OR_NEWER
using UnityEngine.Rendering.RenderGraphModule;
#endif

using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace GaussianSplatting.Runtime
{
    // Note: I have no idea what is the purpose of ScriptableRendererFeature vs ScriptableRenderPass, which one of those
    // is supposed to do resource management vs logic, etc. etc. Code below "seems to work" but I'm just fumbling along,
    // without understanding any of it.
    //
    // ReSharper disable once InconsistentNaming
    class GaussianSplatURPFeature : ScriptableRendererFeature
    {
#if UNITY_6000_0_OR_NEWER
        class GSRenderPass : ScriptableRenderPass
        {
            const string GaussianSplatRTName = "_GaussianSplatRT";

            const string ProfilerTag = "GaussianSplatRenderGraph";
            static readonly ProfilingSampler s_profilingSampler = new(ProfilerTag);
            static readonly int s_gaussianSplatRT = Shader.PropertyToID(GaussianSplatRTName);

            class PassData
            {
                internal UniversalCameraData CameraData;
                internal TextureHandle SourceTexture;
                internal TextureHandle SourceDepth;
                internal TextureHandle GaussianSplatRT;
            }

            public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
            {
                using var builder = renderGraph.AddUnsafePass(ProfilerTag, out PassData passData);

                var cameraData = frameData.Get<UniversalCameraData>();
                var resourceData = frameData.Get<UniversalResourceData>();

                RenderTextureDescriptor rtDesc = cameraData.cameraTargetDescriptor;
                rtDesc.depthBufferBits = 0;
                rtDesc.msaaSamples = 1;
                rtDesc.graphicsFormat = GraphicsFormat.R16G16B16A16_SFloat;
                var textureHandle = UniversalRenderer.CreateRenderGraphTexture(renderGraph, rtDesc, GaussianSplatRTName, true);

                passData.CameraData = cameraData;
                passData.SourceTexture = resourceData.activeColorTexture;
                passData.SourceDepth = resourceData.activeDepthTexture;
                passData.GaussianSplatRT = textureHandle;

                builder.UseTexture(resourceData.activeColorTexture, AccessFlags.ReadWrite);
                builder.UseTexture(resourceData.activeDepthTexture);
                builder.UseTexture(textureHandle, AccessFlags.Write);
                builder.AllowPassCulling(false);
                builder.SetRenderFunc(static (PassData data, UnsafeGraphContext context) =>
                {
                    var commandBuffer = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);
                    using var _ = new ProfilingScope(commandBuffer, s_profilingSampler);
                    commandBuffer.SetGlobalTexture(s_gaussianSplatRT, data.GaussianSplatRT);
                    CoreUtils.SetRenderTarget(commandBuffer, data.GaussianSplatRT, data.SourceDepth, ClearFlag.Color, Color.clear);
                    Material matComposite = GaussianSplatRenderSystem.instance.SortAndRenderSplats(data.CameraData.camera, commandBuffer);
                    commandBuffer.BeginSample(GaussianSplatRenderSystem.s_ProfCompose);
                    Blitter.BlitCameraTexture(commandBuffer, data.GaussianSplatRT, data.SourceTexture, matComposite, 0);
                    commandBuffer.EndSample(GaussianSplatRenderSystem.s_ProfCompose);
                });
            }
        }
#else
        // Unity 2022.3 (URP 14.x) implementation using classic Execute-based ScriptableRenderPass
        class GSRenderPass : ScriptableRenderPass
        {
            static readonly int s_GaussianSplatRT = Shader.PropertyToID("_GaussianSplatRT");

            ScriptableRenderer m_Renderer;
            RenderTargetHandle m_GaussianSplatRT;
            RenderTargetIdentifier m_ColorTarget;
            RenderTargetIdentifier m_DepthTarget;

            public GSRenderPass()
            {
                m_GaussianSplatRT.Init("_GaussianSplatRT");
            }

            public void Setup(ScriptableRenderer renderer)
            {
                m_Renderer = renderer;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                // Camera targets must be accessed within ScriptableRenderPass scope
                m_ColorTarget = m_Renderer.cameraColorTarget;
                m_DepthTarget = m_Renderer.cameraDepthTarget;

                var desc = renderingData.cameraData.cameraTargetDescriptor;
                desc.depthBufferBits = 0;
                desc.msaaSamples = 1;
                desc.graphicsFormat = GraphicsFormat.R16G16B16A16_SFloat;
                cmd.GetTemporaryRT(m_GaussianSplatRT.id, desc, FilterMode.Point);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                var camera = renderingData.cameraData.camera;
                var system = GaussianSplatRenderSystem.instance;

                var cmd = CommandBufferPool.Get("GaussianSplatURP");
                {
                    cmd.SetGlobalTexture(s_GaussianSplatRT, m_GaussianSplatRT.Identifier());
                    CoreUtils.SetRenderTarget(cmd, m_GaussianSplatRT.Identifier(), m_DepthTarget, ClearFlag.Color, Color.clear);

                    Material matComposite = system.SortAndRenderSplats(camera, cmd);

                    // Composite onto camera color target using DrawProcedural (matches BiRP pattern)
                    cmd.BeginSample(GaussianSplatRenderSystem.s_ProfCompose);
                    cmd.SetRenderTarget(m_ColorTarget);
                    cmd.DrawProcedural(Matrix4x4.identity, matComposite, 0, MeshTopology.Triangles, 3, 1);
                    cmd.EndSample(GaussianSplatRenderSystem.s_ProfCompose);
                }

                context.ExecuteCommandBuffer(cmd);
                CommandBufferPool.Release(cmd);
            }

            public override void OnCameraCleanup(CommandBuffer cmd)
            {
                cmd.ReleaseTemporaryRT(m_GaussianSplatRT.id);
            }
        }
#endif

        GSRenderPass m_Pass;
#if UNITY_6000_0_OR_NEWER
        bool m_HasCamera;
#endif

        public override void Create()
        {
            m_Pass = new GSRenderPass
            {
                renderPassEvent = RenderPassEvent.BeforeRenderingTransparents
            };
        }

#if UNITY_6000_0_OR_NEWER
        public override void OnCameraPreCull(ScriptableRenderer renderer, in CameraData cameraData)
        {
            m_HasCamera = false;
            var system = GaussianSplatRenderSystem.instance;
            if (!system.GatherSplatsForCamera(cameraData.camera))
                return;

            m_HasCamera = true;
        }
#endif

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
#if UNITY_6000_0_OR_NEWER
            if (!m_HasCamera)
                return;
#else
            // In Unity 2022.3, OnCameraPreCull is not available with CameraData,
            // so check for valid splats here
            var system = GaussianSplatRenderSystem.instance;
            if (!system.GatherSplatsForCamera(renderingData.cameraData.camera))
                return;
            m_Pass.Setup(renderer);
#endif
            renderer.EnqueuePass(m_Pass);
        }

        protected override void Dispose(bool disposing)
        {
            m_Pass = null;
        }
    }
}

#endif // #if GS_ENABLE_URP
