//  StockArtwork.swift — the small physical objects behind the profile names.
//
//  A profile is more than a menu row. Film gets a canister with a metal cap,
//  a paper label and a tongue of perforated stock; paper gets a boxed sheet.
//  These are drawn in SwiftUI so they stay sharp at every size and carry the
//  measured stock's colour without a separate image asset.

import SwiftUI

struct StockArtwork: View {
    let stock: Stock

    var body: some View {
        GeometryReader { proxy in
            Group {
                if stock.support == .paper {
                    PaperPackArtwork(stock: stock, size: proxy.size)
                } else {
                    FilmCanisterArtwork(stock: stock, size: proxy.size)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FilmCanisterArtwork: View {
    let stock: Stock
    let size: CGSize

    var body: some View {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let bodyWidth = width * 0.62
        let bodyHeight = height * 0.74
        let palette = palette

        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.34))
                .frame(width: bodyWidth * 1.25, height: height * 0.11)
                .blur(radius: width * 0.04)
                .offset(y: height * 0.41)

            filmTongue(width: width, height: height)

            ZStack {
                RoundedRectangle(cornerRadius: width * 0.15, style: .continuous)
                    .fill(LinearGradient(colors: [palette.bodyLight, palette.body,
                                                  palette.bodyDark],
                                         startPoint: .leading, endPoint: .trailing))

                RoundedRectangle(cornerRadius: width * 0.15, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.20), .clear,
                                                  Color.black.opacity(0.18)],
                                         startPoint: .leading, endPoint: .trailing))

                label(width: width, height: height, palette: palette)
            }
            .frame(width: bodyWidth, height: bodyHeight)
            .overlay {
                RoundedRectangle(cornerRadius: width * 0.15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: max(0.5, width * 0.018))
            }

            metalCap(width: width, height: height, bodyWidth: bodyWidth)
                .offset(y: -bodyHeight * 0.50)
            metalCap(width: width, height: height, bodyWidth: bodyWidth)
                .scaleEffect(y: -1)
                .offset(y: bodyHeight * 0.50)
        }
        .frame(width: width, height: height)
    }

    private func filmTongue(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.045, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.055)],
                                     startPoint: .leading, endPoint: .trailing))

            VStack(spacing: height * 0.052) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: width * 0.012, style: .continuous)
                        .fill(Color.labCream.opacity(0.72))
                        .frame(width: width * 0.052, height: height * 0.040)
                }
            }
            .offset(x: width * 0.075)
        }
        .frame(width: width * 0.27, height: height * 0.61)
        .rotationEffect(.degrees(7))
        .offset(x: width * 0.23, y: height * 0.17)
        .shadow(color: .black.opacity(0.34), radius: width * 0.04, x: width * 0.05,
                y: width * 0.04)
    }

    private func metalCap(width: CGFloat, height: CGFloat, bodyWidth: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.74), Color(white: 0.31),
                                              Color(white: 0.68)],
                                     startPoint: .leading, endPoint: .trailing))
            Capsule()
                .fill(Color.black.opacity(0.24))
                .frame(width: bodyWidth * 0.46, height: height * 0.012)
        }
        .frame(width: bodyWidth * 1.04, height: height * 0.105)
        .shadow(color: .black.opacity(0.30), radius: width * 0.025, y: width * 0.025)
    }

    private func label(width: CGFloat, height: CGFloat, palette: Palette) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.035, style: .continuous)
                .fill(LinearGradient(colors: [palette.label.opacity(0.97), palette.label],
                                     startPoint: .top, endPoint: .bottom))

            VStack(spacing: 0) {
                Text(brand)
                    .font(.system(size: width * 0.095, weight: .heavy))
                    .tracking(width * 0.012)
                    .foregroundStyle(palette.ink.opacity(0.74))
                    .lineLimit(1)
                Text(model)
                    .font(.system(size: width * 0.145, weight: .black))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.56)
                Text(speed)
                    .font(.system(size: width * 0.18, weight: .black, design: .rounded))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
            }
            .frame(width: width * 0.48)
        }
        .frame(width: width * 0.52, height: height * 0.42)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.accent.opacity(0.75))
                .frame(width: width * 0.52, height: height * 0.015)
        }
    }

    private var brand: String {
        let id = stock.id
        if id.hasPrefix("kodak") { return "KODAK" }
        if id.hasPrefix("fujifilm") { return "FUJI" }
        if id.hasPrefix("ilford") { return "ILFORD" }
        if id.hasPrefix("cinestill") { return "CINE" }
        return stock.name.split(separator: " ").first.map { String($0).uppercased() } ?? "FILM"
    }

    private var model: String {
        var name = stock.name
        for prefix in ["Kodak ", "Fujifilm ", "Ilford ", "CineStill "] {
            name = name.replacingOccurrences(of: prefix, with: "")
        }
        let words = name.split(separator: " ").map(String.init)
        let wordsWithoutSpeed = words.filter { $0.rangeOfCharacter(from: .decimalDigits) == nil }
        return wordsWithoutSpeed.prefix(2).joined(separator: " ").uppercased()
    }

    private var speed: String {
        let words = stock.name.split(separator: " ").map(String.init)
        if let numeric = words.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
            return numeric.uppercased()
        }
        return stock.type == .positive ? "SLIDE" : "FILM"
    }

    private var palette: Palette {
        let id = stock.id
        if id.hasPrefix("kodak") {
            if id.contains("portra") {
                return Palette(bodyLight: Color(red: 0.91, green: 0.61, blue: 0.35),
                               body: Color(red: 0.73, green: 0.35, blue: 0.22),
                               bodyDark: Color(red: 0.40, green: 0.15, blue: 0.12),
                               label: Color(red: 0.98, green: 0.93, blue: 0.82),
                               ink: Color(red: 0.31, green: 0.10, blue: 0.08),
                               accent: Color(red: 0.61, green: 0.16, blue: 0.13))
            }
            if id.contains("vision3") || id.contains("2393") || id.contains("2383") {
                return Palette(bodyLight: Color(red: 0.28, green: 0.32, blue: 0.35),
                               body: Color(red: 0.12, green: 0.14, blue: 0.16),
                               bodyDark: Color(red: 0.045, green: 0.050, blue: 0.060),
                               label: Color(red: 0.92, green: 0.67, blue: 0.24),
                               ink: Color(white: 0.08),
                               accent: Color(white: 0.10))
            }
            if id.contains("tmax") || id.contains("tri_x") {
                return monochromePalette
            }
            if id.contains("ektachrome") || id.contains("kodachrome") {
                return Palette(bodyLight: Color(red: 0.21, green: 0.35, blue: 0.59),
                               body: Color(red: 0.08, green: 0.15, blue: 0.35),
                               bodyDark: Color(red: 0.025, green: 0.045, blue: 0.12),
                               label: Color(red: 0.96, green: 0.78, blue: 0.24),
                               ink: Color(red: 0.08, green: 0.11, blue: 0.24),
                               accent: Color(red: 0.62, green: 0.08, blue: 0.10))
            }
            return Palette(bodyLight: Color(red: 0.98, green: 0.77, blue: 0.25),
                           body: Color(red: 0.89, green: 0.48, blue: 0.12),
                           bodyDark: Color(red: 0.51, green: 0.19, blue: 0.06),
                           label: Color(red: 0.97, green: 0.92, blue: 0.78),
                           ink: Color(red: 0.19, green: 0.12, blue: 0.06),
                           accent: Color(red: 0.76, green: 0.10, blue: 0.08))
        }
        if id.hasPrefix("fujifilm") {
            if id.contains("velvia") {
                return Palette(bodyLight: Color(red: 0.27, green: 0.66, blue: 0.38),
                               body: Color(red: 0.06, green: 0.35, blue: 0.20),
                               bodyDark: Color(red: 0.015, green: 0.14, blue: 0.08),
                               label: Color(red: 0.95, green: 0.95, blue: 0.83),
                               ink: Color(red: 0.04, green: 0.23, blue: 0.12),
                               accent: Color(red: 0.71, green: 0.09, blue: 0.09))
            }
            if id.contains("provia") {
                return Palette(bodyLight: Color(red: 0.27, green: 0.48, blue: 0.71),
                               body: Color(red: 0.07, green: 0.20, blue: 0.49),
                               bodyDark: Color(red: 0.025, green: 0.06, blue: 0.18),
                               label: Color(red: 0.93, green: 0.92, blue: 0.84),
                               ink: Color(red: 0.05, green: 0.12, blue: 0.27),
                               accent: Color(red: 0.18, green: 0.51, blue: 0.26))
            }
            if id.contains("acros") {
                return monochromePalette
            }
            return Palette(bodyLight: Color(red: 0.40, green: 0.72, blue: 0.44),
                           body: Color(red: 0.08, green: 0.45, blue: 0.22),
                           bodyDark: Color(red: 0.02, green: 0.18, blue: 0.09),
                           label: Color(red: 0.96, green: 0.90, blue: 0.72),
                           ink: Color(red: 0.18, green: 0.10, blue: 0.05),
                           accent: Color(red: 0.78, green: 0.09, blue: 0.08))
        }
        if id.hasPrefix("ilford") {
            return monochromePalette
        }
        if id.hasPrefix("cinestill") {
            return Palette(bodyLight: Color(red: 0.43, green: 0.29, blue: 0.31),
                           body: Color(red: 0.25, green: 0.08, blue: 0.11),
                           bodyDark: Color(red: 0.075, green: 0.020, blue: 0.025),
                           label: Color(red: 0.92, green: 0.12, blue: 0.12),
                           ink: Color(red: 0.98, green: 0.91, blue: 0.80),
                           accent: Color(red: 0.96, green: 0.84, blue: 0.62))
        }
        return Palette(bodyLight: Color(hue: stableHue, saturation: 0.34, brightness: 0.76),
                       body: Color(hue: stableHue, saturation: 0.58, brightness: 0.48),
                       bodyDark: Color(hue: stableHue, saturation: 0.68, brightness: 0.20),
                       label: Color(red: 0.94, green: 0.91, blue: 0.82),
                       ink: Color(white: 0.12), accent: Color(red: 0.64, green: 0.10, blue: 0.09))
    }

    private var monochromePalette: Palette {
        Palette(bodyLight: Color(white: 0.48), body: Color(white: 0.20),
                bodyDark: Color(white: 0.045), label: Color(red: 0.94, green: 0.92, blue: 0.85),
                ink: Color(white: 0.08), accent: Color(white: 0.12))
    }

    private var stableHue: Double {
        var hash = 0
        for scalar in stock.id.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        return Double(hash % 360) / 360
    }

    private struct Palette {
        let bodyLight: Color
        let body: Color
        let bodyDark: Color
        let label: Color
        let ink: Color
        let accent: Color
    }
}

