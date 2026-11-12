//  ImageDecoder.swift — a photo in, the engine's pixels out.
//
//  Core Image is the primary decoder on iOS. The app also compiles the
//  engine's LibRaw compatibility path as a fallback for formats Core Image
//  refuses or only exposes as an embedded thumbnail. This file runs both and
//  hands the engine one consistent linear ProPhoto frame.
//
//  **The engine wants ProPhoto RGB, linear.** Core Image converts directly
//  from the source profile into the same calibrated float working space used
//  by Mac 1.3.5. There is deliberately no 8-bit sRGB intermediate.
//
//  The RAW path is the reason this file exists at all: ImageIO can decode
//  DNG, and most camera formats on recent iOS, but support varies by format
//  and by iOS version. A frame that ImageIO cannot read is reported as such
//  rather than silently rendered wrong.

import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Tightly packed float32 RGB pixels.
///
/// Core Image's path already produces a `[Float]`; LibRaw hands us an NSData
/// that already owns the decoded frame. Keeping both behind one accessor lets
/// the LibRaw fallback avoid a second full-resolution copy on the way from
/// the decoder to the engine.
struct FloatRGBPixels: @unchecked Sendable {
    /// Owns a frame returned by the LibRaw bridge. The C layer keeps the
    /// vector alive until `SPKLibRawFrameFree`, so the pixels can go to the
    /// engine without a full-resolution Swift array copy.
    private final class LibRawOwner: @unchecked Sendable {
        let frame: SPKLibRawFrameRef
        let count: Int

        init(frame: SPKLibRawFrameRef, count: Int) {
            self.frame = frame
            self.count = count
        }

        deinit {
            SPKLibRawFrameFree(frame)
        }

        func withUnsafeBufferPointer<T>(
            _ body: (UnsafeBufferPointer<Float>) throws -> T
        ) rethrows -> T {
            guard let pixels = SPKLibRawFramePixels(frame) else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            return try body(UnsafeBufferPointer(start: pixels, count: count))
        }
    }

    private enum Storage {
        case floats([Float])
        case data(Data)
        case libraw(LibRawOwner)
    }

    private let storage: Storage
    let count: Int

    init(_ floats: [Float]) {
        storage = .floats(floats)
        count = floats.count
    }

    init(data: Data, pixelCount: Int) {
        storage = .data(data)
        count = pixelCount
    }

    init(librawFrame: SPKLibRawFrameRef, pixelCount: Int) {
        storage = .libraw(LibRawOwner(frame: librawFrame, count: pixelCount))
        count = pixelCount
    }

    func withUnsafeBufferPointer<T>(
        _ body: (UnsafeBufferPointer<Float>) throws -> T
    ) rethrows -> T {
        switch storage {
        case .floats(let floats):
            return try floats.withUnsafeBufferPointer(body)
        case .data(let data):
            return try data.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                return try body(UnsafeBufferPointer(start: floats.baseAddress, count: count))
            }
        case .libraw(let owner):
            return try owner.withUnsafeBufferPointer(body)
        }
    }

    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        switch storage {
        case .floats(let floats):
            return try floats.withUnsafeBytes(body)
        case .data(let data):
            return try data.withUnsafeBytes(body)
        case .libraw(let owner):
            return try owner.withUnsafeBufferPointer { floats in
                try body(UnsafeRawBufferPointer(floats))
            }
        }
    }
}

/// A decoded frame, in the engine's input space.
struct DecodedFrame: @unchecked Sendable {
    /// Tightly packed float32, three channels, top row first.
    let pixels: FloatRGBPixels
    let width: Int
    let height: Int

    var megapixels: Double { Double(width * height) / 1_000_000 }

    /// A centred crop to a long/short ratio. The film gate has a fixed shape,
    /// so enabling its physical edge crops the photograph the way a camera
    /// gate would. Used for the small preview; export crops while decoding so
    /// no full-resolution second frame is allocated.
    func centerCropped(toAspect aspect: CGFloat) -> DecodedFrame {
        let crop = ImageDecoder.centerCrop(width: width, height: height, aspect: aspect)
        return cropped(to: crop)
    }

