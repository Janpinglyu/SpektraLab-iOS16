import Foundation

guard CommandLine.arguments.count == 4,
      let maxEdge = Int(CommandLine.arguments[3]) else {
    fputs("usage: ImageDecoderDump <input> <output> <max-edge>\n", stderr)
    exit(2)
}

do {
    let frame = try ImageDecoder.decode(url: URL(fileURLWithPath: CommandLine.arguments[1]),
                                        maxLongEdge: maxEdge)
    var data = Data()
    var width = UInt32(frame.width).littleEndian
    var height = UInt32(frame.height).littleEndian
    withUnsafeBytes(of: &width) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &height) { data.append(contentsOf: $0) }
    frame.pixels.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    print("wrote \(frame.width)x\(frame.height) linear ProPhoto")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
