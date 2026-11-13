//  PhotoLibraryView.swift — the wall the app opens to.
//
//  The editor is a place you visit, not the app's front door. Importing fills
//  this wall; tapping a print opens it in the editor; going back saves the look
//  and refreshes its thumbnail. Recipes are copied from one print and pasted
//  onto a multi-selection, like a contact sheet with one grade.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The three explicit import routes. A file/folder picker cannot be presented
/// while another sheet is on screen, so the chooser records a route and the
/// wall presents it after the chooser has fully disappeared.
enum ImportRoute: String, Identifiable {
    case photos
    case files
    case folder
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var model: ViewModel
    @State private var showingCrashNotice = false

    var body: some View {
        // Inject the real available width once. Every screen reads
        // `labCompact`, so an iPhone SE (375pt / 320pt) gets tighter chrome
        // without hard-coding a device model or touching UIScreen.
        GeometryReader { geo in
            rootContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.labCompact, geo.size.width <= 390)
        }
    }

    private var rootContent: some View {
        Group {
            if model.editingPhotoID != nil {
                EditorView()
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
            } else {
                PhotoLibraryView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.editingPhotoID)
        .preferredColorScheme(.dark)
        // A jetsam kill has no crash report the app can catch. Show the
        // breadcrumb left before the stage that died, on the front door, so
        // the next launch says where it stopped instead of reopening silently.
        .alert("上次异常退出", isPresented: $showingCrashNotice) {
            Button("好", role: .cancel) { model.clearCrashNotice() }
        } message: {
            Text(model.crashNotice ?? "")
        }
        .onAppear {
            if model.crashNotice != nil { showingCrashNotice = true }
        }
#if DEBUG
        .task {
            let environment = ProcessInfo.processInfo.environment
            let libraryPaths = (environment["SPEKTRAFILM_UI_TEST_LIBRARY_PATHS"] ?? "")
                .split(separator: "|")
                .map { URL(fileURLWithPath: String($0)) }
            if !libraryPaths.isEmpty {
                await model.importFiles(from: libraryPaths)
            } else if let path = environment["SPEKTRAFILM_UI_TEST_PATH"], !path.isEmpty,
                      model.library.isEmpty {
                await model.importFile(from: URL(fileURLWithPath: path))
            }
            if environment["SPEKTRAFILM_UI_TEST_IMPORT_ONLY"] != "1",
               let first = model.library.first {
                await model.openLibraryPhoto(first.id)
            }
            if let value = environment["SPEKTRAFILM_UI_TEST_CLOSE_AFTER"],
               let seconds = Double(value) {
                try? await Task.sleep(for: .seconds(seconds))
                model.closeEditor()
                try? await Task.sleep(for: .seconds(2))
            }
            if environment["SPEKTRAFILM_UI_TEST_COPY_FIRST"] == "1",
               let first = model.library.first {
                model.copyRecipe(from: first.id)
                try? await Task.sleep(for: .seconds(1))
            }
            if environment["SPEKTRAFILM_UI_TEST_PASTE_ALL"] == "1" {
                await model.pasteRecipe(to: Set(model.library.map(\.id)))
            }
        }
#endif
    }
}

