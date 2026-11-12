//  PhotoLibrary.swift — the photographs the app keeps, and the look each one has.
//
//  The library is deliberately app-owned rather than a list of Photos
//  identifiers: a picked RAW has to stay readable after the picker result goes
//  away, and the wall has to render without asking the Photos database for
//  permission again. Originals live in Application Support, one thumbnail per
//  photo beside them, and a small JSON manifest carries the recipe.
//
//  A recipe is the *look*, not the photograph: film, paper, adjustments and
//  the physical film-edge/date-back choices. It never carries a crop, a date
//  or a person's shooting data, so pasting it across a selection does not
//  make every picture claim it was taken on the same day.

import Foundation
import UIKit

/// Everything needed to reproduce one look on another photograph.
struct PhotoRecipe: Codable, Equatable, Sendable {
    var filmStock: String
    var printStock: String
    var params: [String: Double]
    var filmBorderEnabled: Bool
    var overscanFormat: String
    var stripOrientation: String
    var dateBackEnabled: Bool
    var dateBackStyle: String
    var dateBackPlacement: String
    var dateBackCorner: String

    /// The look a newly imported photograph starts with.
    static var standard: PhotoRecipe {
        var defaults: [String: Double] = [:]
        for control in ParamCatalog.all { defaults[control.key] = control.defaultValue }
        return PhotoRecipe(filmStock: StockCatalog.defaultFilm,
                           printStock: StockCatalog.defaultPaper,
                           params: defaults,
                           filmBorderEnabled: false,
                           overscanFormat: FilmGateCatalog.automaticID,
                           stripOrientation: FilmStripOrientation.automatic.rawValue,
                           dateBackEnabled: false,
                           dateBackStyle: DateBackStyle.lcd.rawValue,
                           dateBackPlacement: DateBackPlacement.frame.rawValue,
                           dateBackCorner: DateBackCorner.br.rawValue)
    }

    /// Parameters from an older library may not have every key this build
    /// knows. Fill them from the catalogue rather than letting a missing slider
    /// fall back to an engine default the UI does not show.
    var normalizedParams: [String: Double] {
        var merged: [String: Double] = [:]
        for control in ParamCatalog.all { merged[control.key] = control.defaultValue }
        for (key, value) in params { merged[key] = value }
        return merged
    }

    /// The same complete delta every open path uses. `imageAspect` resolves an
    /// automatic gate from *this* photograph, not from whichever photograph
    /// happened to be open when the recipe was copied.
    func engineDelta(filmName: String,
                     imageAspect: CGFloat,
                     stamp: Date,
                     shootingData: String) -> [String: ParamValue] {
        var delta = ParamDefaults.delta(film: filmStock, paper: printStock)
        for (key, value) in normalizedParams { delta[key] = .number(value) }

        let gate = FilmGateCatalog.resolve(selection: overscanFormat, imageAspect: imageAspect)
        delta["overscan_active"] = .bool(filmBorderEnabled)
        delta["overscan_format"] = .string(gate.id)
        delta["overscan_mode"] = .string("strip")
        delta["overscan_gate"] = .string("auto")
        delta["overscan_holes"] = .string("white")
        delta["overscan_carrier"] = .string("none")
        delta["overscan_edge_text"] = .string(filmName.uppercased())
        delta["overscan_frame_number"] = .number(12)
        delta["overscan_camera_seed"] = .number(7)
        delta["overscan_frame_seed"] = .number(11)
        delta["overscan_fog"] = .number(1)
        delta["overscan_leaks"] = .number(0)

        let style = DateBackStyle(rawValue: dateBackStyle) ?? .lcd
        let placement = DateBackPlacement(rawValue: dateBackPlacement) ?? .frame
        let corner = DateBackCorner(rawValue: dateBackCorner) ?? .br
        let dateActive = dateBackEnabled && gate.supportsDateBack
        delta["date_imprint_active"] = .bool(dateActive)
        delta["date_imprint_text"] = .string(Self.dateStamp(stamp))
        delta["date_imprint_data_text"] = .string(shootingData)
        delta["date_imprint_placement"] = .string(filmBorderEnabled ? placement.rawValue : DateBackPlacement.frame.rawValue)
        delta["date_imprint_style"] = .string(style.rawValue)
        delta["date_imprint_corner"] = .string(corner.rawValue)
        delta["date_imprint_ev"] = .number(3.5)
        delta["date_imprint_size"] = .number(1)
        delta["date_imprint_inset_x"] = .number(3)
        delta["date_imprint_inset_y"] = .number(2.4)
        return delta
    }

