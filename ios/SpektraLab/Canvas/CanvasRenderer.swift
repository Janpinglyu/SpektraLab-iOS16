//  CanvasRenderer.swift — the engine's picture on the screen.
//
//  The iOS session asks the engine for gamma-encoded sRGB `RGBA16Unorm`, the
//  same output contract as the desktop preview host. This file draws that
//  texture into an sRGB drawable without applying another colour transform.

import Foundation
import Metal
import MetalKit
import UIKit

/// The matrices that take the working space to the display, as the engine
/// hands them over.
struct OutputTransform {
    /// Source linear RGB → target linear RGB, row-major.
    let matrix: [Float]
    /// The transfer function's mode on each side, as `shaders/nodes.metal`
    /// numbers them.
    let sourceCCTFMode: Int
    let targetCCTFMode: Int
    /// The CAM16-UCS gamut compression, when it is on.
    let gamutCompressConsts: [Float]
    let gamutCompressActive: Bool

    /// The identity: an sRGB engine result to the sRGB drawable.
    static let identity = OutputTransform(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                                          sourceCCTFMode: 0, targetCCTFMode: 0,
                                          gamutCompressConsts: [], gamutCompressActive: false)
}

/// Draws the engine's texture into an `MTKView`.
@MainActor
final class CanvasRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// The texture to draw. Set by the view model when a render lands.
    private(set) var texture: MTLTexture?

    /// The engine's output is transfer-encoded sRGB, matching the macOS
    /// preview host. The Metal drawable is tagged with the same space, so the
    /// canvas must not apply a second ProPhoto or gamma transform.
    var transform: OutputTransform = .identity

    /// The transform's parameters, uploaded to the GPU once per change.
    private var transformBuffer: MTLBuffer?
    /// The aspect-fit rectangle. It is a separate binding instead of a tail
    /// field in `transformBuffer`: the MSL and Swift struct layouts must agree
    /// byte for byte, and a mismatch there silently shrinks or clips the
    /// picture rather than producing a visible shader error.
    private var frameBuffer: MTLBuffer?
    private var sourceAspect: CGFloat?
    private var drawableAspect: CGFloat = 2.0 / 3.0
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        // The shader is compiled from source at launch: one small file, and it
        // keeps the app's own drawing code out of the engine's build (which
        // compiles its kernels with safe-math and must not inherit the app's
        // fast-math setting — RFC-014 §5.1 trap 1).
        //
        // `makeDefaultLibrary` **throws** and is not optional on iOS: it
        // returns `any MTLLibrary` and raises an Objective-C exception when
        // the metallib is missing, which Swift cannot catch. So it is called
        // with `try` and the do/catch turns the failure into "no renderer",
        // which the view model already knows how to report.
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            return nil
        }
        guard let vertex = library.makeFunction(name: "canvasVertex"),
              let fragment = library.makeFunction(name: "canvasFragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        // Must equal the MTKView's `colorPixelFormat`. The MTKView default is
        // `.bgra8Unorm`; the shader already outputs clamped sRGB-encoded
        // values, so an 8-bit unorm drawable is correct. If you want an
        // HDR/`rgba16Float` drawable instead, set `view.colorPixelFormat`
        // to match — do NOT leave them mismatched.
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipeline = state

        // The transform's uniforms: the 3×3 matrix, the two modes, and the
        // gamut-compression constants the fragment shader reads.
        let buffer = device.makeBuffer(length: 256, options: .storageModeShared)
        transformBuffer = buffer
        frameBuffer = device.makeBuffer(length: 16, options: .storageModeShared)
        super.init()
        uploadTransform()
    }

    /// The texture to show.
    func setTexture(_ texture: MTLTexture?) {
        self.texture = texture
        sourceAspect = texture.map { CGFloat($0.width) / CGFloat($0.height) }
        uploadTransform()
    }

    /// Update the viewport without changing the rendered pixels. `pan` is in
    /// view points; it is converted to normalized Metal coordinates here.
    func setViewport(zoom: CGFloat, pan: CGPoint, size: CGSize) {
        self.zoom = min(max(zoom, 1), 4)
        self.pan = CGPoint(x: size.width > 0 ? pan.x * 2 / size.width : 0,
                           y: size.height > 0 ? -pan.y * 2 / size.height : 0)
        if size.height > 0 { drawableAspect = size.width / size.height }
        uploadFrame()
    }

    /// The working space → display transform.
    func setTransform(_ transform: OutputTransform) {
        self.transform = transform
        uploadTransform()
    }

    /// Copy the transform into the shared buffer the shader reads.
    private func uploadTransform() {
        guard let buffer = transformBuffer else { return }
        struct Params {
            var matrix = SIMD3<Float>(1, 0, 0)
            var row2 = SIMD3<Float>(0, 1, 0)
            var row3 = SIMD3<Float>(0, 0, 1)
            var sourceMode: UInt32 = 0
            var targetMode: UInt32 = 0
            var gamutActive: UInt32 = 0
            var padding = SIMD3<UInt32>(0, 0, 0)
        }
        var params = Params()
        let m = transform.matrix
        if m.count >= 9 {
            // `transform.matrix` is row-major, but Metal's `float3x3` is column-
            // major. Upload each *column* of the matrix as the intended *row*, so
            // that `matrix * v` in the shader computes M·v and not Mᵀ·v. Writing
            // the three rows verbatim would make Metal read them as three columns
            // and transpose the grade (wrong hue/contrast).
            params.matrix = SIMD3(m[0], m[3], m[6])
            params.row2   = SIMD3(m[1], m[4], m[7])
            params.row3   = SIMD3(m[2], m[5], m[8])
        }
        params.sourceMode = UInt32(transform.sourceCCTFMode)
        params.targetMode = UInt32(transform.targetCCTFMode)
        params.gamutActive = transform.gamutCompressActive ? 1 : 0
        memcpy(buffer.contents(), &params, MemoryLayout<Params>.size)
        uploadFrame()
    }

    /// Copy an aspect-preserving source frame to the shader constants. The
    /// actual MTKView aspect is used, so portrait, landscape and square photos
    /// all fit instead of being sampled through a fixed 2:3 window.
    private func uploadFrame() {
        guard let frameBuffer, let aspect = sourceAspect, aspect > 0 else { return }
        // Half-extents in normalized device coordinates. The full NDC range
        // is -1...1, so a full-width frame has a half-width of 1, not 0.5.
        // Starting these at 1 and then dividing the frame by two again drew
        // every photo at exactly half size in the centre of the canvas.
        var halfWidth = CGFloat(1)
        var halfHeight = CGFloat(1)
        // NDC spans two units on each axis, while the view has a physical
        // aspect ratio. A wide photo therefore fills x and is letterboxed on
        // y; a tall photo fills y and is pillarboxed on x. This used to be
        // reversed, which drew every landscape frame as a narrow vertical
        // strip through the centre of the screen.
        if aspect > drawableAspect {
            halfHeight = drawableAspect / aspect
        } else {
            halfWidth = aspect / drawableAspect
        }
        halfWidth *= zoom
        halfHeight *= zoom
        // Keep an edge of the photograph on every side while zoomed. Without
        // this, a drag can move the whole frame off-screen and leave only the
        // black canvas, with no way to tell whether the photo is still there.
        let maxPanX = max(0, halfWidth - 1)
        let maxPanY = max(0, halfHeight - 1)
        let panX = min(max(pan.x, -maxPanX), maxPanX)
        let panY = min(max(pan.y, -maxPanY), maxPanY)
        let frame = SIMD4<Float>(Float(panX - halfWidth), Float(panX + halfWidth),
                                 Float(panY - halfHeight), Float(panY + halfHeight))
#if DEBUG
        if ProcessInfo.processInfo.environment["SPEKTRAFILM_CANVAS_LOG"] == "1" {
            NSLog("SpektraLab canvas frame=%@ sourceAspect=%.4f drawableAspect=%.4f",
                  NSCoder.string(for: CGRect(x: CGFloat(frame.x), y: CGFloat(frame.z),
                                             width: CGFloat(frame.y - frame.x),
                                             height: CGFloat(frame.w - frame.z))),
                  aspect, drawableAspect)
        }
#endif
        withUnsafeBytes(of: frame) { bytes in
            frameBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.height > 0 else { return }
        drawableAspect = size.width / size.height
        uploadFrame()
    }

    func draw(in view: MTKView) {
#if DEBUG
        if ProcessInfo.processInfo.environment["SPEKTRAFILM_CANVAS_LOG"] == "1" {
            NSLog("SpektraLab canvas draw bounds=%@ drawable=%@ sourceAspect=%.4f drawableAspect=%.4f zoom=%.3f pan=%.3f,%.3f",
                  NSCoder.string(for: view.bounds),
                  NSCoder.string(for: view.drawableSize),
                  sourceAspect ?? -1,
                  drawableAspect,
                  zoom, pan.x, pan.y)
            NSLog("SpektraLab canvas layer bounds=%@ scale=%.3f super=%@ contentsRect=%@",
                  NSCoder.string(for: view.layer.bounds),
                  view.layer.contentsScale,
                  view.superview.map { NSCoder.string(for: $0.bounds) } ?? "nil",
                  NSCoder.string(for: view.layer.contentsRect))
            if let root = view.window?.rootViewController?.view {
                var found: [String] = []
                func visit(_ v: UIView, _ depth: Int) {
                    if let metal = v as? MTKView {
                        found.append("d\(depth):\(NSCoder.string(for: metal.frame)) drawable=\(NSCoder.string(for: metal.drawableSize))")
                    }
                    for child in v.subviews { visit(child, depth + 1) }
                }
                visit(root, 0)
                NSLog("SpektraLab canvas MTKViews=%@", found.joined(separator: " | "))
            }
        }
#endif
        if view.drawableSize.height > 0 {
            let aspect = view.drawableSize.width / view.drawableSize.height
            if abs(aspect - drawableAspect) > 0.001 {
                drawableAspect = aspect
                uploadFrame()
            }
        }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let texture,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        if let transformBuffer {
            encoder.setFragmentBuffer(transformBuffer, offset: 0, index: 0)
        }
        if let frameBuffer {
            encoder.setFragmentBuffer(frameBuffer, offset: 0, index: 1)
        }
        // A full-screen triangle: three vertices, no vertex buffer, no index
        // buffer. The vertex shader positions them from `vertex_id`.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