struct PhotoLibraryView: View {
    @EnvironmentObject private var model: ViewModel
    @Environment(\.labCompact) private var compact
    @State private var pickerItems: [PhotosPickerItem] = []
    // One document picker, switched between file and folder mode. Two
    // sibling .fileImporter presentations fight on iOS 16.
    @State private var showingDocumentPicker = false
    @State private var documentPickerIsFolder = false
    @State private var showingImportSheet = false
    @State private var pendingImportRoute: ImportRoute? = nil
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var deleteIDs: Set<UUID> = []
    @State private var showingDelete = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: compact ? 3 : 4, alignment: .top),
              count: 3)
    }

    private func presentDocuments(folder: Bool) {
        documentPickerIsFolder = folder
        showingDocumentPicker = true
    }

    private var selectablePhotoIDs: Set<UUID> {
        var ids = Set(model.library.map(\.id))
        if let source = model.recipeSourcePhotoID {
            ids.remove(source)
        }
        return ids
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LabBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let recipe = model.clipboardRecipe {
                        clipboardBanner(recipe)
                    }
                    if model.library.isEmpty {
                        emptyState
                    } else {
                        sectionHeader
                        wall
                    }
                }
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.top, compact ? 6 : 10)
                .padding(.bottom, selecting ? (compact ? 138 : 148)
                         : (model.library.isEmpty ? (compact ? 32 : 44)
                            : (compact ? 114 : 124)))
            }
            .scrollIndicators(.hidden)

            if selecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            } else if !model.library.isEmpty {
                filmWorkbench
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }

            if let message = model.libraryMessage {
                toast(message)
                    .padding(.horizontal, 20)
                    .padding(.bottom, selecting ? 128 : (model.library.isEmpty ? 18 : 108))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }

            if let busy = model.libraryBusy {
                busyOverlay(busy)
                    .transition(.opacity)
                    .zIndex(4)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selecting)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: selected)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: model.libraryMessage)
        .animation(.easeInOut(duration: 0.18), value: model.libraryBusy)
        .labSelectionFeedback(trigger: selected)
        .onChange(of: model.recipeSourcePhotoID) { source in
            if let source {
                selected.remove(source)
            }
        }
        .fileImporter(isPresented: $showingDocumentPicker,
                      allowedContentTypes: documentPickerIsFolder
                          ? [.folder] : [.image, .rawImage],
                      allowsMultipleSelection: !documentPickerIsFolder) { result in
            guard case .success(let urls) = result else { return }
            // ViewModel.importFiles expands a picked folder into its image
            // files while the folder's security scope is still held.
            Task { @MainActor in await model.importFiles(from: urls) }
        }
        .sheet(isPresented: $showingImportSheet) {
            ImportSourcesSheet(pickerItems: $pickerItems, route: $pendingImportRoute)
        }
        .onChange(of: showingImportSheet) { presented in
            guard !presented, let route = pendingImportRoute else { return }
            pendingImportRoute = nil
            Task { @MainActor in
                // Let the chooser finish dismissing before presenting the
                // document picker; two simultaneous presentations fight.
                try? await Task.sleep(for: .milliseconds(220))
                guard route != .photos else { return }  // PhotosPicker handles it
                presentDocuments(folder: route == .folder)
            }
        }
        .confirmationDialog("删除这些照片？",
                            isPresented: $showingDelete,
                            titleVisibility: .visible) {
            Button("删除 \(deleteIDs.count) 张照片", role: .destructive) {
                model.deletePhotos(deleteIDs)
                selected.subtract(deleteIDs)
                deleteIDs = []
                if model.library.isEmpty { selecting = false }
            }
            Button("取消", role: .cancel) { deleteIDs = [] }
        } message: {
            Text("原图和缩略图都会从 SpektraLab 的照片库移除，不会影响系统相册。")
        }
        .task(id: model.libraryMessage) {
            guard model.libraryMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            model.clearLibraryMessage()
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SPEKTRA LAB")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Color.labRed.opacity(0.82))
                Text(selecting ? "选择照片" : "照片库")
                    .font(.system(size: compact ? 27 : 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Color.labCream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.labCream.opacity(0.48))
                    .lineLimit(1)
            }
            Spacer(minLength: compact ? 4 : 8)
            LabGlassContainer(spacing: compact ? 5 : 8) {
                HStack(spacing: compact ? 5 : 8) {
                    if !model.library.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.20, dampingFraction: 0.82)) {
                                selecting.toggle()
                                if !selecting { selected.removeAll() }
                            }
                        } label: {
                            Image(systemName: selecting ? "xmark" : "checkmark.circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.labCream)
                                .frame(width: 44, height: 44)
                                .labGlassInteractive(in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(selecting ? "结束选择" : "选择照片")
                    }

                    if !selecting {
                        // One visible button opens the import chooser --
                        // previously the folder route was hidden behind a
                        // long press, which nobody could discover.
                        Button {
                            showingImportSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.labCream)
                                .frame(width: 44, height: 44)
                                .labGlassInteractive(in: Circle())
                        }
                        .buttonStyle(.plain)
                        .tint(Color.labCream)
                        .accessibilityLabel("选择导入方式")
                        .contextMenu {
                            Button {
                                presentDocuments(folder: false)
                            } label: {
                                Label("快速选择文件", systemImage: "doc.badge.plus")
                            }
                            Button {
                                presentDocuments(folder: true)
                            } label: {
                                Label("快速选择文件夹", systemImage: "folder")
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty else { return }
            showingImportSheet = false
            Task { @MainActor in
                await model.importPickedItems(items)
                pickerItems = []
            }
        }
    }

    private var subtitle: String {
        let edited = model.library.filter(\.isEdited).count
        if model.library.isEmpty { return "导入一组照片，统一调色" }
        if selecting {
            return selected.isEmpty ? "轻点照片进行多选" : "已选 \(selected.count) 张 · 共 \(model.library.count) 张"
        }
        return "\(model.library.count) 张照片 · \(edited) 张已调色"
    }

    private func clipboardBanner(_ recipe: PhotoRecipe) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.labCream.opacity(0.58))
            Text("剪贴板配方")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.labCream.opacity(0.48))
            Text(model.filmName(for: recipe.filmStock))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.labCream.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Text(model.recipeSourcePhotoID != nil
                 ? "来源照片已锁定"
                 : (selecting ? "选择后粘贴" : "长按照片可复制"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.labCream.opacity(0.38))
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .labGlass(in: Capsule())
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(selecting ? "轻点以选择" : "全部照片")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.labCream.opacity(0.76))
            Spacer()
            Text(selecting ? "\(selected.count) / \(model.library.count)" : "长按管理")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Color.labCream.opacity(0.34))
        }
        .padding(.horizontal, 1)
    }

    /// The wall's editing dock. It keeps the measured film rolls visible at
    /// all times, so the library reads as a darkroom rather than a gallery.
    private var filmWorkbench: some View {
        HStack(spacing: compact ? 6 : 9) {
            // On a 375pt SE the 80pt caption plus divider left too little
            // room for the film strip, so the compact dock shows only the
            // scrollable rolls and the edit action.
            if !compact {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "film")
                            .font(.system(size: 10, weight: .semibold))
                        Text("胶片实验室")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.labCream.opacity(0.88))
                    Text("点按直接试色")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Color.labCream.opacity(0.38))
                }
                .frame(width: 80, alignment: .leading)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 34)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(model.films) { stock in
                            Button {
                                openQuickEdit(with: stock)
                            } label: {
                                VStack(spacing: 2) {
                                    StockArtwork(stock: stock)
                                        .frame(width: 34, height: 42)
                                        .overlay(alignment: .topTrailing) {
                                            if stock.id == model.filmStock {
                                                Circle()
                                                    .fill(Color.labRed)
                                                    .frame(width: 5, height: 5)
                                                    .offset(x: 2, y: -2)
                                            }
                                        }
                                    Text(compactStockName(stock))
                                        .font(.system(size: 7.5, weight: .medium))
                                        .foregroundStyle(stock.id == model.filmStock
                                                         ? Color.labCream.opacity(0.88)
                                                         : Color.labCream.opacity(0.40))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(width: 50)
                                }
                                .frame(width: 50, height: 58)
                            }
                            .buttonStyle(.plain)
                            .id(stock.id)
                            .accessibilityLabel("使用 \(stock.name) 编辑最新照片")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onAppear {
                    proxy.scrollTo(model.filmStock, anchor: .center)
                }
                .onChange(of: model.filmStock) { stock in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(stock, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)

            Button {
                openQuickEdit(with: nil)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                    Text("调色")
                        .font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(Color.labCream)
                .frame(width: 44, height: 52)
                .background(Color.labRed.opacity(0.22),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑最新照片")
        }
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 6 : 9)
        .labGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 24, y: 10)
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.bottom, 6)
    }

    private func compactStockName(_ stock: Stock) -> String {
        var name = stock.name
        for prefix in ["Kodak ", "Fujifilm ", "Ilford ", "CineStill "] {
            name = name.replacingOccurrences(of: prefix, with: "")
        }
        let words = name.split(separator: " ")
        return words.prefix(2).joined(separator: " ")
    }

    private func openQuickEdit(with stock: Stock?) {
        guard let photo = model.library.first else { return }
        Task { @MainActor in
            await model.openLibraryPhoto(photo.id)
            guard model.editingPhotoID != nil else { return }
            if let stock {
                model.filmChanged(stock.id)
            }
        }
    }

    // MARK: - the wall

    private var wall: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(model.library) { photo in
                photoTile(photo)
                    .contextMenu {
                        Button {
                            Task { @MainActor in await model.openLibraryPhoto(photo.id) }
                        } label: {
                            Label("编辑", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            copyRecipe(from: photo.id)
                        } label: {
                            Label("复制配方", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteIDs = [photo.id]
                            showingDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func photoTile(_ photo: LibraryPhoto) -> some View {
        let isSelected = selected.contains(photo.id)
        let isRecipeSource = model.recipeSourcePhotoID == photo.id
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        return Color.labPanel
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottom) {
                    Image(uiImage: photo.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .saturation(isRecipeSource ? 0.12 : 1)

                    if photo.isEdited {
                        LinearGradient(colors: [.clear, .black.opacity(0.62)],
                                       startPoint: .center, endPoint: .bottom)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.labRed.opacity(0.92))
                                .frame(width: 4, height: 4)
                            Text(model.filmName(for: photo.recipe.filmStock))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .padding(.bottom, 7)
                    }

                    if isSelected {
                        Color.labRed.opacity(0.10)
                    }
                    if isRecipeSource {
                        Color.black.opacity(selecting ? 0.34 : 0.24)
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(isSelected ? Color.labRed : Color.white.opacity(0.055),
                                   lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    if isRecipeSource {
                        ZStack {
                            Circle().fill(Color.black.opacity(0.48))
                            Circle().strokeBorder(Color.white.opacity(0.40), lineWidth: 1)
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.82))
                        }
                        .frame(width: 22, height: 22)
                        .padding(6)
                    } else {
                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.labRed : Color.black.opacity(0.28))
                            Circle()
                                .strokeBorder(Color.white.opacity(isSelected ? 0 : 0.72), lineWidth: 1.5)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                        .padding(6)
                    }
                } else if isRecipeSource {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.46))
                        Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.78))
                    }
                    .frame(width: 22, height: 22)
                    .padding(6)
                } else if photo.isEdited {
                    Menu {
                        Button {
                            Task { @MainActor in await model.openLibraryPhoto(photo.id) }
                        } label: {
                            Label("编辑", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            copyRecipe(from: photo.id)
                        } label: {
                            Label("复制配方", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            deleteIDs = [photo.id]
                            showingDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .labGlassInteractive(in: Circle())
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .topLeading) {
                if isRecipeSource {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 7, weight: .bold))
                        Text("配方来源")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Color.white.opacity(0.82))
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(Color.black.opacity(0.42), in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1)
                    }
                    .padding(6)
                }
            }
            .contentShape(shape)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(photo.name)
            .accessibilityValue(isRecipeSource ? "配方来源，已锁定"
                                : (isSelected ? "已选择" : ""))
            .onTapGesture {
                if selecting {
                    guard !isRecipeSource else { return }
                    if isSelected { selected.remove(photo.id) } else { selected.insert(photo.id) }
                } else {
                    Task { @MainActor in await model.openLibraryPhoto(photo.id) }
                }
            }
    }

    // MARK: - selection

    private var selectionBar: some View {
        VStack(spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.isEmpty ? "选择照片" : "已选 \(selected.count) 张")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.labCream)
                        .contentTransition(.numericText())
                    Text(model.clipboardRecipe == nil
                         ? "长按照片可复制配方"
                         : "配方来源已灰显锁定")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.labCream.opacity(0.40))
                }
                Spacer()
                Button {
                    selected = selectablePhotoIDs
                } label: {
                    Text(selected == selectablePhotoIDs && !selectablePhotoIDs.isEmpty
                         ? "已全选" : "全选")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.labCream.opacity(0.74))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selected == selectablePhotoIDs)
            }

            HStack(spacing: 9) {
                if selected.count == 1, let id = selected.first {
                    Button {
                        copyRecipe(from: id)
                    } label: {
                        Label("复制配方", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .frame(height: 46)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(Color.labCream.opacity(0.88))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    paste()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.on.clipboard")
                        Text(model.clipboardRecipe == nil ? "先复制一个配方" : "粘贴配方")
                        if let recipe = model.clipboardRecipe {
                            Text("· \(model.filmName(for: recipe.filmStock))")
                                .lineLimit(1)
                                .font(.system(size: 10, weight: .medium))
                                .opacity(0.62)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(model.clipboardRecipe == nil
                                ? Color.white.opacity(0.07)
                                : Color.labRed.opacity(0.28),
                                in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(model.clipboardRecipe == nil ? 0.05 : 0.16),
                                    lineWidth: 1)
                    }
                    .foregroundStyle(model.clipboardRecipe == nil ? Color.white.opacity(0.42) : .white)
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty || model.clipboardRecipe == nil)

                Button {
                    deleteIDs = selected
                    showingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .foregroundStyle(Color.labCream.opacity(selected.isEmpty ? 0.35 : 0.8))
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)
            }
        }
        .padding(14)
        .labGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.36), radius: 26, y: 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func copyRecipe(from id: UUID) {
        selected.remove(id)
        model.copyRecipe(from: id)
    }

    private func paste() {
        guard !selected.isEmpty, model.clipboardRecipe != nil else { return }
        let ids = selected.intersection(selectablePhotoIDs)
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            await model.pasteRecipe(to: ids)
            selected.removeAll()
            selecting = false
        }
    }

    // MARK: - empty, busy, toast

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.labRed.opacity(0.12))
                    .frame(width: compact ? 120 : 164, height: compact ? 120 : 164)
                    .blur(radius: 30)
                Circle()
                    .fill(Color.white.opacity(0.035))
                    .frame(width: compact ? 84 : 108, height: compact ? 84 : 108)
                Circle()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    .frame(width: compact ? 84 : 108, height: compact ? 84 : 108)
                Image(systemName: "photo.stack")
                    .font(.system(size: compact ? 30 : 38, weight: .light))
                    .foregroundStyle(Color.labCream.opacity(0.86))
            }
            .frame(height: compact ? 132 : 172)

            VStack(spacing: 8) {
                Text("把一组照片带进来")
                    .font((compact ? Font.title3 : Font.title2).weight(.semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.labCream)
                Text("相册、文件或整个文件夹都能导入。\n点开一张开始调色，返回后就是照片墙。")
                    .font(.footnote)
                    .foregroundStyle(Color.labCream.opacity(0.44))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(spacing: compact ? 8 : 10) {
                PhotosPicker(selection: $pickerItems,
                             maxSelectionCount: 100,
                             matching: .images) {
                    Label("从相册添加照片", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 44 : 50)
                        .foregroundStyle(.white)
                        .labGlassTint(Color.labRed.opacity(0.16), in: Capsule())
                }
                .tint(Color.labCream)

                Button {
                    presentDocuments(folder: false)
                } label: {
                    Label("选择文件（可多选）", systemImage: "doc.badge.plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.labCream.opacity(0.82))
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 40 : 46)
                        .labGlassInteractive(in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    presentDocuments(folder: true)
                } label: {
                    Label("选择整个文件夹（批量导入）", systemImage: "folder.badge.plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.labCream.opacity(0.82))
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 40 : 46)
                        .labGlassInteractive(in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: compact ? CGFloat.infinity : 310)
            .padding(.top, compact ? 16 : 28)

            Text("相册 / 文件 / 文件夹 · 支持 Sony ARW · DNG · JPEG · HEIC")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.labCream.opacity(0.28))
                .padding(.top, compact ? 10 : 14)
        }
        .padding(.top, compact ? 8 : 20)
        .frame(minHeight: compact ? 430 : 500)
        .frame(maxWidth: .infinity)
    }

    private func busyOverlay(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.20).ignoresSafeArea()
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(Color.labCream)
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.labCream)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 58)
            .labGlass(in: Capsule())
            .shadow(color: .black.opacity(0.32), radius: 24, y: 10)
        }
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.labCream)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 17)
            .frame(minHeight: 40)
            .labGlass(in: Capsule())
            .shadow(color: .black.opacity(0.32), radius: 20, y: 8)
        .allowsHitTesting(false)
    }
}

