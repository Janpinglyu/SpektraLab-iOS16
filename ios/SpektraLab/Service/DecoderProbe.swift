//  DecoderProbe.swift — a DEBUG-only, launch-argument decoder check.
//
//  Core Image's RAW support is supplied by the OS and differs between macOS
//  and iOS. Compiling a macOS command-line harness therefore cannot prove
//  that a Sony ARW opens on a phone. This probe runs inside the real app on a
//  simulator or device, decoding every file the caller stages for it.

#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import Metal
import UIKit
import UniformTypeIdentifiers

enum DecoderProbe {
    static func runIfRequested() {
        runRenderTestIfRequested()
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SPEKTRAFILM_DECODER_TEST_DIR"],
              !directory.isEmpty else { return }
        let fullResolution = environment["SPEKTRAFILM_DECODER_TEST_FULL"] == "1"

        Task.detached(priority: .userInitiated) {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? [])
                .filter { url in
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
                        return false
                    }
                    return values.isRegularFile == true
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var lines: [String] = []
            for url in files {
                let hint = UTType(filenameExtension: url.pathExtension)
                do {
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let frame = try ImageDecoder.decode(
                        data: data,
                        maxLongEdge: fullResolution ? nil : 512,
                        typeHint: hint
                    )
                    let line = "PASS \(url.lastPathComponent) \(frame.width)x\(frame.height) RAW=\(hint?.conforms(to: .rawImage) == true)"
                    lines.append(line)
                    NSLog("SpektraLab decoder probe: %@", line)
                } catch {
                    let line = "FAIL \(url.lastPathComponent): \(error.localizedDescription)"
                    lines.append(line)
                    NSLog("SpektraLab decoder probe: %@", line)
                }
            }

            let result = lines.joined(separator: "\n") + "\n"
            let documents = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask)[0]
            try? result.write(to: documents.appendingPathComponent("decoder-probe.txt"),
                              atomically: true, encoding: .utf8)
        }
    }

    /// Exercise the full decode → engine → 16-bit CGImage → JPEG chain.
    ///
    /// This exists because a decoder test alone cannot catch a colour-space
    /// mismatch, a missing engine resource, or an export-time memory spike.
    private static func runRenderTestIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SPEKTRAFILM_RENDER_TEST_PATH"],
              !path.isEmpty else { return }
        let fullResolution = environment["SPEKTRAFILM_RENDER_TEST_FULL"] == "1"
        let saveToPhotos = environment["SPEKTRAFILM_RENDER_TEST_SAVE"] == "1"
        let filmBorder = environment["SPEKTRAFILM_RENDER_TEST_BORDER"] == "1"
        let gateID = environment["SPEKTRAFILM_RENDER_TEST_GATE"] ?? "135"
        let gate = FilmGateCatalog.gate(id: gateID) ?? FilmGateCatalog.gates[0]
        let orientation = FilmStripOrientation(
            rawValue: environment["SPEKTRAFILM_RENDER_TEST_ORIENTATION"] ?? "automatic"
        ) ?? .automatic
        let automaticAspect: CGFloat? = filmBorder && orientation == .automatic
            ? gate.aspect
            : nil
        let targetAspect: CGFloat? = filmBorder && orientation != .automatic
            ? (orientation == .vertical ? 1 / gate.aspect : gate.aspect)
            : nil
        let dateBack = environment["SPEKTRAFILM_RENDER_TEST_DATE"] == "1"
            && gate.supportsDateBack

        Task.detached(priority: .userInitiated) {
            let source = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                let frame = try ImageDecoder.decode(
                    data: data,
                    maxLongEdge: fullResolution ? nil : 2048,
                    typeHint: UTType(filenameExtension: source.pathExtension),
                    aspect: automaticAspect,
                    targetAspect: targetAspect
                )
                guard let device = MTLCreateSystemDefaultDevice() else {
                    throw EngineError.noDevice
                }
                let engine = try SpektraEngine(device: device)
                var delta = ParamDefaults.delta(
                    film: StockCatalog.defaultFilm,
                    paper: StockCatalog.defaultPaper
                )
                delta["output_color_space"] = .string("sRGB")
                if filmBorder {
                    delta["overscan_active"] = .bool(true)
                    delta["overscan_format"] = .string(gate.id)
                    delta["overscan_mode"] = .string("strip")
                    delta["overscan_gate"] = .string("auto")
                    delta["overscan_holes"] = .string("white")
                    delta["overscan_carrier"] = .string("none")
                    delta["overscan_edge_text"] = .string("KODAK PORTRA 400")
                    delta["overscan_frame_number"] = .number(12)
                    delta["overscan_camera_seed"] = .number(7)
                    delta["overscan_frame_seed"] = .number(11)
                    delta["overscan_fog"] = .number(1)
                    delta["overscan_leaks"] = .number(0)
                }
                if dateBack {
                    delta["date_imprint_active"] = .bool(true)
                    delta["date_imprint_text"] = .string("'26 11 05")
                    delta["date_imprint_data_text"] = .string("1/125  F2.8  ISO 400  50mm")
                    delta["date_imprint_placement"] = .string(filmBorder ? "rebate" : "frame")
                    delta["date_imprint_style"] = .string("lcd")
                    delta["date_imprint_corner"] = .string("br")
                    delta["date_imprint_ev"] = .number(3.5)
                    delta["date_imprint_size"] = .number(1)
                    delta["date_imprint_inset_x"] = .number(3)
                    delta["date_imprint_inset_y"] = .number(2.4)
                }
                let openDelta = delta

                let bitmap = try await engine.perform {
                    try frame.pixels.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else {
                            throw EngineError.failed(status: -1, message: "decode produced no pixels")
                        }
                        _ = try engine.open(pixels: EnginePixels(
                            data: base,
                            width: frame.width,
                            height: frame.height
                        ), params: openDelta)
                    }
                    _ = try engine.solve(target: "both")
                    return try engine.renderBitmap(tier: "full", reprint: false)
                }

                let destination = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                )[0].appendingPathComponent("render-test.jpg")
                guard let output = CGImageDestinationCreateWithURL(
                    destination as CFURL,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil
                ) else {
                    throw ExportError.encodingFailed
                }
                CGImageDestinationAddImage(output, bitmap.cgImage, [
                    kCGImageDestinationLossyCompressionQuality: 0.92,
                ] as CFDictionary)
                guard CGImageDestinationFinalize(output) else {
                    throw ExportError.encodingFailed
                }
                if saveToPhotos {
                    try await PhotoLibrary.saveJPEG(at: destination)
                    NSLog("SpektraLab render probe: PHOTOS PASS %dx%d",
                          bitmap.width, bitmap.height)
                }
                NSLog("SpektraLab render probe: PASS %dx%d -> %@",
                      bitmap.width, bitmap.height, destination.path)
            } catch {
                NSLog("SpektraLab render probe: FAIL %@", error.localizedDescription)
                let documents = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                )[0]
                try? error.localizedDescription.write(
                    to: documents.appendingPathComponent("render-probe-error.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }
}
#endif
