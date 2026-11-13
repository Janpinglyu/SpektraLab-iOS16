//  ContentView.swift — the engine's picture, chosen from a scrolling strip.
//
//  This is the real SpektraLab pipeline: the frame goes to `spk_open`, the
//  enlarger is solved, and the print is rendered by the C++/Metal engine into
//  a texture that MetalCanvas draws with the engine's output transform.
//  Every film and paper here is a measured profile from
//  `<resources>/profiles`, and every slider is an engine parameter.
//
//  What changed is only how those choices are reached. The two list sheets
//  are gone; films, papers and the parameter controls now live in a bottom
//  deck with a horizontal strip, so the picture stays on screen while a
//  person swipes through them.

import SwiftUI
import PhotosUI
import MetalKit
import UIKit
import UniformTypeIdentifiers

extension Color {
    static var labInk: Color { Color(red: 0.071, green: 0.071, blue: 0.075) }
    static var labPanel: Color { Color(red: 0.110, green: 0.110, blue: 0.118) }
    static var labCream: Color { Color(red: 0.965, green: 0.949, blue: 0.918) }
    static var labRed: Color { Color(red: 0.96, green: 0.27, blue: 0.24) }
}

extension View {
    // iOS 16 compatibility layer.
    //
    // `glassEffect` / `GlassEffectContainer` are iOS 26 APIs. With a 16.0
    // deployment target the compiler refuses every unguarded call, so each
    // one goes through `if #available(iOS 26.0, *)` and falls back to the
    // same material treatment the project used before iOS 27. The extra
    // `compiler(>=6.2)` test keeps the sources buildable with an older Xcode
    // whose SDK has no Liquid Glass symbols at all.
    @ViewBuilder
    nonisolated func labGlass<S: Shape>(_ active: Bool = true, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
#if compiler(>=6.2)
            glassEffect(active ? .regular : .clear, in: shape)
#else
            labGlassFallback(active: active, in: shape)
#endif
        } else {
            labGlassFallback(active: active, in: shape)
        }
    }

    @ViewBuilder
    nonisolated func labGlassInteractive<S: Shape>(_ active: Bool = true, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
#if compiler(>=6.2)
            glassEffect(active ? .regular.interactive() : .clear, in: shape)
#else
            labGlassFallback(active: active, in: shape)
#endif
        } else {
            labGlassFallback(active: active, in: shape)
        }
    }

    /// A tinted glass surface. Used for the one primary action on a screen
    /// (add photos, paste a recipe), so the rest of the chrome stays neutral.
    @ViewBuilder
    nonisolated func labGlassTint<S: Shape>(_ tint: Color, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
#if compiler(>=6.2)
            glassEffect(.regular.tint(tint).interactive(), in: shape)
#else
            labGlassTintFallback(tint, in: shape)
#endif
        } else {
            labGlassTintFallback(tint, in: shape)
        }
    }

    @ViewBuilder
    nonisolated func labGlassFallback<S: Shape>(active: Bool, in shape: S) -> some View {
        if active {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
        } else {
            self
        }
    }

    nonisolated func labGlassTintFallback<S: Shape>(_ tint: Color, in shape: S) -> some View {
        background(tint.opacity(0.42), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    /// `.sensoryFeedback` is iOS 17. iOS 16 keeps the same view tree, minus
    /// the haptic.
    @ViewBuilder
    nonisolated func labSelectionFeedback<T: Equatable>(trigger: T) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }

    /// `.presentationBackground` arrived in iOS 16.4, four patch releases
    /// after this build's floor.
    @ViewBuilder
    nonisolated func labPresentationBackground(_ color: Color) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(color)
        } else {
            self
        }
    }
}

/// Stand-in for SwiftUI's iOS 26 `GlassEffectContainer`. Both call sites put
/// a single `HStack` inside it, so returning the content unchanged on older
/// systems introduces no extra layout.
struct LabGlassContainer<Content: View>: View {
    var spacing: CGFloat = 8
    private let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    @ViewBuilder
    var body: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
#else
        content()
#endif
    }
}

