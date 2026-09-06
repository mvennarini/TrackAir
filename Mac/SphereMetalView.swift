import SwiftUI
import MetalKit

/// Sfera di vetro renderizzata in Metal (vedi SphereShaders.metal) in una
/// vista trasparente, cosi' fuori dalla sfera si vede il desktop.
struct SphereMetalView: NSViewRepresentable {
    var active: Bool
    var success: Bool

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.framebufferOnly = true
        v.preferredFramesPerSecond = 60
        v.isPaused = !active
        v.enableSetNeedsDisplay = false
        v.wantsLayer = true
        v.layer?.isOpaque = false
        (v.layer as? CAMetalLayer)?.isOpaque = false
        let r = SphereRenderer(view: v)
        r?.success = success
        v.delegate = r
        context.coordinator.renderer = r
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        v.isPaused = !active
        context.coordinator.renderer?.success = success
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: SphereRenderer? }
}

struct SphereUniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var success: Float
}

final class SphereRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let start = CACurrentMediaTime()
    var success = false
    private var successLevel: Float = 0

    init?(view: MTKView) {
        // Shader compilato a runtime dal sorgente in Resources: cosi' la build non
        // richiede il Metal Toolchain e lo shader si puo' ritoccare senza ricompilare.
        guard let device = view.device, let q = device.makeCommandQueue(),
              let url = Bundle.main.url(forResource: "SphereShaders.metal", withExtension: "txt"),
              let src = try? String(contentsOf: url, encoding: .utf8),
              let lib = try? device.makeLibrary(source: src, options: nil) else { return nil }
        queue = q
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sphere_vertex")
        d.fragmentFunction = lib.makeFunction(name: "sphere_fragment")
        d.colorAttachments[0].pixelFormat = view.colorPixelFormat
        // il fragment restituisce colore premoltiplicato
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipeline = p
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        // transizione morbida verso lo stato "abbinato"
        successLevel += ((success ? 1 : 0) - successLevel) * 0.05
        var u = SphereUniforms(time: Float(CACurrentMediaTime() - start),
                               resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                               success: successLevel)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<SphereUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
