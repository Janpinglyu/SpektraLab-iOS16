import Foundation
import ImageIO
import UniformTypeIdentifiers

private func source(for data: Data, label: String) throws -> CGImageSource {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        throw DecodeError.unreadable("\(label): ImageIO did not recognise the file")
    }
    return source
}

private func check(_ path: String, expectedRAW: Bool) throws {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let imageSource = try source(for: data, label: url.lastPathComponent)
    let detectedRAW = ImageDecoder.isRAW(
        source: imageSource,
        typeHint: UTType(filenameExtension: url.pathExtension)
    )

    guard detectedRAW == expectedRAW else {
        throw DecodeError.unreadable(
            "\(url.lastPathComponent): expected RAW=\(expectedRAW), got RAW=\(detectedRAW)"
        )
    }

    let edge = ProcessInfo.processInfo.environment["FULL_RESOLUTION"] == "1" ? nil : 512
    let frame = try ImageDecoder.decode(url: url, maxLongEdge: edge)
    guard frame.width > 0, frame.height > 0,
          frame.pixels.count == frame.width * frame.height * 3 else {
        throw DecodeError.emptyImage
    }
    print("PASS \(url.lastPathComponent): RAW=\(detectedRAW), \(frame.width)x\(frame.height)")
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: ImageDecoderSmoke <jpeg> <raw>\n", stderr)
    exit(2)
}

do {
    try check(CommandLine.arguments[1], expectedRAW: false)
    try check(CommandLine.arguments[2], expectedRAW: true)
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