/// A nearly black darkroom with two faint spills of coloured light. The glass
/// controls need something beneath them to refract, but the backdrop stays
/// quiet enough not to compete with a photograph's own colour.
struct LabBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.044, blue: 0.050)
            LinearGradient(colors: [Color.white.opacity(0.020), .clear, .black.opacity(0.16)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.94, green: 0.31, blue: 0.22).opacity(0.11), .clear],
                           center: UnitPoint(x: 0.96, y: 0.01),
                           startRadius: 4, endRadius: 430)
            RadialGradient(colors: [Color(red: 0.30, green: 0.50, blue: 0.67).opacity(0.065), .clear],
                           center: UnitPoint(x: 0.02, y: 0.74),
                           startRadius: 8, endRadius: 390)
            RadialGradient(colors: [.clear, .black.opacity(0.24)],
                           center: .center, startRadius: 170, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct EditorView: View {
    @EnvironmentObject private var model: ViewModel
    @State private var showingExport = false
    @State private var showingDiagnostics = false
    @State private var showingFilmEffects = false
    @State private var hiddenError: String?
    @State private var deck: Deck = .film
    @State private var immersive = false
    @State private var zoom: CGFloat = 1
    @State private var savedZoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var savedPan = CGSize.zero
    @State private var copyToast = false

    private enum Deck: String, CaseIterable, Identifiable, Equatable {
        case film = "胶片"
        case paper = "相纸"
        case adjust = "调整"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LabBackdrop()

            VStack(spacing: 0) {
                if !immersive {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                picture
                if !immersive {
                    deckPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if !immersive, let why = failureMessage {
                notice(why)
            }

            if immersive {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) { immersive = false }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .labGlassInteractive(in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.labCream)
                .padding(.trailing, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity)
            }

            if copyToast {
                Text("配方已复制")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.labCream)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 38)
                    .labGlass(in: Capsule())
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 66)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: immersive)
        .statusBarHidden(immersive)
        .preferredColorScheme(.dark)
        .alert("导出照片", isPresented: $showingExport) {
            Button("保存到相册") {
                _ = Task<Void, Never> { @MainActor in
                    await model.exportToPhotos()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(ImageDecoder.exportLongEdge().map {
                "以最长边 \($0) px 重新渲染为 JPEG 并保存到相册（按本机内存自动限制，避免导出时因内存不足被系统终止）。"
            } ?? "以原始分辨率渲染为 JPEG 并保存到相册。")
        }
        .sheet(isPresented: $showingDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showingFilmEffects) { FilmEffectsSheet(model: model) }
#if DEBUG
        .task {
            let environment = ProcessInfo.processInfo.environment
            if let film = environment["SPEKTRAFILM_UI_TEST_FILM"], !film.isEmpty {
                model.filmChanged(film)
                try? await Task.sleep(for: .seconds(2))
            }
            if let paper = environment["SPEKTRAFILM_UI_TEST_PAPER"], !paper.isEmpty {
                model.paperChanged(paper)
                try? await Task.sleep(for: .seconds(2))
            }
            if let gate = environment["SPEKTRAFILM_UI_TEST_GATE"], !gate.isEmpty {
                model.setOverscanFormat(gate)
            }
            if let orientation = environment["SPEKTRAFILM_UI_TEST_ORIENTATION"],
               let requested = FilmStripOrientation(rawValue: orientation) {
                model.setStripOrientation(requested)
            }
            if environment["SPEKTRAFILM_UI_TEST_BORDER"] == "1" {
                model.setFilmBorderEnabled(true)
                try? await Task.sleep(for: .seconds(8))
            }
            if environment["SPEKTRAFILM_UI_TEST_DATE"] == "1" {
                model.setDateBackEnabled(true)
                try? await Task.sleep(for: .seconds(6))
            }
            if let requested = environment["SPEKTRAFILM_UI_TEST_DECK"],
               let requestedDeck = ["film": Deck.film,
                                    "paper": Deck.paper,
                                    "adjust": Deck.adjust][requested]
                   ?? Deck(rawValue: requested) {
                deck = requestedDeck
            }
            if environment["SPEKTRAFILM_UI_TEST_EFFECTS_SHEET"] == "1" {
                showingFilmEffects = true
            }
            if environment["SPEKTRAFILM_UI_TEST_IMMERSIVE"] == "1" {
                immersive = true
            }
            if let value = environment["SPEKTRAFILM_UI_TEST_ZOOM"],
               let requested = Double(value) {
                zoom = min(max(CGFloat(requested), 1), 4)
                savedZoom = zoom
            }
            if let value = environment["SPEKTRAFILM_UI_TEST_EXPOSURE"],
               let requested = Double(value) {
                model.parameterChanged(FilmParam.exposureCompensation.key, requested)
                try? await Task.sleep(for: .seconds(8))
            }
        }
#endif
    }

    // MARK: - top bar

    private var topBar: some View {
        ZStack {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { deck = .film }
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text(model.currentFilmName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.labCream)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.labCream.opacity(0.55))
                    }
                    Text(model.currentPaperName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: 190)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("当前胶片 \(model.currentFilmName)，相纸 \(model.currentPaperName)")
            .labGlassInteractive(in: Capsule())

            HStack(spacing: 8) {
                Button {
                    model.closeEditor()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .labGlassInteractive(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回照片墙")

                Spacer()

                LabGlassContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Menu {
                            if model.editingPhotoID != nil {
                                Button {
                                    if let id = model.editingPhotoID {
                                        model.copyRecipe(from: id)
                                        copyToast = true
                                        Task { @MainActor in
                                            try? await Task.sleep(for: .seconds(2))
                                            copyToast = false
                                        }
                                    }
                                } label: {
                                    Label("复制这张照片的配方", systemImage: "doc.on.doc")
                                }
                            }
                            Button {
                                model.closeEditor()
                            } label: {
                                Label("保存并返回照片墙", systemImage: "rectangle.stack")
                            }
                            Divider()
                            Button {
                                showingDiagnostics = true
                            } label: {
                                Label("诊断信息", systemImage: "info.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 42, height: 42)
                                .labGlassInteractive(in: Circle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            showingExport = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 42, height: 42)
                                .labGlassInteractive(in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.renderedTexture == nil)
                        .opacity(model.renderedTexture == nil ? 0.4 : 1)
                    }
                }
            }
        }
        .tint(Color.labRed)
        .foregroundStyle(Color.labCream)
        .padding(.top, 3)
        .padding(.horizontal, 12)
    }

    // MARK: - the picture

    private var picture: some View {
        ZStack {
            if model.renderedTexture != nil {
                GeometryReader { proxy in
                    MetalCanvas(renderer: model.renderer,
                                texture: model.renderedTexture,
                                zoom: zoom,
                                pan: pan)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        // MTLTexture is not Hashable; the engine's progress id is
                        // what tells SwiftUI the picture changed.
                        .id(model.renderIdentity)
                        .simultaneousGesture(imageGestures)
                        .simultaneousGesture(pictureTapGesture)
                }
            } else {
                emptyState
            }

            if model.renderedTexture != nil {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(model.currentFilmName)]")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.labCream.opacity(0.94))
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Text(model.currentPaperName)
                                    .lineLimit(1)
                                if model.filmBorderEnabled {
                                    Text("·")
                                    Text(model.selectedGate.title)
                                    if model.stripOrientation != .automatic {
                                        Text("·")
                                        Text(model.stripOrientation.title)
                                    }
                                }
                            }
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.labCream.opacity(0.55))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .transition(.opacity)
            }

            if isBusy {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(model.state == .importing ? "读取中" : "渲染中")
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.labInk)
    }

    private var pictureTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                if zoom > 1 || pan != .zero {
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoom = 1
                        savedZoom = 1
                        pan = .zero
                        savedPan = .zero
                    }
                } else {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) { immersive.toggle() }
                }
            }
            .exclusively(before: TapGesture().onEnded {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) { immersive.toggle() }
            })
    }

    private var imageGestures: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    zoom = min(max(savedZoom * value, 1), 4)
                    if zoom <= 1 { pan = .zero }
                }
                .onEnded { _ in
                    savedZoom = zoom
                    if zoom <= 1 { savedPan = .zero }
                },
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard zoom > 1 else { return }
                    pan = CGSize(width: savedPan.width + value.translation.width,
                                 height: savedPan.height + value.translation.height)
                }
                .onEnded { _ in savedPan = pan }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.labRed.opacity(0.14)).frame(width: 92, height: 92)
                Circle().stroke(Color.labRed.opacity(0.35), lineWidth: 1).frame(width: 92, height: 92)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.labRed)
            }
            VStack(spacing: 7) {
                Text("这张照片没有显示出来")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.labCream)
                Text("回到照片墙重新打开，或查看诊断信息。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.closeEditor()
            } label: {
                Label("返回照片墙", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .frame(minHeight: 46)
                    .background(Color.labRed, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(colors: [Color.labRed.opacity(0.09), Color.clear],
                           center: .center, startRadius: 10, endRadius: 240)
        )
    }

    // MARK: - the bottom deck

    private var deckPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Deck.allCases) { tab in
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { deck = tab }
                    } label: {
                        VStack(spacing: 4) {
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: deck == tab ? .semibold : .medium))
                                .foregroundStyle(deck == tab ? Color.labCream : Color.secondary.opacity(0.48))
                            Capsule()
                                .fill(deck == tab ? Color.labCream : Color.clear)
                                .frame(width: 18, height: 1.5)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(deck == .film ? "\(model.films.count) 款"
                     : deck == .paper ? "\(model.papers.count) 款" : "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    showingDiagnostics = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 2)

            deckContent
                .frame(height: deck == .adjust ? 158 : 70)
        }
        .labGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var deckContent: some View {
        switch deck {
        case .film:
            stockStrip(model.films, selected: model.filmStock) { model.filmChanged($0) }
        case .paper:
            stockStrip(model.papers, selected: model.printStock) { model.paperChanged($0) }
        case .adjust:
            adjustPanel
        }
    }

    private func stockStrip(_ stocks: [Stock], selected: String,
                            pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(stocks) { stock in
                    StockTile(stock: stock,
                              selected: stock.id == selected) {
                        pick(stock.id)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
        }
    }

    private var adjustPanel: some View {
        ScrollView {
            VStack(spacing: 9) {
                effectControls
                ForEach(ParamCatalog.all) { control in
                    ParamSlider(control: control,
                                value: Binding(
                                    get: { model.params[control.key] ?? control.defaultValue },
                                    set: { model.parameterChanged(control.key, $0) }))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var effectControls: some View {
        HStack(spacing: 7) {
            effectButton(title: "片边",
                         detail: model.filmEdgeDisplayName,
                         symbol: "film",
                         active: model.filmBorderEnabled) {
                model.setFilmBorderEnabled(!model.filmBorderEnabled)
            }
            effectButton(title: "日期",
                         detail: model.dateBackEnabled ? model.dateStampText : "关闭",
                         symbol: "calendar",
                         active: model.dateBackEnabled) {
                model.setDateBackEnabled(!model.dateBackEnabled)
            }
            .disabled(!model.dateBackAvailable)
            .opacity(model.dateBackAvailable ? 1 : 0.38)

            Button {
                showingFilmEffects = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                    Text("设置")
                        .font(.system(size: 8, weight: .medium))
                }
                .foregroundStyle(Color.labCream.opacity(0.78))
                .frame(width: 42, height: 38)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func effectButton(title: String, detail: String, symbol: String,
                              active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.labCream)
                    Text(detail)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(active ? Color.labRed : Color.secondary.opacity(0.68))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 9)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(active ? Color.labRed.opacity(0.14) : Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(active ? Color.labRed.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - helpers

    private var isBusy: Bool {
        model.state == .rendering || model.state == .importing
    }

    private var failureMessage: String? {
        guard case .failed(let why) = model.state, why != hiddenError else { return nil }
        return why
    }

    private func notice(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.labRed)
                Text(why)
                    .font(.footnote)
                    .foregroundStyle(Color.labCream)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    hiddenError = why
                    model.dismissFailure()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            Button {
                showingDiagnostics = true
            } label: {
                Text("查看诊断信息")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.labRed)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.labRed.opacity(0.45), lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, deck == .adjust ? 214 : 130)
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("把这段内容发给开发者，可以直接定位引擎侧的问题。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(model.diagnostics)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(16)
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("复制") {
                        UIPasteboard.general.string = model.diagnostics
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - the engine's canvas

/// The engine's texture, drawn. `MTKView` is paused with an explicit
/// `draw()`: the app draws when a render lands, not sixty times a second.
struct MetalCanvas: UIViewRepresentable {
    let renderer: CanvasRenderer?
    let texture: MTLTexture?
    let zoom: CGFloat
    let pan: CGSize

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer?.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.backgroundColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1)
        view.clearColor = MTLClearColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1)
        view.contentMode = .scaleAspectFit
        // The engine writes sRGB transfer-encoded values, matching the
        // macOS host. Tagging the drawable with the same space keeps iOS from
        // applying an implicit conversion.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = false
        return view
    }

    /// `MTKView` has no intrinsic size, and a representable with no size
    /// proposal collapses to a zero-by-zero drawable even inside a ZStack
    /// that fills the screen. That made the canvas render at its old size and
    /// the composition look like a small card. Accept the proposed size, or
    /// the parent's dimensions when the proposal has no concrete value.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: MTKView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer?.setTexture(texture)
        renderer?.setViewport(zoom: zoom,
                              pan: CGPoint(x: pan.width, y: pan.height),
                              size: view.bounds.size)
#if DEBUG
        if ProcessInfo.processInfo.environment["SPEKTRAFILM_CANVAS_LOG"] == "1" {
            NSLog("SpektraLab canvas bounds=%@ drawable=%@ texture=%dx%d",
                  NSCoder.string(for: view.bounds),
                  NSCoder.string(for: view.drawableSize),
                  texture?.width ?? 0,
                  texture?.height ?? 0)
        }
#endif
        view.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        weak var renderer: CanvasRenderer?

        init(renderer: CanvasRenderer?) {
            self.renderer = renderer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            renderer?.draw(in: view)
        }
    }
}

// MARK: - a slider

struct ParamSlider: View {
    let control: ParamControl
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(control.title).font(.footnote)
                Spacer()
                Text(formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: control.range)
                .tint(Color.labRed)
        }
    }

    private var formatted: String {
        if control.key == FilmParam.exposureCompensation.key {
            return String(format: "%+.2f EV", value)
        }
        if control.range.lowerBound < 0 {
            return String(format: "%+.2f", value)
        }
        return String(format: "%.2f", value)
    }
}

// MARK: - one tile in the strip

/// A measured profile, shown on the user's own photo. The tint is only a
/// navigation cue: the picture itself is always rendered by the engine.
struct StockTile: View {
    let stock: Stock
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                StockArtwork(stock: stock)
                    .frame(width: 44, height: 50)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.labRed)
                                .background(Color.labCream, in: Circle())
                                .offset(x: 4, y: -4)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(stock.name)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.labCream : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(0.78)
                        .multilineTextAlignment(.leading)

                    Text(typeLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(selected ? Color.labRed : Color.secondary.opacity(0.65))
                        .lineLimit(1)
                }
                .frame(width: 108, alignment: .leading)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(width: 168, height: 58, alignment: .leading)
            .background(selected ? Color.labRed.opacity(0.12) : Color.white.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? Color.labRed : Color.white.opacity(0.08),
                            lineWidth: selected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: selected)
        .accessibilityLabel("\(stock.name)，\(typeLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var typeLabel: String {
        if stock.support == .paper { return "相纸" }
        return stock.type == .positive ? "反转片" : "负片"
    }
}

// MARK: - the physical film edge and date back

/// The controls behind the compact “片边 / 日期” chips. They stay out of the
/// preview strip until someone asks for them, because they change the
/// physical gate rather than the picture's colour look.
struct FilmEffectsSheet: View {
    @ObservedObject var model: ViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var dataDraft = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text("让画面重新成为一段底片。片边、齿孔、格号、日期与拍摄数据都按上游引擎的曝光模型生成，并和照片一起显影。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    borderSection
                    dateSection
                }
                .padding(16)
            }
            .background(Color.labInk.ignoresSafeArea())
            .navigationTitle("片边与日期后背")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        model.setShootingDataText(dataDraft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Color.labRed)
        .presentationDetents([.large])
        .labPresentationBackground(Color.labInk)
        .onAppear { dataDraft = model.shootingDataText }
        .onDisappear {
            if dataDraft != model.shootingDataText {
                model.setShootingDataText(dataDraft)
            }
        }
    }

    private var borderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("片边", systemImage: "film")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.filmBorderEnabled },
                    set: { model.setFilmBorderEnabled($0) }))
                    .labelsHidden()
                    .tint(Color.labRed)
            }

            Text("片幅")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    gateChip(id: FilmGateCatalog.automaticID,
                             title: "自动",
                             detail: model.selectedGate.title)
                    ForEach(FilmGateCatalog.gates) { gate in
                        gateChip(id: gate.id, title: gate.title, detail: gate.detail)
                    }
                }
            }

            Text("片边方向")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Picker("片边方向", selection: Binding(
                get: { model.stripOrientation },
                set: { model.setStripOrientation($0) })) {
                ForEach(FilmStripOrientation.allCases) { orientation in
                    Text(orientation.title).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.stripOrientationAvailable)

            HStack(spacing: 6) {
                Image(systemName: model.selectedGate.isSquare ? "square" : "rectangle.split.2x1")
                Text(model.selectedGate.isSquare
                     ? "方形片幅没有横竖之分；画面会以中心裁切到 1:1。"
                     : "当前 \(model.gateDisplayName) · \(model.stripOrientation.detail)。为避免拉伸，画面会中心裁切到对应方向的片条，预览与导出使用同一构图。")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .effectCard()
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("日期后背", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.dateBackEnabled },
                    set: { model.setDateBackEnabled($0) }))
                    .labelsHidden()
                    .tint(Color.labRed)
                    .disabled(!model.dateBackAvailable)
            }

            if !model.dateBackAvailable {
                Text("这个全景片幅在真实相机上没有日期后背，引擎会忽略日期曝光。")
                    .font(.caption2)
                    .foregroundStyle(Color.labRed.opacity(0.85))
            }

            if model.dateBackEnabled && model.dateBackAvailable {
                HStack {
                    Text("日期")
                        .font(.footnote)
                    Spacer()
                    DatePicker("", selection: Binding(
                        get: { model.dateStampDate },
                        set: { model.setDateStampDate($0) }), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }

                HStack {
                    Text(model.dateStampText)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.labCream)
                    Spacer()
                    Text("负片曝光")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Picker("字面", selection: Binding(
                    get: { model.dateBackStyle },
                    set: { model.setDateBackStyle($0) })) {
                    ForEach(DateBackStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Picker("位置", selection: Binding(
                    get: { model.dateBackPlacement },
                    set: { model.setDateBackPlacement($0) })) {
                    ForEach(DateBackPlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.filmBorderEnabled)

                if !model.filmBorderEnabled {
                    Text("打开片边后才能把日期放在帧与帧之间；当前会曝在画面内。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Picker("角落", selection: Binding(
                    get: { model.dateBackCorner },
                    set: { model.setDateBackCorner($0) })) {
                    ForEach(DateBackCorner.allCases) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text("拍摄数据")
                        .font(.footnote)
                    TextField("1/125  F2.8  ISO 400  50mm", text: $dataDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .padding(10)
                        .background(Color.white.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("120 会印在片边留白，135 会印在齿孔之间；日期仍按上面的字面曝光。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .effectCard()
        .opacity(model.dateBackAvailable ? 1 : 0.82)
    }

    private func gateChip(id: String, title: String, detail: String) -> some View {
        let selected = model.overscanFormat == id
        return Button {
            model.setOverscanFormat(id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Color.labCream : Color.secondary)
                Text(detail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(selected ? Color.labRed : Color.secondary.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(selected ? Color.labRed.opacity(0.14) : Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.labRed.opacity(0.6) : Color.white.opacity(0.08),
                            lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func effectCard() -> some View {
        padding(14)
            .background(Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.075), lineWidth: 1)
            }
    }
}
