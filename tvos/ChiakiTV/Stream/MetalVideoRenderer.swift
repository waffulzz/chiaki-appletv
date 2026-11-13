// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import CoreVideo
import Metal
import QuartzCore

/// Draws decoded NV12 frames straight into a CAMetalLayer, presenting each one as soon as it is
/// decoded. Unlike AVSampleBufferDisplayLayer, nothing here can queue frames: at most one is
/// waiting for the next screen refresh.
final class MetalVideoRenderer {
	let layer = CAMetalLayer()

	private let device: MTLDevice
	private let queue: MTLCommandQueue
	private let pipeline: MTLRenderPipelineState
	private var textureCache: CVMetalTextureCache?

	/// Decoder output format this renderer expects.
	static let pixelBufferAttributes: [CFString: Any] = [
		kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
		kCVPixelBufferMetalCompatibilityKey: true,
		kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
	]

	init?() {
		guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
		self.device = device
		self.queue = queue
		do {
			let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
			let descriptor = MTLRenderPipelineDescriptor()
			descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
			descriptor.fragmentFunction = library.makeFunction(name: "fragmentNV12")
			descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
			pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
		} catch {
			LogStore.shared.append(level: 1, "Metal renderer setup failed: \(error)")
			return nil
		}
		CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

		layer.device = device
		layer.pixelFormat = .bgra8Unorm
		layer.framebufferOnly = true
		layer.maximumDrawableCount = 2 // fewest frames in flight
		layer.allowsNextDrawableTimeout = true
		layer.presentsWithTransaction = false
		layer.backgroundColor = CGColor(gray: 0, alpha: 1)
	}

	/// Call on the main thread when the layer's size changes.
	func layout(bounds: CGRect, scale: CGFloat) {
		layer.frame = bounds
		layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
	}

	/// Called on chiaki's video thread for every decoded frame.
	func render(_ pixelBuffer: CVPixelBuffer) {
		guard let textureCache, CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return }
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		guard let luma = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm, cache: textureCache),
		      let chroma = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm, cache: textureCache),
		      let lumaTexture = CVMetalTextureGetTexture(luma),
		      let chromaTexture = CVMetalTextureGetTexture(chroma),
		      let drawable = layer.nextDrawable(),
		      let commandBuffer = queue.makeCommandBuffer() else { return }

		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = drawable.texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		pass.colorAttachments[0].storeAction = .store
		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

		// Aspect fit
		let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
		let scale = min(target.width / CGFloat(width), target.height / CGFloat(height))
		let w = CGFloat(width) * scale, h = CGFloat(height) * scale
		encoder.setViewport(MTLViewport(originX: Double((target.width - w) / 2), originY: Double((target.height - h) / 2),
			width: Double(w), height: Double(h), znear: 0, zfar: 1))
		encoder.setRenderPipelineState(pipeline)
		encoder.setFragmentTexture(lumaTexture, index: 0)
		encoder.setFragmentTexture(chromaTexture, index: 1)
		encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		encoder.endEncoding()

		commandBuffer.present(drawable)
		// Keep the CVMetalTextures (and so the decoded frame) alive until the GPU is done
		commandBuffer.addCompletedHandler { _ in _ = luma; _ = chroma }
		commandBuffer.commit()
	}

	private func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
		var texture: CVMetalTexture?
		CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, format,
			CVPixelBufferGetWidthOfPlane(pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &texture)
		return texture
	}

	/// BT.709 limited range YCbCr to RGB, which is what the console sends for SDR.
	private static let shaderSource = """
	#include <metal_stdlib>
	using namespace metal;

	struct VertexOut {
		float4 position [[position]];
		float2 uv;
	};

	vertex VertexOut vertexMain(uint vid [[vertex_id]]) {
		const float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
		const float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
		VertexOut out;
		out.position = float4(positions[vid], 0, 1);
		out.uv = uvs[vid];
		return out;
	}

	fragment float4 fragmentNV12(VertexOut in [[stage_in]],
			texture2d<float> luma [[texture(0)]],
			texture2d<float> chroma [[texture(1)]]) {
		constexpr sampler s(filter::linear, address::clamp_to_edge);
		float y = (luma.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
		float2 c = (chroma.sample(s, in.uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
		float3 rgb = float3(y + 1.5748 * c.y,
			y - 0.1873 * c.x - 0.4681 * c.y,
			y + 1.8556 * c.x);
		return float4(saturate(rgb), 1.0);
	}
	"""
}