    /// Crop to an exact image aspect, including which way up it is. Use this
    /// when the film-strip direction is chosen explicitly: a 2:3 target stays
    /// portrait even though the photograph is landscape.
    func centerCropped(toTargetAspect targetAspect: CGFloat) -> DecodedFrame {
        let crop = ImageDecoder.centerCrop(width: width, height: height,
                                          targetAspect: targetAspect)
        return cropped(to: crop)
    }

    private func cropped(to crop: (x: Int, y: Int, width: Int, height: Int)) -> DecodedFrame {
        guard crop.width != width || crop.height != height else { return self }
        var output = [Float](repeating: 0, count: crop.width * crop.height * 3)
        pixels.withUnsafeBufferPointer { source in
            guard let source = source.baseAddress else { return }
            output.withUnsafeMutableBufferPointer { destination in
                guard let destination = destination.baseAddress else { return }
                for row in 0..<crop.height {
                    let from = ((crop.y + row) * width + crop.x) * 3
                    let to = row * crop.width * 3
                    destination.advanced(by: to).update(
                        from: source.advanced(by: from), count: crop.width * 3)
                }
            }
        }
        return DecodedFrame(pixels: FloatRGBPixels(output),
                            width: crop.width,
                            height: crop.height)
    }
}

/// Why a frame could not be decoded.
enum DecodeError: Error, LocalizedError, CustomStringConvertible {
    case unreadable(String)
    case unsupportedFormat(String)
    case emptyImage
    case outOfMemory(pixels: Int)

    var description: String {
        switch self {
        case .unreadable(let why): "the image could not be read: \(why)"
        case .unsupportedFormat(let what): "this format cannot be decoded on iOS: \(what)"
        case .emptyImage: "the image is empty"
        case .outOfMemory(let px): "this frame is \(px) pixels, too large to decode on a phone"
        }
    }

    var errorDescription: String? { description }
}

/// Decodes images into the engine's input space.
enum ImageDecoder {

    /// The largest frame a phone will decode, in pixels.
    ///
    /// 24 MP is the ceiling here, not the engine's: the engine renders a
    /// 45 MP frame happily, but a phone has to hold the decoded float32
    /// pixels (48 MB at 24 MP, three channels), the GPU copy, and the
    /// rendered result, and the jetsam limit is closer than the arithmetic
    /// suggests. The engine's `live` tier caps the *render* at 2048 px on the
    /// long edge anyway, so a larger decode buys nothing for the preview —
    /// only for the export, where the app re-renders at `full`.
    static let maxPixels = 64_000_000

    /// The long edge the decoded frame is scaled to before it reaches the
    /// engine.
    ///
    /// A preview at 2048 px long edge needs no more, and decoding a 45 MP
    /// frame to throw most of it away costs seconds and hundreds of megabytes
    /// for a result nobody sees. The export path decodes at full size.
    static let previewLongEdge = 2048

    /// Export at the source resolution; only the interactive preview shrinks.
    static let exportLongEdge: Int? = nil