/// An explicit three-way import chooser. The album row is a real
/// PhotosPicker (that is the iOS 16 presentation mechanism); the two
/// document-picker routes are recorded and presented by the wall after this
/// sheet disappears, so two sheets never fight over presentation.
struct ImportSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var pickerItems: [PhotosPickerItem]
    @Binding var route: ImportRoute?

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width <= 390
            NavigationStack {
                ScrollView {
                    VStack(spacing: compact ? 10 : 14) {
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: 100,
                                     matching: .images) {
                            importRow(title: "从相册导入",
                                      detail: "系统相册 · 支持多选与 HEIC / JPEG",
                                      symbol: "photo.on.rectangle.angled",
                                      primary: true)
                        }
                        .buttonStyle(.plain)
                        .tint(Color.labCream)

                        Button {
                            route = .files
                            dismiss()
                        } label: {
                            importRow(title: "选择文件",
                                      detail: "从「文件」App 选一张或多张 RAW / JPEG",
                                      symbol: "doc.badge.plus",
                                      primary: false)
                        }
                        .buttonStyle(.plain)

                        Button {
                            route = .folder
                            dismiss()
                        } label: {
                            importRow(title: "选择整个文件夹",
                                      detail: "自动批量导入文件夹内所有照片（最多 200 张）",
                                      symbol: "folder.badge.plus",
                                      primary: false)
                        }
                        .buttonStyle(.plain)

                        Text("相册由系统选择器提供，无需额外授权；文件夹导入仅在选择期间获得读取权限，一次最多 200 张。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, compact ? 2 : 6)
                    }
                    .padding(compact ? 14 : 20)
                }
                .navigationTitle("导入照片")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("取消") { dismiss() }
                    }
                }
            }
            .presentationDetents([.height(compact ? 330 : 370), .medium])
        }
    }

    private func importRow(title: String, detail: String,
                           symbol: String, primary: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(primary ? Color.white : Color.labCream.opacity(0.88))
                .frame(width: 40, height: 40)
                .background(primary ? Color.labRed.opacity(0.72) : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.labCream)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}
