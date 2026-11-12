//  StockCatalog.swift — the films and papers the engine ships with.
//
//  A "stock" is a profile file: `<resources>/profiles/<stock>.json`, each with
//  an `info` block that names it, says whether it is a film or a paper, and
//  says whether it is a negative or a slide (positive) stock.
//
//  Two directories, one catalogue:
//
//  * `profiles/` — the 28 measured configurations from Andrea Volpato's
//    spektrafilm, 18 negative films + 4 slides + 6 papers.
//  * `../resources_product/profiles/` — 4 black-and-white films plus a
//    CineStill and a paper, measured for this project and shipped separately
//    because they are not upstream's.
//
//  The engine resolves a stock by name against `<resources>/profiles/`, so
//  the product profiles are merged into the same directory in the bundle. See
//  `ios/Tools/build-engine.sh`.
//
//  The catalogue is read at launch and cached: the files are small (a few
//  hundred kB each), the count is fixed, and the engine reads them again
//  anyway when it loads a profile.

import Foundation

/// One film or paper.
struct Stock: Identifiable, Hashable, Sendable {
    /// The profile's stem — what the engine calls it.
    let id: String
    /// The name to show a person: "Kodak Portra 400".
    let name: String
    /// `film` or `paper`.
    let support: Support
    /// `negative` or `positive`. A slide has no negative to print from.
    let type: FilmType
    /// The Mac catalogue's photographed film box, when one is available.
    let coverURL: URL?

    enum Support: String, Sendable {
        case film, paper
        var label: String {
            switch self {
            case .film: "胶片"
            case .paper: "相纸"
            }
        }
    }

    enum FilmType: String, Sendable {
        case negative, positive
        var label: String {
            switch self {
            case .negative: "负片"
            case .positive: "反转片"
            }
        }
    }

    /// Whether this stock can be printed: a slide film's `spk_render_digital_
    /// intermediate` has none, and the engine refuses it with `SPK_ERR_USER`.
    var isPrintable: Bool { type == .negative }
}

/// Every stock the bundle carries.
struct StockCatalog: Sendable {
    let films: [Stock]
    let papers: [Stock]
    let slides: [Stock]

    /// Every film that can be printed, negative and slide alike.
    var printableFilms: [Stock] { films }

    /// The catalogue, read from `resources/profiles`.
    ///
    /// A missing or malformed profile is skipped rather than fatal: one bad
    /// file should cost one stock, not the whole app.
    static func load(resources: URL) -> StockCatalog {
        let dir = resources.appendingPathComponent("profiles")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var films: [Stock] = []
        var papers: [Stock] = []
        var slides: [Stock] = []

        for file in files where file.hasSuffix(".json") {
            let id = String(file.dropLast(5))
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  let supportRaw = (info["support"] as? String)
                    ?? (json["derived_from"] != nil ? "film" : nil),
                  let typeRaw = (info["type"] as? String)
                    ?? (json["derived_from"] != nil ? "negative" : nil),
                  let support = Stock.Support(rawValue: supportRaw),
                  let type = Stock.FilmType(rawValue: typeRaw) else {
                continue
            }
            let name = (info["name"] as? String) ?? id
            let cover = resources
                .appendingPathComponent("film_covers")
                .appendingPathComponent(id)
                .appendingPathExtension("jpg")
            let resolvedSupport: Stock.Support = (info["stage"] as? String) == "printing"
                ? .paper : support
            let stock = Stock(id: id, name: name, support: resolvedSupport, type: type,
                              coverURL: FileManager.default.fileExists(atPath: cover.path) ? cover : nil)
            switch (resolvedSupport, type) {
            case (.film, .negative): films.append(stock)
            case (.film, .positive): slides.append(stock)
            case (.paper, _): papers.append(stock)
            }
        }

        // Sorted by display name: the list is a menu, and a menu is read.
        return StockCatalog(films: films.sorted { $0.name < $1.name },
                            papers: papers.sorted { $0.name < $1.name },
                            slides: slides.sorted { $0.name < $1.name })
    }

    /// The stocks to show when nothing is chosen yet.
    ///
    /// Portra 400 and Crystal Archive: the pair most people reach for first,
    /// and one that is a negative film and a paper, so the app can open and
    /// print a frame without the user having to choose anything.
    static let defaultFilm = "kodak_portra_400"
    static let defaultPaper = "fujifilm_crystal_archive_typeii"

    /// The paper whose preview LUT is paired with a given film, if any.
    ///
    /// The engine's `print_luts.json` records which film each preview table
    /// was baked against, and a mismatch is an approximation with unmeasured
    /// error. So when the user picks a film that has a paired paper, that
    /// paper is offered first.
    static func pairedPaper(forFilm film: String, in resources: URL) -> String? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("print_luts.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for (_, value) in json {
            guard let entry = value as? [String: Any],
                  let paired = entry["paired_film"] as? String,
                  paired == film else { continue }
            return (entry["paper"] as? String)
                ?? entry["print_stock"] as? String
                ?? paperForLUTKey(film: film, resources: resources)
        }
        return nil
    }

    /// The LUT index is keyed by paper name, so the pairing runs the other
    /// way: find the entry whose `paired_film` matches, and take its key.
    private static func paperForLUTKey(film: String, resources: URL) -> String? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("print_luts.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for (key, value) in json {
            guard let entry = value as? [String: Any],
                  let paired = entry["paired_film"] as? String,
                  paired == film else { continue }
            return key
        }
        return nil
    }
}
