//  ViewModel.swift — the app's state, and the loop that drives the engine.
//
//  One `ObservableObject` holds the whole app: the frame, the stocks, the
//  parameters, the rendered texture, and the errors. SwiftUI reads it; the
//  engine is driven from it.
//
//  **The render loop is the interesting part.** A slider drag must not queue
//  a hundred renders: the engine would work through them all after the finger
//  is already up, and the user would watch the preview lag behind their own
//  hand. So a change marks the render *stale*, and a render runs only when
//  the user stops moving — with one render in flight at a time, and a newer
//  request replacing an older one rather than queueing behind it.

import Foundation
import SwiftUI
import Metal
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class ViewModel: ObservableObject {

    // MARK: - what the app shows

    /// The app's state.
    ///
    /// Named `AppState` rather than `State`: inside a SwiftUI view, `State`
    /// is SwiftUI's own property-wrapper type, and a nested type of the same
    /// name makes every `.failed` in the file ambiguous -- the compiler
    /// resolves it to some other `State` in scope and reports a type error
    /// about a gesture phase, which is nowhere near the problem.
    enum AppState: Equatable {
        case empty
        case importing
        case rendering
        case ready
        case failed(String)
    }

    @Published private(set) var state: AppState = .empty
    @Published private(set) var statusText = ""
    @Published private(set) var renderedTexture: MTLTexture?

    /// What identifies the current render.
    ///
    /// The engine gives every render a progress id, and it is a new string
    /// each time -- so it is what tells SwiftUI that the picture changed.
    /// The texture itself cannot: `MTLTexture` is not `Hashable`, and its
    /// `hashValue` does not exist.
    @Published private(set) var renderIdentity: String = ""
    @Published private(set) var lastRenderMs: Double = 0
    @Published private(set) var sourceSize: CGSize = .zero

    /// The parameters, as the sliders hold them.
    @Published var params: [String: Double] = [:]
    /// The chosen film and paper.
    @Published var filmStock: String = StockCatalog.defaultFilm
    @Published var printStock: String = StockCatalog.defaultPaper

    /// The film's physical edge. These are engine parameters, not a drawn
    /// border: the rebate, holes and edge print are developed on the negative.
    @Published private(set) var filmBorderEnabled = false
    @Published private(set) var overscanFormat = FilmGateCatalog.automaticID
    @Published private(set) var stripOrientation: FilmStripOrientation = .automatic

    /// The camera's date back, printed through the film base.
    @Published private(set) var dateBackEnabled = false
    @Published private(set) var dateBackStyle: DateBackStyle = .lcd
    @Published private(set) var dateBackPlacement: DateBackPlacement = .frame
    @Published private(set) var dateBackCorner: DateBackCorner = .br
    @Published private(set) var dateStampDate = Date()
    @Published private(set) var shootingDataText = "1/125  F2.8  ISO 400  50mm"

    /// The catalogue, read at launch.
    @Published private(set) var catalog = StockCatalog(films: [], papers: [], slides: [])

    // MARK: - the photo wall

    /// Every imported photograph, newest first. The originals and thumbnails
    /// live on disk; this array is the UI's index into them.
    @Published private(set) var library: [LibraryPhoto] = []
    /// Non-nil while the wall is showing and a photograph should be open in
    /// the editor. `ContentView` switches the whole screen on this.
    @Published private(set) var editingPhotoID: UUID?
    /// A modal, wall-level operation: importing, opening, or applying a recipe
    /// across a selection. It is separate from `state`, which belongs to the
    /// editor's engine session.
    @Published private(set) var libraryBusy: String?
    @Published private(set) var libraryMessage: String?
    /// The last copied look. Kept in UserDefaults as well as memory, so
    /// closing the app does not lose a recipe the person just copied.
    @Published private(set) var clipboardRecipe: PhotoRecipe?
    /// The photograph the clipboard recipe came from. It is deliberately not a
    /// valid paste target: a recipe is copied *from* this frame, not back onto
    /// it, and the wall dims it while the recipe is on the clipboard.
    @Published private(set) var recipeSourcePhotoID: UUID?

    var editingPhoto: LibraryPhoto? {
        guard let id = editingPhotoID else { return nil }
        return library.first { $0.id == id }
    }

    /// The stocks, in the order the scrolling strip shows them.
    var films: [Stock] { catalog.films + catalog.slides }
    var papers: [Stock] { catalog.papers }

    var currentFilmName: String {
        films.first { $0.id == filmStock }?.name ?? filmStock
    }

    var currentPaperName: String {
        papers.first { $0.id == printStock }?.name ?? printStock
    }

    var selectedGate: FilmGate {
        FilmGateCatalog.resolve(selection: overscanFormat, imageAspect: naturalAspect)
    }

    /// The crop shape handed to the engine. The engine reads the strip's
    /// direction from this shape, so changing it here changes the real
    /// perforations and rebate, not just the SwiftUI frame.
    var filmCropAspect: CGFloat {
        stripOrientation.targetAspect(for: selectedGate, sourceAspect: naturalAspect)
    }

    var gateDisplayName: String {
        overscanFormat == FilmGateCatalog.automaticID
            ? "自动 · \(selectedGate.title)"
            : selectedGate.title
    }

    var filmEdgeDisplayName: String {
        guard filmBorderEnabled else { return "关闭" }
        return stripOrientation == .automatic
            ? gateDisplayName
            : "\(gateDisplayName) · \(stripOrientation.title)"
    }

    var stripOrientationAvailable: Bool { !selectedGate.isSquare }

    var dateBackAvailable: Bool { selectedGate.supportsDateBack }

    var dateStampText: String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: dateStampDate)
        return String(format: "'%02d %02d %02d",
                      (parts.year ?? 2000) % 100,
                      parts.month ?? 1,
                      parts.day ?? 1)
    }

    /// A rebate date needs the film edge around the gate. Without it the
    /// engine prints the date in the picture instead.
    var effectiveDateBackPlacement: DateBackPlacement {
        filmBorderEnabled ? dateBackPlacement : .frame
    }

    /// Enough state to diagnose an engine failure without a debugger.
    var diagnostics: String {
        let root = engine?.resources.path ?? SpektraEngine.defaultResources().path
        return [
            "state: \(state)",
            "profiles: \(catalog.films.count) films / \(catalog.slides.count) slides / \(catalog.papers.count) papers",
            "resources: \(root)",
            "engine: \(engine == nil ? "not started" : "ready")",
            "film edge: \(filmBorderEnabled ? "on" : "off") · \(gateDisplayName) · \(stripOrientation.detail) · crop \(String(format: "%.4f", filmCropAspect))",
            "status: \(statusText)"
        ].joined(separator: "\n")
    }

    /// The picked photo, kept so it can be re-decoded at full size for export.
    private var pickedItem: PhotosPickerItem?
    private var originalTypeHint: UTType?
    /// Original bytes for the full-resolution export; a preview-only
    /// transferable must never replace them.
    private var originalData: Data?

    /// The decoded frame in the engine's input space.
    private var frame: DecodedFrame?
    /// The photograph's own long/short ratio, before a film gate crops it.
    private var naturalAspect: CGFloat = 3.0 / 2.0
    /// Gate and orientation changes re-decode the photograph. Coalesce them so
    /// a slow, older decode can never finish last and restore the previous
    /// direction after the user has picked a new one.
    private var effectReloadNeeded = false
    private var effectReloadRunning = false
    private var sourceGeneration = 0

    // MARK: - the engine

    private var engine: SpektraEngine?
    /// The canvas renderer. The view needs it to draw the texture.
    private(set) var renderer: CanvasRenderer? = nil
    private var device: MTLDevice?

    /// The render loop's state.
    private var renderTask: Task<Void, Never>?
    private var renderInFlight = false
    private var needsRender = false
    private var paramsDirty = false
    /// The recipe the editor opened with. `closeEditor` compares against it so
    /// merely viewing a photo does not mark it as edited.
    private var editingBaseRecipe: PhotoRecipe?

    // MARK: - life cycle

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .failed("这台设备没有可用的 Metal 设备")
            return
        }
        self.device = device

        // The catalogue and the defaults, before the engine: a stock list that
        // depends on the engine's resources is a stock list that is empty when
        // the resources are missing, and an empty list is harder to diagnose
        // than an error.
        let resources = SpektraEngine.defaultResources()
        catalog = StockCatalog.load(resources: resources)
        loadLibrary()
        loadClipboardRecipe()

        for control in ParamCatalog.all {
            params[control.key] = control.defaultValue
        }

        do {
            let engine = try SpektraEngine(device: device, resources: resources)
            self.engine = engine
            self.renderer = CanvasRenderer(device: device)
            state = .empty
            statusText = "就绪 · \(catalog.films.count) 款胶片 · \(catalog.papers.count) 款相纸"
        } catch {
            // The CI build does not ship the resource archive inside the .app:
            // a 15 MB payload makes the side-loading installer fail when it
            // copies the unpacked IPA to its fixed `App.app`, and it reports
            // only "Failed to get bundle ID". The six-entry test bundle
            // installed fine, so the archive is fetched here once instead.
            state = .importing
            statusText = "首次启动：正在准备引擎资源…"
            Task { @MainActor in
                await self.prepareResourcesAndStart(device: device)
            }
        }
    }

    /// First-launch path: download the resources, unpack them, start the
    /// engine. Every launch after that finds the unpacked copy in Caches and
    /// never reaches the network.
    private func prepareResourcesAndStart(device: MTLDevice) async {
        do {
            let resources = try await SpektraEngine.fetchResourcesRemotely()
            catalog = StockCatalog.load(resources: resources)
            let engine = try SpektraEngine(device: device, resources: resources)
            self.engine = engine
            self.renderer = CanvasRenderer(device: device)
            state = .empty
            statusText = "就绪 · \(catalog.films.count) 款胶片 · \(catalog.papers.count) 款相纸"
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "资源准备失败"
        }
    }

    /// Puts the previous run's crash on screen, so it does not take another
    /// cycle of "it just closes" to find out what happened.
    private func reportPreviousCrash() {
        guard let crash = CrashLog.take() else { return }
        state = .failed("上次异常退出：\(crash)")
        statusText = "上次异常退出 · \(crash)"
    }

    // MARK: - importing

    /// Load original bytes, preferring a RAW representation when the picker
    /// exposes one. Plain `Data.self` is re-encoded by Photos for RAW assets.
    private static func loadData(from item: PhotosPickerItem) async throws -> Data {
        if let raw = try? await item.loadTransferable(type: PickedImageData.self)?.data,
           !raw.isEmpty {
            return raw
        }
        return try await item.loadTransferable(type: Data.self) ?? Data()
    }

    /// Import several photographs from Photos. Importing only fills the wall;
    /// it does not steal the screen by opening the first one.
    func importPickedItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        libraryBusy = "正在导入 0/\(items.count)"
        var imported = 0
        var failed = 0
        for (index, item) in items.enumerated() {
            libraryBusy = "正在导入 \(index + 1)/\(items.count)"
            do {
                let data = try await Self.loadData(from: item)
                guard !data.isEmpty else { throw DecodeError.unreadable("照片没有返回数据") }
                let hint = item.supportedContentTypes.first { $0.conforms(to: .rawImage) }
                    ?? item.supportedContentTypes.first
                    ?? ImageDecoder.inferredRAWTypeHint(for: data)
                let name = String(format: "照片 %02d", library.count + 1)
                try await addPhoto(data: data, name: name, typeHint: hint)
                imported += 1
            } catch {
                failed += 1
            }
            await Task.yield()
        }
        libraryBusy = nil
        libraryMessage = failed == 0
            ? "已导入 \(imported) 张照片"
            : "已导入 \(imported) 张，\(failed) 张无法读取"
    }

    /// Import one or more files, including the RAW containers Photos may only
    /// expose as a rendered preview.
    func importFiles(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        libraryBusy = "正在导入 0/\(urls.count)"
        var imported = 0
        var failed = 0
        for (index, url) in urls.enumerated() {
            libraryBusy = "正在导入 \(index + 1)/\(urls.count)"
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard !data.isEmpty else { throw DecodeError.unreadable("文件为空") }
                let hint = UTType(filenameExtension: url.pathExtension)
                try await addPhoto(data: data,
                                   name: url.deletingPathExtension().lastPathComponent,
                                   typeHint: hint)
                imported += 1
            } catch {
                failed += 1
            }
            await Task.yield()
        }
        libraryBusy = nil
        libraryMessage = failed == 0
            ? "已导入 \(imported) 张照片"
            : "已导入 \(imported) 张，\(failed) 张无法读取"
    }

    /// Single-file compatibility entry point for the DEBUG probe.
    func importFile(from url: URL) async {
        await importFiles(from: [url])
    }

    /// Put the bytes on disk, make the wall's thumbnail, and append the photo.
    @discardableResult
    private func addPhoto(data: Data, name: String, typeHint: UTType?) async throws -> UUID {
        let root = libraryRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let ext = typeHint?.preferredFilenameExtension ?? "img"
        let fileName = "\(id.uuidString).\(ext)"
        let originalURL = root.appendingPathComponent(fileName)
        try data.write(to: originalURL, options: .atomic)

        let made = LibraryThumbnail.from(data: data)
        let thumbnail = made?.0 ?? LibraryThumbnail.placeholder()
        let width = made?.1 ?? thumbnail.cgImage?.width ?? 0
        let height = made?.2 ?? thumbnail.cgImage?.height ?? 0
        try LibraryThumbnail.saveJPEG(thumbnail, to: thumbnailURL(for: id))

        let photo = LibraryPhoto(id: id,
                                 name: name,
                                 fileName: fileName,
                                 typeIdentifier: typeHint?.identifier,
                                 pixelWidth: width,
                                 pixelHeight: height,
                                 sourceAspect: Double(thumbnail.size.width / max(thumbnail.size.height, 1)),
                                 createdAt: Date(),
                                 recipe: PhotoRecipe.standard,
                                 isEdited: false,
                                 thumbnail: thumbnail)
        library.insert(photo, at: 0)
        saveLibraryManifest()
        return id
    }

    /// Decode and open one photograph in the editor's engine session. This is
    /// the old import path minus the library write: the photo already exists
    /// on the wall.
    private func loadPhoto(data: Data, typeHint: UTType?, name: String) async throws {
        sourceGeneration &+= 1
        effectReloadNeeded = false
        originalData = data
        originalTypeHint = typeHint
        let decoded = try ImageDecoder.decode(data: data,
                                              maxLongEdge: ImageDecoder.previewLongEdge,
                                              typeHint: typeHint)
        naturalAspect = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
        let framed = filmBorderEnabled
            ? decoded.centerCropped(toTargetAspect: filmCropAspect)
            : decoded
        try await loadFrame(framed)
        statusText = "已载入 \(name) · \(decoded.width)×\(decoded.height) · \(String(format: "%.1f", decoded.megapixels)) MP"
    }

    /// The look currently on the canvas, ready to be stored on a photo or
    /// copied to the wall's recipe clipboard.
    var currentRecipe: PhotoRecipe {
        PhotoRecipe(filmStock: filmStock,
                    printStock: printStock,
                    params: params,
                    filmBorderEnabled: filmBorderEnabled,
                    overscanFormat: overscanFormat,
                    stripOrientation: stripOrientation.rawValue,
                    dateBackEnabled: dateBackEnabled,
                    dateBackStyle: dateBackStyle.rawValue,
                    dateBackPlacement: dateBackPlacement.rawValue,
                    dateBackCorner: dateBackCorner.rawValue)
    }

    /// Every path that opens a session uses the same complete delta. The
    /// stocks are not enough: the film edge and date back are exposure on the
    /// negative, so leaving them out here would make the preview and export
    /// disagree with the controls.
    private func currentEngineDelta() -> [String: ParamValue] {
        currentRecipe.engineDelta(filmName: currentFilmName,
                                  imageAspect: naturalAspect,
                                  stamp: dateStampDate,
                                  shootingData: shootingDataText)
    }

    /// The delta for `spk_open` only. `product_defaults` selects the product's
    /// defaults at open time; `spk_set_params` does not accept the key, so it
    /// must not be part of `currentEngineDelta()`, which also feeds the live
    /// parameter updates.
    private func currentOpenDelta() -> [String: ParamValue] {
        var delta = currentEngineDelta()
        delta[ParamDefaults.productDefaultsKey] = .bool(true)
        return delta
    }

    // MARK: - the photo wall

    private static let clipboardRecipeKey = "SpektraLab.clipboardRecipe"
    private static let clipboardRecipeSourceKey = "SpektraLab.clipboardRecipeSource"

    private var libraryRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SpektraLabLibrary", isDirectory: true)
    }

    private func thumbnailURL(for id: UUID) -> URL {
        libraryRoot.appendingPathComponent("\(id.uuidString)-thumb.jpg")
    }

    private func originalURL(for photo: LibraryPhoto) -> URL {
        libraryRoot.appendingPathComponent(photo.fileName)
    }

    func filmName(for stock: String) -> String {
        films.first { $0.id == stock }?.name ?? stock
    }

    private func prepareLibraryRoot() {
        let root = libraryRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = root
        try? mutable.setResourceValues(values)
    }

    private func loadLibrary() {
        prepareLibraryRoot()
        guard let data = try? Data(contentsOf: libraryRoot.appendingPathComponent("library.json")),
              let entries = try? JSONDecoder().decode([LibraryManifestEntry].self, from: data)
        else { return }
        library = entries.compactMap { entry in
            let thumbURL = thumbnailURL(for: entry.id)
            guard let thumbnail = UIImage(contentsOfFile: thumbURL.path) else { return nil }
            return LibraryPhoto(id: entry.id,
                                name: entry.name,
                                fileName: entry.fileName,
                                typeIdentifier: entry.typeIdentifier,
                                pixelWidth: entry.pixelWidth,
                                pixelHeight: entry.pixelHeight,
                                sourceAspect: entry.sourceAspect,
                                createdAt: entry.createdAt,
                                recipe: entry.recipe,
                                isEdited: entry.isEdited,
                                thumbnail: thumbnail)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveLibraryManifest() {
        prepareLibraryRoot()
        let entries = library.map { photo in
            LibraryManifestEntry(id: photo.id,
                                 name: photo.name,
                                 fileName: photo.fileName,
                                 typeIdentifier: photo.typeIdentifier,
                                 pixelWidth: photo.pixelWidth,
                                 pixelHeight: photo.pixelHeight,
                                 sourceAspect: photo.sourceAspect,
                                 createdAt: photo.createdAt,
                                 recipe: photo.recipe,
                                 isEdited: photo.isEdited)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: libraryRoot.appendingPathComponent("library.json"), options: .atomic)
    }

    private func loadClipboardRecipe() {
        guard let data = UserDefaults.standard.data(forKey: Self.clipboardRecipeKey),
              let recipe = try? JSONDecoder().decode(PhotoRecipe.self, from: data)
        else { return }
        clipboardRecipe = recipe
        if let raw = UserDefaults.standard.string(forKey: Self.clipboardRecipeSourceKey),
           let id = UUID(uuidString: raw),
           library.contains(where: { $0.id == id }) {
            recipeSourcePhotoID = id
        }
    }

    private func saveClipboardRecipe(_ recipe: PhotoRecipe) {
        UserDefaults.standard.set(try? JSONEncoder().encode(recipe),
                                  forKey: Self.clipboardRecipeKey)
        if let recipeSourcePhotoID {
            UserDefaults.standard.set(recipeSourcePhotoID.uuidString,
                                      forKey: Self.clipboardRecipeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.clipboardRecipeSourceKey)
        }
    }

    /// Switch the editor's controls to a stored look. Missing parameter keys
    /// are filled from the catalogue by `normalizedParams`.
    private func apply(_ recipe: PhotoRecipe) {
        params = recipe.normalizedParams
        filmStock = films.contains { $0.id == recipe.filmStock }
            ? recipe.filmStock : StockCatalog.defaultFilm
        printStock = papers.contains { $0.id == recipe.printStock }
            ? recipe.printStock : StockCatalog.defaultPaper
        filmBorderEnabled = recipe.filmBorderEnabled
        overscanFormat = recipe.overscanFormat == FilmGateCatalog.automaticID
            || FilmGateCatalog.gate(id: recipe.overscanFormat) != nil
            ? recipe.overscanFormat : FilmGateCatalog.automaticID
        stripOrientation = FilmStripOrientation(rawValue: recipe.stripOrientation) ?? .automatic
        dateBackEnabled = recipe.dateBackEnabled
        dateBackStyle = DateBackStyle(rawValue: recipe.dateBackStyle) ?? .lcd
        dateBackPlacement = DateBackPlacement(rawValue: recipe.dateBackPlacement) ?? .frame
        dateBackCorner = DateBackCorner(rawValue: recipe.dateBackCorner) ?? .br
    }

    /// Open a wall photo in the editor. The wall stays on screen with a small
    /// progress label until the engine has the first preview, so the editor
    /// never appears as an empty "add a photo" screen.
    func openLibraryPhoto(_ id: UUID) async {
        guard libraryBusy == nil,
              let photo = library.first(where: { $0.id == id }) else { return }
        guard engine != nil else {
            libraryMessage = "引擎还在准备，请稍后再试"
            return
        }
        libraryBusy = "正在打开 \(photo.name)…"
        apply(photo.recipe)
        dateStampDate = photo.createdAt
        shootingDataText = "1/125  F2.8  ISO 400  50mm"
        editingBaseRecipe = photo.recipe
        do {
            let data = try Data(contentsOf: originalURL(for: photo), options: [.mappedIfSafe])
            let hint = photo.typeIdentifier.flatMap(UTType.init)
            try await loadPhoto(data: data, typeHint: hint, name: photo.name)
            editingPhotoID = id
            libraryBusy = nil
            libraryMessage = nil
        } catch {
            libraryBusy = nil
            libraryMessage = "无法打开 \(photo.name)：\(error.localizedDescription)"
            state = .failed(error.localizedDescription)
        }
    }

    /// Leave the editor and put the current look back on the wall. The recipe
    /// is saved synchronously; the thumbnail is refreshed right after, so
    /// returning never waits for a second render.
    func closeEditor() {
        guard let id = editingPhotoID else { return }
        let recipe = currentRecipe
        let changed = recipe != editingBaseRecipe
        if let index = library.firstIndex(where: { $0.id == id }) {
            library[index].recipe = recipe
            library[index].isEdited = library[index].isEdited || changed
        }
        saveLibraryManifest()
        renderTask?.cancel()
        editingPhotoID = nil
        editingBaseRecipe = nil
        libraryMessage = nil
        Task { @MainActor [weak self] in
            await self?.refreshThumbnail(for: id, recipe: recipe)
        }
    }

    /// Copy one photo's look for the paste action. The recipe is also written
    /// to the app's own clipboard (and the system pasteboard as JSON), so it
    /// survives a relaunch without reading the user's pasteboard unasked.
    func copyRecipe(from id: UUID) {
        guard let photo = library.first(where: { $0.id == id }) else { return }
        clipboardRecipe = photo.recipe
        recipeSourcePhotoID = id
        saveClipboardRecipe(photo.recipe)
        libraryMessage = "已复制 \(filmName(for: photo.recipe.filmStock)) 配方"
        if let data = try? JSONEncoder().encode(photo.recipe) {
            UIPasteboard.general.string = "spektralab-recipe:v1:" + data.base64EncodedString()
        }
    }

    /// Apply the copied look to every selected photo and refresh each wall
    /// thumbnail. This is serial on purpose: one engine session is reused, so
    /// a hundred selected photos do not become a hundred GPU sessions.
    func pasteRecipe(to ids: Set<UUID>) async {
        guard let recipe = clipboardRecipe else {
            libraryMessage = "先在一张照片上复制配方"
            return
        }
        let targets = library.filter {
            ids.contains($0.id) && $0.id != recipeSourcePhotoID
        }
        guard !targets.isEmpty else { return }
        libraryBusy = "正在粘贴配方 0/\(targets.count)"
        var failed = 0
        for (offset, target) in targets.enumerated() {
            libraryBusy = "正在粘贴配方 \(offset + 1)/\(targets.count)"
            guard let index = library.firstIndex(where: { $0.id == target.id }) else { continue }
            library[index].recipe = recipe
            library[index].isEdited = true
            do {
                let image = try await renderThumbnail(for: library[index], recipe: recipe)
                library[index].thumbnail = image
                try LibraryThumbnail.saveJPEG(image, to: thumbnailURL(for: target.id))
            } catch {
                failed += 1
            }
            await Task.yield()
        }
        saveLibraryManifest()
        libraryBusy = nil
        libraryMessage = failed == 0
            ? "已把配方粘贴到 \(targets.count) 张照片"
            : "已粘贴 \(targets.count - failed) 张，\(failed) 张缩略图未更新"
    }

    /// Delete photos and their on-disk originals. The manifest is rewritten
    /// after the files are gone, so a crash mid-delete leaves either an entry
    /// with a missing file (skipped on next launch) or no entry at all.
    func deletePhotos(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let photo = library.first(where: { $0.id == id }) {
                try? FileManager.default.removeItem(at: originalURL(for: photo))
            }
            try? FileManager.default.removeItem(at: thumbnailURL(for: id))
        }
        if let editing = editingPhotoID, ids.contains(editing) {
            editingPhotoID = nil
            editingBaseRecipe = nil
        }
        if let source = recipeSourcePhotoID, ids.contains(source) {
            recipeSourcePhotoID = nil
            UserDefaults.standard.removeObject(forKey: Self.clipboardRecipeSourceKey)
        }
        library.removeAll { ids.contains($0.id) }
        saveLibraryManifest()
        libraryMessage = "已删除 \(ids.count) 张照片"
    }

    func clearLibraryMessage() {
        libraryMessage = nil
    }

    private func refreshThumbnail(for id: UUID, recipe: PhotoRecipe) async {
        guard let index = library.firstIndex(where: { $0.id == id }) else { return }
        let previousBusy = libraryBusy
        libraryBusy = "正在更新缩略图…"
        defer { libraryBusy = previousBusy }
        guard let image = try? await renderThumbnail(for: library[index], recipe: recipe) else { return }
        guard let current = library.firstIndex(where: { $0.id == id }) else { return }
        library[current].thumbnail = image
        try? LibraryThumbnail.saveJPEG(image, to: thumbnailURL(for: id))
        saveLibraryManifest()
    }

    /// Render one wall-sized print through the real engine. `preview_long_edge`
    /// is set to the thumbnail size, so this is a lookup-sized render rather
    /// than a full live-tier one per photo.
    private func renderThumbnail(for photo: LibraryPhoto, recipe: PhotoRecipe) async throws -> UIImage {
        guard let engine else { throw EngineError.failed(status: -1, message: "引擎没有启动") }
        let data = try Data(contentsOf: originalURL(for: photo), options: [.mappedIfSafe])
        let hintID = photo.typeIdentifier
        let decoded = try await Task.detached(priority: .userInitiated) {
            try ImageDecoder.decode(data: data,
                                    maxLongEdge: 1400,
                                    typeHint: hintID.flatMap(UTType.init))
        }.value
        let sourceAspect = CGFloat(photo.sourceAspect)
        let gate = FilmGateCatalog.resolve(selection: recipe.overscanFormat,
                                           imageAspect: sourceAspect)
        let orientation = FilmStripOrientation(rawValue: recipe.stripOrientation) ?? .automatic
        let framed = recipe.filmBorderEnabled
            ? decoded.centerCropped(toTargetAspect: orientation.targetAspect(for: gate,
                                                                            sourceAspect: sourceAspect))
            : decoded
        var delta = recipe.engineDelta(filmName: filmName(for: recipe.filmStock),
                                       imageAspect: sourceAspect,
                                       stamp: photo.createdAt,
                                       shootingData: "1/125  F2.8  ISO 400  50mm")
        delta[ParamDefaults.productDefaultsKey] = .bool(true)
        delta["preview_long_edge"] = .number(900)
        let openDelta = delta
        let bitmap = try await engine.perform {
            try framed.pixels.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    throw EngineError.failed(status: -1, message: "解码结果为空")
                }
                _ = try engine.open(pixels: EnginePixels(data: base,
                                                         width: framed.width,
                                                         height: framed.height),
                                    params: openDelta)
            }
            try engine.solve(target: "both")
            return try engine.renderBitmap(tier: "live", reprint: false)
        }
        return LibraryThumbnail.downscale(bitmap.cgImage)
    }

    /// Load an already-decoded frame: open a session and render the first
    /// preview.
    private func loadFrame(_ decoded: DecodedFrame) async throws {
        guard let engine else { throw EngineError.failed(status: -1, message: "引擎没有启动") }
        frame = decoded
        sourceSize = CGSize(width: decoded.width, height: decoded.height)

        // Open with the current stocks and parameters, so the first preview
        // already shows what the user chose.
        let openDelta = currentOpenDelta()

        // The pointer has to stay alive across the `open` call: the engine
        // borrows the pixels for the duration of that call and copies what it
        // keeps, so the buffer must not go out of scope before it returns.
        // Taking the address inside a closure and using it outside would
        // leave it dangling -- which reads as a frame of noise rather than
        // as a crash, and is much harder to find.
        let reply = try await engine.perform {
            try decoded.pixels.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    throw EngineError.failed(status: -1, message: "解码结果为空")
                }
                return try engine.open(pixels: EnginePixels(
                    data: base,
                    width: decoded.width,
                    height: decoded.height), params: openDelta)
            }
        }

        if let meta = reply.meta, let w = meta.width, let h = meta.height {
            sourceSize = CGSize(width: w, height: h)
        }

        // The solve must happen before the first render, or the print uses
        // default exposure and the highlights blow out — which looks like a
        // rendering bug and is not one.
        try await engine.perform { try engine.solve(target: "both") }

        await renderNow()
    }

    // MARK: - parameters

    /// Dismiss an error notice without losing the picture already on screen.
    func dismissFailure() {
        if case .failed = state {
            state = renderedTexture == nil ? .empty : .ready
        }
    }

    /// A parameter changed. Mark the render stale and schedule one.
    func parameterChanged(_ key: String, _ value: Double) {
        params[key] = value
        paramsDirty = true
        scheduleRender()
    }

    /// Turn the physical film edge on or off. The picture has to be re-opened
    /// with the gate's aspect ratio: the engine refuses a crop that is not the
    /// selected format's shape, and stretching an edge around the old frame
    /// would not be the same negative.
    func setFilmBorderEnabled(_ enabled: Bool) {
        guard filmBorderEnabled != enabled else { return }
        filmBorderEnabled = enabled
        if !enabled && dateBackPlacement == .rebate {
            dateBackPlacement = .frame
        }
        reloadPreviewForFilmEffect()
    }

    /// Pick an explicit gate, or automatic matching against the photograph.
    func setOverscanFormat(_ id: String) {
        guard id == FilmGateCatalog.automaticID || FilmGateCatalog.gate(id: id) != nil else { return }
        overscanFormat = id
        if selectedGate.isSquare && stripOrientation != .automatic {
            stripOrientation = .automatic
        }
        if !selectedGate.supportsDateBack {
            dateBackEnabled = false
            dateBackPlacement = .frame
        }
        if filmBorderEnabled { reloadPreviewForFilmEffect() }
    }

    /// Choose which way the strip runs. The frame is re-cropped to the chosen
    /// orientation, so a horizontal choice on a portrait source selects a
    /// horizontal slice of the photograph and the engine builds a horizontal
    /// strip around it. It never rotates the picture or fakes the rebate.
    func setStripOrientation(_ orientation: FilmStripOrientation) {
        guard stripOrientation != orientation else { return }
        guard !selectedGate.isSquare || orientation == .automatic else { return }
        stripOrientation = orientation
        if filmBorderEnabled { reloadPreviewForFilmEffect() }
    }

    func setDateBackEnabled(_ enabled: Bool) {
        guard enabled == false || selectedGate.supportsDateBack else { return }
        dateBackEnabled = enabled
        if enabled && !filmBorderEnabled { dateBackPlacement = .frame }
        scheduleEffectRender()
    }

    func setDateBackStyle(_ style: DateBackStyle) {
        dateBackStyle = style
        scheduleEffectRender()
    }

    func setDateBackPlacement(_ placement: DateBackPlacement) {
        dateBackPlacement = (placement == .rebate && filmBorderEnabled) ? .rebate : .frame
        scheduleEffectRender()
    }

    func setDateBackCorner(_ corner: DateBackCorner) {
        dateBackCorner = corner
        scheduleEffectRender()
    }

    func setDateStampDate(_ date: Date) {
        guard date != dateStampDate else { return }
        dateStampDate = date
        scheduleEffectRender()
    }

    func setShootingDataText(_ text: String) {
        guard text != shootingDataText else { return }
        shootingDataText = text
        scheduleEffectRender()
    }

    private func scheduleEffectRender() {
        guard frame != nil else { return }
        paramsDirty = true
        scheduleRender()
    }

    /// A gate change has to reload the preview because the crop is applied
    /// before the engine sees the frame. A toggle-off reloads the full frame,
    /// restoring the part the rebate had cropped away.
    private func reloadPreviewForFilmEffect() {
        guard originalData != nil else {
            scheduleEffectRender()
            return
        }
        effectReloadNeeded = true
        guard !effectReloadRunning else { return }
        effectReloadRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.effectReloadNeeded {
                self.effectReloadNeeded = false
                self.state = .importing
                self.statusText = self.filmBorderEnabled
                    ? "正在裁切到 \(self.gateDisplayName)…"
                    : "正在恢复完整画面…"
                do {
                    guard let data = self.originalData else { break }
                    let sourceGeneration = self.sourceGeneration
                    let hint = self.originalTypeHint
                    let decoded = try await Task.detached(priority: .userInitiated) {
                        try ImageDecoder.decode(data: data,
                                                maxLongEdge: ImageDecoder.previewLongEdge,
                                                typeHint: hint)
                    }.value
                    guard sourceGeneration == self.sourceGeneration else { continue }
                    self.naturalAspect = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
                    let gate = self.selectedGate
                    if !gate.supportsDateBack {
                        self.dateBackEnabled = false
                        self.dateBackPlacement = .frame
                    }
                    let framed = self.filmBorderEnabled
                        ? decoded.centerCropped(toTargetAspect: self.filmCropAspect)
                        : decoded
                    try await self.loadFrame(framed)
                } catch {
                    self.state = .failed(error.localizedDescription)
                    self.statusText = "片边载入失败"
                }
            }
            self.effectReloadRunning = false
            if self.effectReloadNeeded { self.reloadPreviewForFilmEffect() }
        }
    }

    /// The film changed: reopen, because the stock is a session-level choice.
    func filmChanged(_ stock: String) {
        filmStock = stock
        // Offer the paper that goes with this film, if the engine has a
        // preview table paired with it.
        if let paired = StockCatalog.pairedPaper(forFilm: stock, in: engine?.resources ?? SpektraEngine.defaultResources()) {
            printStock = paired
        }
        reopenAndRender()
    }

    /// The paper changed: reopen, for the same reason.
    func paperChanged(_ stock: String) {
        printStock = stock
        reopenAndRender()
    }

    /// Reopen the session with the current stocks and parameters.
    private func reopenAndRender() {
        guard let frame, let engine else { return }
        let openDelta = currentOpenDelta()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await engine.perform {
                    // The pointer has to outlive the call: the engine borrows
                    // the pixels for the duration of `open` and copies what
                    // it keeps.
                    try frame.pixels.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else {
                            throw EngineError.failed(status: -1, message: "解码结果为空")
                        }
                        _ = try engine.open(pixels: EnginePixels(
                            data: base,
                            width: frame.width,
                            height: frame.height), params: openDelta)
                    }
                    try engine.solve(target: "both")
                }
                self.paramsDirty = false
                self.scheduleRender()
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - the render loop

    /// Ask for a render. It runs when the current one is done and the user
    /// has stopped moving.
    func scheduleRender() {
        needsRender = true
        guard !renderInFlight else { return }
        // `@MainActor` on the closure: `Task { ... }` is `@Sendable` by
        // default, and a closure that captures a `MainActor`-isolated
        // `ViewModel` is not Sendable unless the closure says where it
        // runs. Without this, Swift 6's strict concurrency rejects it.
        renderTask = Task { @MainActor [weak self] in
            // A short settle, so a drag does not render on every frame. The
            // preview is a reprint of a cached negative — fast — but not free.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            await self?.renderNow()
        }
    }

    /// Render now, one at a time.
    private func renderNow() async {
        guard renderInFlight == false else { return }
        guard let engine, let renderer else { return }
        guard frame != nil else { return }

        // This render is consuming the request that is currently pending.
        // A change made while it is awaiting the engine sets the flag again.
        needsRender = false
        renderInFlight = true
        defer {
            renderInFlight = false
            // A request that arrived while this render was running runs now.
            if needsRender {
                scheduleRender()
            }
        }

        state = .rendering

        do {
            let dirty = paramsDirty
            let changed = currentEngineDelta()
            let result = try await engine.perform {
                if dirty {
                    _ = try engine.setParams(changed)
                    // The exposure has to be recomputed when the
                    // compensation changed, or the print keeps the old EV.
                    try engine.solve(target: "both")
                }

                // `live` is the interactive tier: the engine renders at the
                // live long edge (2048 px), which is what a phone screen can
                // show.
                return try engine.render(tier: "live", reprint: true)
            }
            if dirty { paramsDirty = false }
            renderer.setTexture(result.texture)
            renderedTexture = result.texture
            renderIdentity = result.progressID.isEmpty
                ? UUID().uuidString
                : result.progressID
            lastRenderMs = result.elapsedMs
            state = .ready
            statusText = String(format: "渲染完成 · %.0f ms · %d×%d",
                                result.elapsedMs, result.width, result.height)
        } catch {
            // The state stays `.failed`. It used to be forced back to `.ready`
            // right here, which is the worst possible outcome: no error shown,
            // `renderedTexture` nil, and every slider disabled with no
            // explanation.
            state = .failed(error.localizedDescription)
            statusText = "渲染失败：\(error.localizedDescription)"
        }
    }

    // MARK: - exporting

    /// Export the print to the photo library.
    ///
    /// Decode the source at its original resolution and render in strips.
    func exportToPhotos() async {
        guard let engine, let originalData else {
            statusText = "还没有可导出的照片"
            return
        }
        state = .importing
        statusText = "正在导出高质量 JPEG…"

        do {
            let data = originalData
            let hint = originalTypeHint
            let cropAspect = filmBorderEnabled ? filmCropAspect : nil
            // Decoding a RAW container is CPU-heavy. Do it off the main actor
            // so the export sheet keeps moving and the UI never freezes.
            let full = try await Task.detached(priority: .userInitiated) {
                try ImageDecoder.decode(data: data,
                                        maxLongEdge: ImageDecoder.exportLongEdge,
                                        typeHint: hint,
                                        targetAspect: cropAspect)
            }.value

            let exportDelta = currentOpenDelta()

            // Open, solve and render are one unit on the engine's serial
            // queue. `full` stays alive only until `open` copies it; the
            // exported image then owns the engine's 16-bit rows directly.
            let bitmap = try await engine.perform {
                try full.pixels.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else {
                        throw EngineError.failed(status: -1, message: "解码结果为空")
                    }
                    _ = try engine.open(pixels: EnginePixels(
                        data: base,
                        width: full.width,
                        height: full.height), params: exportDelta)
                }
                try engine.solve(target: "both")
                return try engine.renderBitmap(tier: "full", reprint: false)
            }

            // Encode on a background task as well: JPEG compression is the
            // second-long part after a 24 MP render and does not need the main
            // actor. No UIImage and no full-size JPEG Data are created.
            let cgImage = bitmap.cgImage
            let jpegURL = try await Task.detached(priority: .userInitiated) {
                try Self.writeJPEG(from: cgImage)
            }.value
            try await PhotoLibrary.saveJPEG(at: jpegURL)

            statusText = String(format: "已导出 %d×%d 到相册", bitmap.width, bitmap.height)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "导出失败"
        }
    }

    /// Write the engine's 16-bit sRGB image as a JPEG.
    ///
    /// `cgImage` already owns the engine rows through its data provider, so
    /// ImageIO can encode straight from those pixels. The previous path read
    /// the Metal texture into a CPU array and converted every pixel to RGBA8;
    /// that array, plus the 8-bit Data buffer, was roughly 500 MB at 24 MP and
    /// was the cause of the export-time jetsam kills.
    private nonisolated static func writeJPEG(from cgImage: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraLab-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1, nil) else {
            throw ExportError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.encodingFailed
        }
        return url
    }

}

/// RAW 原始文件字节（ARW/CR3/DNG…）。优先按 `rawImage` 取原始数据；普通照片
/// 回退到 `image`。`PhotosPickerItem.loadTransferable(type: Data.self)` 对于
/// RAW 只能拿到渲染后的位图，拿不到原始字节，所以这里用自定义 Transferable。
///
/// The `importedContentType:` label is the one this SDK expects; the older
/// `importedAs:` is not a parameter of `DataRepresentation` any more, and
/// writing it is a compile error rather than a deprecation.
struct PickedImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .rawImage) { Self(data: $0) }
        DataRepresentation(importedContentType: .image) { Self(data: $0) }
    }
}

/// Saving to the photo library, with the permission the app needs.
enum PhotoLibrary {
    /// Ask for permission and save.
    static func saveJPEG(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.permissionDenied
        }
        defer { try? FileManager.default.removeItem(at: url) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset()
                .addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}

enum ExportError: Error, CustomStringConvertible {
    case permissionDenied
    case encodingFailed
    var description: String {
        switch self {
        case .permissionDenied: "没有相册写入权限，请在系统设置里允许"
        case .encodingFailed: "照片编码失败，无法导出 JPEG"
        }
    }
}