    static func dateStamp(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: date)
        return String(format: "'%02d %02d %02d",
                      (parts.year ?? 2000) % 100,
                      parts.month ?? 1,
                      parts.day ?? 1)
    }
}

/// One photograph on the wall. The image is already decoded for display; the
/// original stays on disk so opening it or exporting it keeps full quality.
struct LibraryPhoto: Identifiable {
    let id: UUID
    var name: String
    var fileName: String
    var typeIdentifier: String?
    var pixelWidth: Int
    var pixelHeight: Int
    /// The source's display aspect before a film gate crops it. A rendered
    /// thumbnail may itself be a wide strip, so its size cannot be used to
    /// decide the next crop.
    var sourceAspect: Double
    var createdAt: Date
    var recipe: PhotoRecipe
    var isEdited: Bool
    var thumbnail: UIImage

    /// The thumbnail has already been through ImageIO's orientation transform,
    /// so its size is the only aspect that is correct for both portrait and
    /// landscape source files.
    var aspect: Double {
        guard thumbnail.size.height > 0 else { return 3.0 / 2.0 }
        return Double(thumbnail.size.width / thumbnail.size.height)
    }

    var megapixels: Double {
        Double(pixelWidth * pixelHeight) / 1_000_000
    }
}

/// The manifest's row. `thumbnail` is not stored in JSON; it is the JPEG next
/// to the original, named from the id.
struct LibraryManifestEntry: Codable {
    var id: UUID
    var name: String
    var fileName: String
    var typeIdentifier: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var sourceAspect: Double
    var createdAt: Date
    var recipe: PhotoRecipe
    var isEdited: Bool
}

enum LibraryThumbnail {
    static let maxPixel: CGFloat = 900

    /// Decode a display thumbnail without touching the engine. ImageIO's
    /// thumbnail path is also the cheapest way to honour EXIF orientation on
    /// JPEG/HEIC/RAW containers.
    static func from(data: Data, maxPixel: CGFloat = maxPixel) -> (UIImage, Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let cg else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? cg.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? cg.height
        return (UIImage(cgImage: cg), width, height)
    }

    static func downscale(_ image: UIImage, maxPixel: CGFloat = maxPixel) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return image }
        let factor = min(1, maxPixel / max(width, height))
        if factor >= 1 { return image }
        let size = CGSize(width: width * factor, height: height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func downscale(_ cgImage: CGImage, maxPixel: CGFloat = maxPixel) -> UIImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return UIImage(cgImage: cgImage) }
        let factor = min(1, maxPixel / max(width, height))
        let size = CGSize(width: width * factor, height: height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func saveJPEG(_ image: UIImage, to url: URL) throws {
        guard let data = image.jpegData(compressionQuality: 0.86) else {
            throw DecodeError.unreadable("缩略图无法编码")
        }
        try data.write(to: url, options: .atomic)
    }

    static func placeholder() -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let symbol = UIImage(systemName: "photo")?.withTintColor(.white.withAlphaComponent(0.28),
                                                                     renderingMode: .alwaysOriginal)
            let side = size.width * 0.24
            symbol?.draw(in: CGRect(x: (size.width - side) / 2,
                                    y: (size.height - side) / 2,
                                    width: side, height: side))
        }
    }
}