private struct PaperPackArtwork: View {
    let stock: Stock
    let size: CGSize

    var body: some View {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let accent = paperAccent

        ZStack {
            RoundedRectangle(cornerRadius: width * 0.08, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .offset(x: width * 0.045, y: height * 0.045)

            RoundedRectangle(cornerRadius: width * 0.08, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.54)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: width * 0.08, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.38), lineWidth: max(0.5, width * 0.018))
                }

            VStack(spacing: 0) {
                Rectangle()
                    .fill(accent)
                    .frame(height: height * 0.10)
                Spacer(minLength: 0)
                Text("PAPER")
                    .font(.system(size: width * 0.12, weight: .black))
                    .tracking(width * 0.012)
                    .foregroundStyle(Color.black.opacity(0.72))
                Text(paperMark)
                    .font(.system(size: width * 0.09, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(accent.opacity(0.86))
                    .frame(height: height * 0.07)
            }
            .clipShape(RoundedRectangle(cornerRadius: width * 0.08, style: .continuous))
            .padding(width * 0.07)
        }
        .frame(width: width * 0.86, height: height * 0.90)
    }

    private var paperMark: String {
        let id = stock.id
        if id.contains("crystal") { return "FUJI" }
        if id.contains("portra") { return "PORTRA" }
        if id.contains("endura") { return "ENDURA" }
        if id.contains("multigrade") { return "ILFORD" }
        return "PRINT"
    }

    private var paperAccent: Color {
        let id = stock.id
        if id.hasPrefix("fujifilm") { return Color(red: 0.09, green: 0.48, blue: 0.23) }
        if id.hasPrefix("kodak") { return Color(red: 0.88, green: 0.56, blue: 0.11) }
        return Color(red: 0.62, green: 0.20, blue: 0.18)
    }
}