    /// The exact float working space used by the Mac 1.3.5 decoder.
    private static let linearProPhoto: CGColorSpace? = {
        let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let primaries: [CGFloat] = [
            0.7976749, 0.2880402, 0.0000000,
            0.1351917, 0.7118741, 0.0000000,
            0.0313534, 0.0000857, 0.8252100,
        ]
        return d50.withUnsafeBufferPointer { wp in
            black.withUnsafeBufferPointer { bp in
                gamma.withUnsafeBufferPointer { gp in
                    primaries.withUnsafeBufferPointer { matrix in
                        CGColorSpace(calibratedRGBWhitePoint: wp.baseAddress!,
                                     blackPoint: bp.baseAddress,
                                     gamma: gp.baseAddress!,
                                     matrix: matrix.baseAddress)
                    }
                }
            }
        }
    }()

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ])

    /// Decode an image from data.
    ///
    /// - Parameter maxLongEdge: the long edge to scale to, or `nil` for no
    ///   scaling (the export path).
    static func decode(data: Data, maxLongEdge: Int?, typeHint: UTType? = nil,
                       aspect: CGFloat? = nil, targetAspect: CGFloat? = nil) throws -> DecodedFrame {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DecodeError.unreadable("not an image this system recognises")
        }
        let callerTypeHint = typeHint
        let resolvedHint = callerTypeHint ?? inferredRAWTypeHint(for: data)
        let authoritativeRAW = isRAW(source: source, typeHint: callerTypeHint)
        var rawFailure: Error?

        // CIRAWFilter can return a non-nil implementation for ordinary JPEGs
        // on some iOS releases. Its concrete implementation also varies by
        // camera format, and a property Swift believes exists can still have
        // no Objective-C setter. That raises an exception Swift cannot catch,
        // so the property configuration lives in RAWDecodeSupport.m where it
        // can be guarded one setter at a time. Trust the container type
        // reported by ImageIO, never the mere presence of CIRAWFilter.
        if isRAW(source: source, typeHint: resolvedHint) {
            // The identifier is what tells Core Image which maker profile to
            // use. A generic container type (`public.tiff`, or DNG for every
            // file) loses that profile. Prefer a real RAW UTI from ImageIO,
            // then the caller's extension-based hint.
            let identifier = rawIdentifier(source: source, typeHint: resolvedHint)
#if DEBUG
            let forceLibRaw = ProcessInfo.processInfo.environment["SPEKTRAFILM_FORCE_LIBRAW"] == "1"
#else
            let forceLibRaw = false
#endif
            if !forceLibRaw, let output = SPKDecodeRAWImage(data, identifier) {
                // A filter object can exist while its `outputImage` is empty,
                // and iOS can also answer with an embedded thumbnail instead
                // of the sensor frame (Nikon NEF does this on iOS 27). Both
                // are failures for this app: the first has no pixels, the
                // second silently exports a 120x160 postage stamp. Compare
                // the long edge against the size ImageIO reports for the
                // file before trusting the Core Image result.
                let declared = declaredPixelSize(source: source)
                if !isPlausibleRAWExtent(output.extent, declared: declared) {
                    NSLog("SpektraLab Core Image RAW returned %dx%d; using LibRaw",
                          Int(output.extent.width), Int(output.extent.height))
                } else {
                    do {
                        return try pixels(from: output, maxLongEdge: maxLongEdge,
                                          aspect: aspect, targetAspect: targetAspect)
                    } catch {
                        NSLog("SpektraLab Core Image RAW path failed for %@: %@",
                              identifier ?? "unknown", error.localizedDescription)
                    }
                }
            }

            // Apple's RAW support is a camera profile table, not a universal
            // decoder. A format can be missing, return an empty image, or
            // expose only its preview, and that set differs between macOS and
            // iOS. Fall back to the same pinned LibRaw release and the same
            // linear-ProPhoto policy the Mac engine uses.
            do {
                return try decodeWithLibRaw(data: data, typeHint: resolvedHint,
                                            identifier: identifier,
                                            maxLongEdge: maxLongEdge,
                                            aspect: aspect, targetAspect: targetAspect)
            } catch {
                guard !authoritativeRAW else { throw error }
                // The RAW UTI came from a byte signature, not ImageIO or the
                // caller. A plain TIFF can carry a maker string too, so give
                // Core Image's ordinary decoder a chance after LibRaw fails.
                rawFailure = error
                NSLog("SpektraLab inferred RAW path failed for %@; trying Core Image: %@",
                      identifier ?? "unknown", error.localizedDescription)
            }
        }
        if let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            return try pixels(from: image, maxLongEdge: maxLongEdge,
                              aspect: aspect, targetAspect: targetAspect)
        }

        // A TIFF-based RAW can arrive here when ImageIO reports public.tiff
        // and the picker did not preserve a RAW type. LibRaw is the last
        // chance before calling the file unreadable.
        if isTIFFContainer(data) {
            if let rawFailure {
                throw DecodeError.unreadable(
                    "Core Image could not decode this TIFF; \(rawFailure.localizedDescription)")
            }
            do {
                return try decodeWithLibRaw(data: data, typeHint: resolvedHint,
                                            identifier: rawIdentifier(source: source,
                                                                      typeHint: resolvedHint),
                                            maxLongEdge: maxLongEdge,
                                            aspect: aspect, targetAspect: targetAspect)
            } catch {
                throw DecodeError.unreadable(
                    "Core Image could not decode this TIFF; \(error.localizedDescription)")
            }
        }
        throw DecodeError.unreadable("Core Image could not decode this image")
    }

    private static func decodeWithLibRaw(data: Data, typeHint: UTType?,
                                         identifier: String?, maxLongEdge: Int?,
                                         aspect: CGFloat?, targetAspect: CGFloat?) throws -> DecodedFrame {
        var width = 0
        var height = 0
        let suffix = typeHint?.preferredFilenameExtension
            ?? UTType(identifier ?? "")?.preferredFilenameExtension
        guard let decoded = SPKLibRawDecode(
            data,
            suffix,
            maxLongEdge ?? 0,
            aspect.map(Double.init) ?? 0,
            targetAspect.map(Double.init) ?? 0,
            &width,
            &height
        ) else {
            let message = String(cString: SPKLibRawLastError())
            throw DecodeError.unreadable(message.isEmpty
                ? "Apple RAW and the bundled LibRaw decoder both refused this file"
                : message)
        }
        guard width > 0, height > 0 else {
            SPKLibRawFrameFree(decoded)
            throw DecodeError.emptyImage
        }
        return DecodedFrame(
            pixels: FloatRGBPixels(librawFrame: decoded,
                                   pixelCount: width * height * 3),
            width: width,
            height: height
        )
    }

    /// A picker can hand over original RAW bytes without the extension that
    /// told us what they are. ImageIO then reports the TIFF shell as
    /// `public.tiff`, so use the container's maker signature as a hint.
    static func inferredRAWTypeHint(for data: Data) -> UTType? {
        let sample = Data(data.prefix(2_000_000))
        func has(_ bytes: [UInt8]) -> Bool { sample.starts(with: bytes) }
        func contains(_ text: String) -> Bool {
            sample.range(of: Data(text.utf8)) != nil
        }

        let isORF = has([0x49, 0x49, 0x52, 0x4F]) || has([0x4D, 0x4D, 0x4F, 0x52])
        let isRW2 = has([0x49, 0x49, 0x55, 0x00])
        let isCR3 = sample.count > 12 && sample.subdata(in: 4..<12) == Data("ftypcrx ".utf8)
        let isRAF = contains("FUJIFILMCCD-RAW")
        let isTIFF = isTIFFContainer(data)
        guard isTIFF || isORF || isRW2 || isCR3 || isRAF else { return nil }

        if isORF || isRW2 {
            return UTType(filenameExtension: has([0x49, 0x49, 0x55, 0x00]) ? "rw2" : "orf")
        }
        if isCR3 {
            return UTType(filenameExtension: "cr3")
        }
        if isRAF {
            return UTType(filenameExtension: "raf")
        }
        if contains("SONY") {
            return UTType(filenameExtension: "arw")
        }
        if contains("NIKON") || contains("Nikon") {
            return UTType(filenameExtension: "nef")
        }
        if contains("Canon") {
            return UTType(filenameExtension: "cr2")
        }
        if contains("DNG") {
            return UTType(filenameExtension: "dng")
        }
        return nil
    }

    private static func isTIFFContainer(_ data: Data) -> Bool {
        data.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
    }

    /// The UTI that describes the camera container, not the TIFF shell it is
    /// wrapped in. iOS reports Sony ARW and Nikon NEF as `public.tiff`; giving
    /// that to CIRAWFilter strips the maker profile it needs. The extension
    /// hint is a real RAW UTI, so it wins over a generic container type.
    private static func rawIdentifier(source: CGImageSource, typeHint: UTType?) -> String? {
        let detected = CGImageSourceGetType(source) as String?
        if let detected,
           UTType(detected)?.conforms(to: .rawImage) == true {
            return detected
        }
        if let typeHint, typeHint.conforms(to: .rawImage) {
            return typeHint.identifier
        }
        return detected ?? typeHint?.identifier
    }

    /// The full frame size ImageIO reports for a file, before any decode.
    private static func declaredPixelSize(source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A RAW filter may downscale by whole factors, but it must not return an
    /// embedded preview. Half the declared long edge leaves room for a 2x
    /// scale factor. The fixed floor catches files where iOS reports the
    /// preview's size as the file's size too -- Nikon NEF does exactly that
    /// on iOS 27, with a 160x120 "native" frame for a 6048x4024 sensor.
    private static func isPlausibleRAWExtent(_ extent: CGRect, declared: CGSize?) -> Bool {
        guard !extent.isInfinite, !extent.isEmpty else { return false }
        let outputLongEdge = max(extent.width, extent.height)
        var required: CGFloat = 1024
        if let declared {
            required = max(required, max(declared.width, declared.height) * 0.5)
        }
        return outputLongEdge >= required
    }

    /// ImageIO's declared container type is the gate for camera RAW handling.
    /// This intentionally does not infer RAW support from CIRAWFilter alone.
    static func isRAW(source: CGImageSource, typeHint: UTType? = nil) -> Bool {
        if typeHint?.conforms(to: .rawImage) == true { return true }
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// Decode an image from a file URL.
    static func decode(url: URL, maxLongEdge: Int?) throws -> DecodedFrame {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let hint = UTType(filenameExtension: url.pathExtension)
        return try decode(data: data, maxLongEdge: maxLongEdge, typeHint: hint)
    }

    /// Decode an image from a `CGImage` — what the Photos picker hands back.
    static func decode(image: CGImage, maxLongEdge: Int?) throws -> DecodedFrame {
        try decode(cgImage: image, maxLongEdge: maxLongEdge)
    }

    /// Decode from a `CGImageSource`.
    static func decode(source: CGImageSource, maxLongEdge: Int?) throws -> DecodedFrame {
        let type = CGImageSourceGetType(source) as String?
        guard let image = decodeImage(source: source, maxLongEdge: maxLongEdge) else {
            if let type {
                throw DecodeError.unsupportedFormat(type)
            }
            throw DecodeError.emptyImage
        }
        return try pixels(from: CIImage(cgImage: image), maxLongEdge: nil)
    }

    /// Decode from a `CGImage`.
    static func decode(cgImage: CGImage, maxLongEdge: Int?) throws -> DecodedFrame {
        try pixels(from: CIImage(cgImage: cgImage), maxLongEdge: maxLongEdge)
    }

    // MARK: - the decode itself

    /// Core Image performs the complete source-profile conversion directly
    /// into float32 linear ProPhoto, matching Mac 1.3.5 without an 8-bit sRGB
    /// intermediate or a hand-written colour matrix.
    private static func pixels(from source: CIImage, maxLongEdge: Int?,
                               aspect: CGFloat? = nil,
                               targetAspect: CGFloat? = nil) throws -> DecodedFrame {
        guard let colorSpace = linearProPhoto else {
            throw DecodeError.unreadable("linear ProPhoto RGB is unavailable")
        }
        var image = source
        var sourceExtent = image.extent
        guard !sourceExtent.isInfinite, !sourceExtent.isEmpty else {
            throw DecodeError.emptyImage
        }
        if let targetAspect {
            let crop = centerCrop(width: Int(sourceExtent.width.rounded()),
                                  height: Int(sourceExtent.height.rounded()),
                                  targetAspect: targetAspect)
            sourceExtent = CGRect(x: sourceExtent.origin.x + CGFloat(crop.x),
                                  y: sourceExtent.origin.y + CGFloat(crop.y),
                                  width: CGFloat(crop.width),
                                  height: CGFloat(crop.height))
            image = image.cropped(to: sourceExtent)
        } else if let aspect {
            let crop = centerCrop(width: Int(sourceExtent.width.rounded()),
                                  height: Int(sourceExtent.height.rounded()),
                                  aspect: aspect)
            sourceExtent = CGRect(x: sourceExtent.origin.x + CGFloat(crop.x),
                                  y: sourceExtent.origin.y + CGFloat(crop.y),
                                  width: CGFloat(crop.width),
                                  height: CGFloat(crop.height))
            image = image.cropped(to: sourceExtent)
        }
        if let maxLongEdge {
            let current = max(sourceExtent.width, sourceExtent.height)
            if current > CGFloat(maxLongEdge), current.isFinite {
                let factor = CGFloat(maxLongEdge) / current
                image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            }
        }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { throw DecodeError.emptyImage }
        guard width * height <= maxPixels else {
            throw DecodeError.outOfMemory(pixels: width * height)
        }
        let placed = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                              y: -extent.origin.y))
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            context.render(placed, toBitmap: base, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: colorSpace)
        }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return DecodedFrame(pixels: FloatRGBPixels(rgb), width: width, height: height)
    }

    /// The integer rectangle used by both the Core Image and LibRaw paths.
    /// `aspect` is long edge over short edge and keeps the photograph's own
    /// orientation: a portrait frame is cropped to the reciprocal, so a
    /// vertical 3:2 photograph becomes 2:3 and not a sideways landscape.
    static func centerCrop(width: Int, height: Int, aspect: CGFloat) -> (x: Int, y: Int, width: Int, height: Int) {
        guard width > 0, height > 0, aspect.isFinite, aspect > 0 else {
            return (0, 0, max(width, 1), max(height, 1))
        }
        let sourceAspect = CGFloat(width) / CGFloat(height)
        let targetAspect = sourceAspect >= 1 ? aspect : 1 / aspect
        return centerCrop(width: width, height: height, targetAspect: targetAspect)
    }

    /// Crop to an exact target aspect, which may be portrait or landscape.
    static func centerCrop(width: Int, height: Int,
                           targetAspect: CGFloat) -> (x: Int, y: Int, width: Int, height: Int) {
        guard width > 0, height > 0, targetAspect.isFinite, targetAspect > 0 else {
            return (0, 0, max(width, 1), max(height, 1))
        }
        let sourceAspect = CGFloat(width) / CGFloat(height)
        var cropWidth = width
        var cropHeight = height
        if sourceAspect > targetAspect {
            cropWidth = max(1, min(width, Int((CGFloat(height) * targetAspect).rounded())))
        } else if sourceAspect < targetAspect {
            cropHeight = max(1, min(height, Int((CGFloat(width) / targetAspect).rounded())))
        }
        return ((width - cropWidth) / 2, (height - cropHeight) / 2, cropWidth, cropHeight)
    }

    private static func decodeImage(source: CGImageSource, maxLongEdge: Int?) -> CGImage? {
        if let maxLongEdge {
            // `kCGImageSourceThumbnailMaxPixelSize` makes ImageIO decode at a
            // reduced size, which is a decode-time downscale — much cheaper
            // than decoding 45 MP and resampling afterwards.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return thumbnail
            }
            // The thumbnail path failed (some RAW containers refuse it). Fall
            // through to a full decode rather than giving up on the file.
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

}
