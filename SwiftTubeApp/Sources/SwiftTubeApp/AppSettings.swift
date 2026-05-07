import AppKit
import Foundation
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case dark
    case midnight
    case midnightOcean
    case midnightForest
    case midnightRose
    case midnightAurora
    case midnightEmber
    case midnightAmethyst
    case midnightLagoon
    case midnightCocoa
    case light
    case sunrise
    case sky
    case mint
    case rose
    case sand
    case lavender
    case citrus
    case pearl
    case coral
    case ruby
    case meadow
    case glacier

    struct Palette {
        let title: String
        let subtitle: String
        let preferredColorScheme: ColorScheme
        let isDefaultTheme: Bool
        let windowBackgroundColor: NSColor
        let cardBackgroundColor: NSColor
        let sidebarBackgroundColor: NSColor
        let elevatedBackgroundColor: NSColor
        let previewColors: [NSColor]
    }

    var id: String { rawValue }

    static var defaultThemes: [AppAppearanceMode] {
        [.light, .dark, .midnight]
    }

    static var coloredThemes: [AppAppearanceMode] {
        allCases.filter { !defaultThemes.contains($0) }
    }

    private static func preview(_ colors: NSColor...) -> [NSColor] {
        colors
    }

    var title: String { palette.title }
    var subtitle: String { palette.subtitle }
    var preferredColorScheme: ColorScheme { palette.preferredColorScheme }
    var isDefaultTheme: Bool { palette.isDefaultTheme }

    var windowBackgroundColor: Color {
        Color(nsColor: palette.windowBackgroundColor)
    }

    var cardBackgroundColor: Color {
        Color(nsColor: palette.cardBackgroundColor)
    }

    var sidebarBackgroundColor: Color {
        Color(nsColor: palette.sidebarBackgroundColor)
    }

    var elevatedBackgroundColor: Color {
        Color(nsColor: palette.elevatedBackgroundColor)
    }

    var hoverCardBackgroundColor: Color {
        switch preferredColorScheme {
        case .dark:
            return Color.white.opacity(0.07)
        case .light:
            return Color.black.opacity(0.06)
        @unknown default:
            return Color.black.opacity(0.06)
        }
    }

    var separatorColor: Color {
        switch preferredColorScheme {
        case .dark:
            return Color.white.opacity(0.08)
        case .light:
            return Color.black.opacity(0.08)
        @unknown default:
            return Color.black.opacity(0.08)
        }
    }

    var previewGradient: LinearGradient {
        LinearGradient(
            colors: palette.previewColors.map { Color(nsColor: $0) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var palette: Palette {
        switch self {
        case .dark:
            return Palette(
                title: "Dark",
                subtitle: "The old Midnight look, promoted into SwiftTube’s new default dark theme.",
                preferredColorScheme: .dark,
                isDefaultTheme: true,
                windowBackgroundColor: .init(calibratedRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 24 / 255, green: 24 / 255, blue: 24 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 28 / 255, green: 28 / 255, blue: 28 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1),
                    .init(calibratedRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
                )
            )
        case .midnight:
            return Palette(
                title: "Midnight",
                subtitle: "A true-black variant with maximum contrast and almost no glow.",
                preferredColorScheme: .dark,
                isDefaultTheme: true,
                windowBackgroundColor: .black,
                cardBackgroundColor: .init(calibratedRed: 12 / 255, green: 12 / 255, blue: 12 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 8 / 255, green: 8 / 255, blue: 8 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 16 / 255, green: 16 / 255, blue: 16 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 28 / 255, green: 28 / 255, blue: 28 / 255, alpha: 1),
                    .black
                )
            )
        case .midnightOcean:
            return Palette(
                title: "Ocean",
                subtitle: "Deep navy surfaces with cool electric highlights.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 13 / 255, green: 18 / 255, blue: 28 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 24 / 255, green: 31 / 255, blue: 44 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 18 / 255, green: 26 / 255, blue: 42 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 30 / 255, green: 38 / 255, blue: 56 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 77 / 255, green: 121 / 255, blue: 212 / 255, alpha: 1),
                    .init(calibratedRed: 13 / 255, green: 18 / 255, blue: 28 / 255, alpha: 1)
                )
            )
        case .midnightForest:
            return Palette(
                title: "Forest",
                subtitle: "Dark evergreen surfaces with calmer muted contrast.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 14 / 255, green: 20 / 255, blue: 17 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 25 / 255, green: 34 / 255, blue: 29 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 18 / 255, green: 28 / 255, blue: 23 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 30 / 255, green: 40 / 255, blue: 33 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 90 / 255, green: 135 / 255, blue: 102 / 255, alpha: 1),
                    .init(calibratedRed: 14 / 255, green: 20 / 255, blue: 17 / 255, alpha: 1)
                )
            )
        case .midnightRose:
            return Palette(
                title: "Rose",
                subtitle: "Charcoal and cherry-magenta tones with a softer glow.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 24 / 255, green: 16 / 255, blue: 23 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 36 / 255, green: 24 / 255, blue: 35 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 31 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 42 / 255, green: 28 / 255, blue: 40 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 182 / 255, green: 87 / 255, blue: 134 / 255, alpha: 1),
                    .init(calibratedRed: 24 / 255, green: 16 / 255, blue: 23 / 255, alpha: 1)
                )
            )
        case .midnightAurora:
            return Palette(
                title: "Aurora",
                subtitle: "Bold indigo-blue surfaces with brighter neon energy.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 15 / 255, green: 18 / 255, blue: 32 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 26 / 255, green: 32 / 255, blue: 52 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 20 / 255, green: 24 / 255, blue: 44 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 31 / 255, green: 36 / 255, blue: 61 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 103 / 255, green: 129 / 255, blue: 1, alpha: 1),
                    .init(calibratedRed: 107 / 255, green: 61 / 255, blue: 229 / 255, alpha: 1)
                )
            )
        case .midnightEmber:
            return Palette(
                title: "Ember",
                subtitle: "Warm charcoal with copper highlights and deeper reds.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 28 / 255, green: 18 / 255, blue: 16 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 44 / 255, green: 29 / 255, blue: 24 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 35 / 255, green: 22 / 255, blue: 18 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 47 / 255, green: 30 / 255, blue: 24 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 230 / 255, green: 126 / 255, blue: 65 / 255, alpha: 1),
                    .init(calibratedRed: 76 / 255, green: 35 / 255, blue: 19 / 255, alpha: 1)
                )
            )
        case .midnightAmethyst:
            return Palette(
                title: "Amethyst",
                subtitle: "A plush violet dark theme with richer purple depth.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 20 / 255, green: 16 / 255, blue: 31 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 34 / 255, green: 27 / 255, blue: 50 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 27 / 255, green: 22 / 255, blue: 40 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 40 / 255, green: 31 / 255, blue: 57 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 169 / 255, green: 119 / 255, blue: 1, alpha: 1),
                    .init(calibratedRed: 78 / 255, green: 51 / 255, blue: 149 / 255, alpha: 1)
                )
            )
        case .midnightLagoon:
            return Palette(
                title: "Lagoon",
                subtitle: "A teal dark theme with denser aquatic depth.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 12 / 255, green: 22 / 255, blue: 24 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 19 / 255, green: 35 / 255, blue: 37 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 16 / 255, green: 30 / 255, blue: 32 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 24 / 255, green: 43 / 255, blue: 46 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 66 / 255, green: 188 / 255, blue: 188 / 255, alpha: 1),
                    .init(calibratedRed: 13 / 255, green: 54 / 255, blue: 58 / 255, alpha: 1)
                )
            )
        case .midnightCocoa:
            return Palette(
                title: "Cocoa",
                subtitle: "Velvety espresso brown with softer amber warmth.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 27 / 255, green: 20 / 255, blue: 17 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 41 / 255, green: 31 / 255, blue: 26 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 34 / 255, green: 25 / 255, blue: 21 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 47 / 255, green: 35 / 255, blue: 29 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 170 / 255, green: 122 / 255, blue: 93 / 255, alpha: 1),
                    .init(calibratedRed: 52 / 255, green: 36 / 255, blue: 28 / 255, alpha: 1)
                )
            )
        case .light:
            return Palette(
                title: "Light",
                subtitle: "Bright, clean default surfaces with subtle cool contrast.",
                preferredColorScheme: .light,
                isDefaultTheme: true,
                windowBackgroundColor: .windowBackgroundColor,
                cardBackgroundColor: .white,
                sidebarBackgroundColor: .init(calibratedRed: 240 / 255, green: 243 / 255, blue: 248 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
                previewColors: Self.preview(
                    .white,
                    .init(calibratedRed: 217 / 255, green: 227 / 255, blue: 244 / 255, alpha: 1)
                )
            )
        case .sunrise:
            return Palette(
                title: "Sunrise",
                subtitle: "Warm cream surfaces with peach and apricot accents.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 255 / 255, green: 243 / 255, blue: 234 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 1, green: 250 / 255, blue: 244 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 247 / 255, green: 232 / 255, blue: 219 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 1, green: 246 / 255, blue: 239 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 1, green: 185 / 255, blue: 138 / 255, alpha: 1),
                    .init(calibratedRed: 1, green: 233 / 255, blue: 209 / 255, alpha: 1)
                )
            )
        case .sky:
            return Palette(
                title: "Sky",
                subtitle: "Airy blue surfaces with brighter daylight contrast.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 235 / 255, green: 244 / 255, blue: 1, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 247 / 255, green: 251 / 255, blue: 1, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 223 / 255, green: 236 / 255, blue: 252 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 244 / 255, green: 249 / 255, blue: 1, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 117 / 255, green: 182 / 255, blue: 1, alpha: 1),
                    .init(calibratedRed: 208 / 255, green: 231 / 255, blue: 1, alpha: 1)
                )
            )
        case .mint:
            return Palette(
                title: "Mint",
                subtitle: "Soft mint surfaces with fresher green highlights.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 233 / 255, green: 250 / 255, blue: 242 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 245 / 255, green: 1, blue: 249 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 216 / 255, green: 242 / 255, blue: 228 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 240 / 255, green: 252 / 255, blue: 246 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 89 / 255, green: 204 / 255, blue: 150 / 255, alpha: 1),
                    .init(calibratedRed: 211 / 255, green: 248 / 255, blue: 228 / 255, alpha: 1)
                )
            )
        case .rose:
            return Palette(
                title: "Rose",
                subtitle: "Editorial pink surfaces with brighter berry accents.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 1, green: 238 / 255, blue: 245 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 1, green: 246 / 255, blue: 249 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 249 / 255, green: 227 / 255, blue: 236 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 1, green: 242 / 255, blue: 247 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 1, green: 133 / 255, blue: 178 / 255, alpha: 1),
                    .init(calibratedRed: 1, green: 222 / 255, blue: 234 / 255, alpha: 1)
                )
            )
        case .sand:
            return Palette(
                title: "Sand",
                subtitle: "Warm neutral surfaces with a sunnier paper tone.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 251 / 255, green: 241 / 255, blue: 226 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 1, green: 248 / 255, blue: 238 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 244 / 255, green: 231 / 255, blue: 212 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 1, green: 244 / 255, blue: 231 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 233 / 255, green: 185 / 255, blue: 112 / 255, alpha: 1),
                    .init(calibratedRed: 1, green: 233 / 255, blue: 196 / 255, alpha: 1)
                )
            )
        case .lavender:
            return Palette(
                title: "Lavender",
                subtitle: "Pale violet surfaces with stronger lilac highlights.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 244 / 255, green: 239 / 255, blue: 1, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 250 / 255, green: 246 / 255, blue: 1, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 235 / 255, green: 227 / 255, blue: 1, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 247 / 255, green: 243 / 255, blue: 1, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 186 / 255, green: 143 / 255, blue: 1, alpha: 1),
                    .init(calibratedRed: 226 / 255, green: 203 / 255, blue: 1, alpha: 1)
                )
            )
        case .citrus:
            return Palette(
                title: "Citrus",
                subtitle: "Fresh cream surfaces with punchier lime and lemon notes.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 249 / 255, green: 251 / 255, blue: 219 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 1, green: 1, blue: 238 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 236 / 255, green: 244 / 255, blue: 198 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 252 / 255, green: 1, blue: 231 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 186 / 255, green: 233 / 255, blue: 74 / 255, alpha: 1),
                    .init(calibratedRed: 1, green: 226 / 255, blue: 124 / 255, alpha: 1)
                )
            )
        case .pearl:
            return Palette(
                title: "Pearl",
                subtitle: "Clean pearl-white surfaces with crisp silver-blue separation.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 241 / 255, green: 245 / 255, blue: 251 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 231 / 255, green: 237 / 255, blue: 246 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 250 / 255, green: 252 / 255, blue: 1, alpha: 1),
                previewColors: Self.preview(
                    .white,
                    .init(calibratedRed: 205 / 255, green: 221 / 255, blue: 244 / 255, alpha: 1)
                )
            )
        case .coral:
            return Palette(
                title: "Coral",
                subtitle: "Soft coral surfaces with warmer citrus-pink accents.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 1, green: 236 / 255, blue: 228 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 1, green: 244 / 255, blue: 239 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 251 / 255, green: 228 / 255, blue: 220 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 1, green: 240 / 255, blue: 232 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 1, green: 142 / 255, blue: 118 / 255, alpha: 1),
                    .init(calibratedRed: 1, green: 218 / 255, blue: 190 / 255, alpha: 1)
                )
            )
        case .ruby:
            return Palette(
                title: "Ruby",
                subtitle: "A new dark crimson palette with deeper wine-toned highlights.",
                preferredColorScheme: .dark,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 25 / 255, green: 13 / 255, blue: 18 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 40 / 255, green: 21 / 255, blue: 29 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 31 / 255, green: 17 / 255, blue: 24 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 47 / 255, green: 24 / 255, blue: 33 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 217 / 255, green: 76 / 255, blue: 114 / 255, alpha: 1),
                    .init(calibratedRed: 74 / 255, green: 22 / 255, blue: 38 / 255, alpha: 1)
                )
            )
        case .meadow:
            return Palette(
                title: "Meadow",
                subtitle: "A new spring green light theme with brighter leafy contrast.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 236 / 255, green: 250 / 255, blue: 228 / 255, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 247 / 255, green: 1, blue: 241 / 255, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 220 / 255, green: 243 / 255, blue: 206 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 243 / 255, green: 252 / 255, blue: 235 / 255, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 111 / 255, green: 205 / 255, blue: 90 / 255, alpha: 1),
                    .init(calibratedRed: 204 / 255, green: 246 / 255, blue: 171 / 255, alpha: 1)
                )
            )
        case .glacier:
            return Palette(
                title: "Glacier",
                subtitle: "A crisp ice-blue light theme with sharper frosted surfaces.",
                preferredColorScheme: .light,
                isDefaultTheme: false,
                windowBackgroundColor: .init(calibratedRed: 235 / 255, green: 247 / 255, blue: 1, alpha: 1),
                cardBackgroundColor: .init(calibratedRed: 247 / 255, green: 252 / 255, blue: 1, alpha: 1),
                sidebarBackgroundColor: .init(calibratedRed: 220 / 255, green: 238 / 255, blue: 252 / 255, alpha: 1),
                elevatedBackgroundColor: .init(calibratedRed: 242 / 255, green: 250 / 255, blue: 1, alpha: 1),
                previewColors: Self.preview(
                    .init(calibratedRed: 108 / 255, green: 197 / 255, blue: 1, alpha: 1),
                    .init(calibratedRed: 198 / 255, green: 234 / 255, blue: 1, alpha: 1)
                )
            )
        }
    }
}

enum SeekCategory: String, CaseIterable, Identifiable {
    case short
    case medium
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "Short Seek"
        case .medium: return "Medium Seek"
        case .long: return "Long Seek"
        }
    }

    var description: String {
        switch self {
        case .short: return "Small corrections and quick rewinds."
        case .medium: return "Default skipping through a video."
        case .long: return "Big jumps through long videos."
        }
    }

    var defaultSeconds: Int {
        switch self {
        case .short: return 5
        case .medium: return 10
        case .long: return 30
        }
    }
}

enum PlayerKeyAction: String, CaseIterable, Identifiable {
    case playPause
    case seekShortBack
    case seekShortForward
    case seekMediumBack
    case seekMediumForward
    case seekLongBack
    case seekLongForward
    case frameBack
    case frameForward
    case theaterMode
    case fullscreen
    case subtitles
    case likeVideo
    case dislikeVideo
    case watchLater
    case saveToPlaylist
    case subscribe
    case share

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .seekShortBack: return "Short Seek Back"
        case .seekShortForward: return "Short Seek Forward"
        case .seekMediumBack: return "Medium Seek Back"
        case .seekMediumForward: return "Medium Seek Forward"
        case .seekLongBack: return "Long Seek Back"
        case .seekLongForward: return "Long Seek Forward"
        case .frameBack: return "Frame Step Back"
        case .frameForward: return "Frame Step Forward"
        case .theaterMode: return "Toggle Theater Mode"
        case .fullscreen: return "Toggle Fullscreen"
        case .subtitles: return "Toggle Subtitles"
        case .likeVideo: return "Like Video"
        case .dislikeVideo: return "Dislike Video"
        case .watchLater: return "Toggle Watch Later"
        case .saveToPlaylist: return "Save To Playlist"
        case .subscribe: return "Subscribe"
        case .share: return "Open Share"
        }
    }

    var groupTitle: String {
        switch self {
        case .playPause, .theaterMode, .fullscreen, .subtitles:
            return "Playback"
        case .seekShortBack, .seekShortForward, .seekMediumBack, .seekMediumForward, .seekLongBack, .seekLongForward, .frameBack, .frameForward:
            return "Navigation"
        case .likeVideo, .dislikeVideo, .watchLater, .saveToPlaylist, .subscribe, .share:
            return "Video Actions"
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .playPause:
            return KeyBinding.legacyCharacter("k") ?? .unbound
        case .seekShortBack:
            return KeyBinding(keyCode: 123, modifiers: [], keyLabel: "Left Arrow")
        case .seekShortForward:
            return KeyBinding(keyCode: 124, modifiers: [], keyLabel: "Right Arrow")
        case .seekMediumBack:
            return KeyBinding.legacyCharacter("j") ?? .unbound
        case .seekMediumForward:
            return KeyBinding.legacyCharacter("l") ?? .unbound
        case .seekLongBack:
            return KeyBinding(keyCode: 123, modifiers: [.option], keyLabel: "Left Arrow")
        case .seekLongForward:
            return KeyBinding(keyCode: 124, modifiers: [.option], keyLabel: "Right Arrow")
        case .frameBack:
            return KeyBinding.legacyCharacter(",") ?? .unbound
        case .frameForward:
            return KeyBinding.legacyCharacter(".") ?? .unbound
        case .theaterMode:
            return KeyBinding.legacyCharacter("t") ?? .unbound
        case .fullscreen:
            return KeyBinding.legacyCharacter("f") ?? .unbound
        case .subtitles:
            return KeyBinding.legacyCharacter("c") ?? .unbound
        case .likeVideo, .dislikeVideo, .watchLater, .saveToPlaylist, .subscribe, .share:
            return .unbound
        }
    }
}

enum NotificationDisplayMode: String, CaseIterable, Identifiable {
    case errorsOnly
    case all
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .errorsOnly:
            return "Errors Only"
        case .all:
            return "Success + Errors"
        case .none:
            return "None"
        }
    }

    var subtitle: String {
        switch self {
        case .errorsOnly:
            return "Only failed background actions show notifications."
        case .all:
            return "Show both successful and failed background actions."
        case .none:
            return "Hide all background action notifications."
        }
    }
}

enum NotificationPlacement: String, CaseIterable, Identifiable {
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomLeft:
            return "Bottom Left"
        case .bottomRight:
            return "Bottom Right"
        }
    }
}

enum BrowseVideoGridPreset: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Default"
        case .large: return "Large"
        }
    }

    var cardWidth: Double {
        switch self {
        case .compact: return 250
        case .standard: return 340
        case .large: return 520
        }
    }

    var columnHint: String {
        switch self {
        case .compact: return "4 columns"
        case .standard: return "3 columns"
        case .large: return "2 columns"
        }
    }
}

enum PlayerControlLayout: String, CaseIterable, Identifiable {
    case standard
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .compact: return "Compact"
        }
    }
}

final class AppSettings: ObservableObject {
    nonisolated(unsafe) static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let sidebarOrderKey = "sidebarItemOrder"
    private let sidebarHiddenKey = "hiddenSidebarItems"
    private let sidebarPlaylistOrderKey = "sidebarPlaylistOrder"
    private let hiddenSidebarPlaylistIDsKey = "hiddenSidebarPlaylistIDs"
    private let keyBindingsKey = "playerKeyBindings"
    private let notificationDisplayModeKey = "notificationDisplayMode"
    private let notificationPlacementKey = "notificationPlacement"
    private let notificationAutoHideDelayKey = "notificationAutoHideDelay"
    private let browseVideoGridPresetKey = "browseVideoGridPreset"
    private let browseVideoCardWidthKey = "browseVideoCardWidth"
    private let appearanceModeMigrationKey = "appearanceModeMigration0130"
    private let sponsorBlockEnabledKey = "sponsorBlockEnabled"
    private let sponsorBlockAutoSkipKey = "sponsorBlockAutoSkipEnabled"
    private let sponsorBlockCategoryBehaviorsKey = "sponsorBlockCategoryBehaviors"
    private let playerControlLayoutKey = "playerControlLayout"
    private let sendWatchProgressToYouTubeKey = "sendWatchProgressToYouTube"
    private let onboardingCompletedKey = "onboardingCompleted"

    @Published var appearanceMode: AppAppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }

    @Published var defaultQuality: DefaultQuality {
        didSet { defaults.set(defaultQuality.rawValue, forKey: "defaultQuality") }
    }

    @Published var defaultPlaybackSpeed: Double {
        didSet { defaults.set(defaultPlaybackSpeed, forKey: "defaultPlaybackSpeed") }
    }

    @Published var spacebarHoldPlaybackSpeed: Double {
        didSet { defaults.set(spacebarHoldPlaybackSpeed, forKey: "spacebarHoldPlaybackSpeed") }
    }

    @Published var shortSeekSeconds: Int {
        didSet { defaults.set(shortSeekSeconds, forKey: "shortSeekSeconds") }
    }

    @Published var mediumSeekSeconds: Int {
        didSet { defaults.set(mediumSeekSeconds, forKey: "mediumSeekSeconds") }
    }

    @Published var longSeekSeconds: Int {
        didSet { defaults.set(longSeekSeconds, forKey: "longSeekSeconds") }
    }

    @Published var keyboardLockKey: KeyboardLockKey {
        didSet { defaults.set(keyboardLockKey.rawValue, forKey: "keyboardLockKey") }
    }

    @Published var keyBindings: [PlayerKeyAction: KeyBinding] {
        didSet { persistKeyBindings() }
    }

    @Published var sidebarItemOrder: [SidebarItemKind] {
        didSet { defaults.set(sidebarItemOrder.map(\.rawValue), forKey: sidebarOrderKey) }
    }

    @Published var hiddenSidebarItems: Set<String> {
        didSet { defaults.set(Array(hiddenSidebarItems), forKey: sidebarHiddenKey) }
    }

    @Published var sidebarPlaylistOrder: [String] {
        didSet { defaults.set(sidebarPlaylistOrder, forKey: sidebarPlaylistOrderKey) }
    }

    @Published var hiddenSidebarPlaylistIDs: Set<String> {
        didSet { defaults.set(Array(hiddenSidebarPlaylistIDs), forKey: hiddenSidebarPlaylistIDsKey) }
    }

    @Published var notificationDisplayMode: NotificationDisplayMode {
        didSet { defaults.set(notificationDisplayMode.rawValue, forKey: notificationDisplayModeKey) }
    }

    @Published var notificationPlacement: NotificationPlacement {
        didSet { defaults.set(notificationPlacement.rawValue, forKey: notificationPlacementKey) }
    }

    @Published var notificationAutoHideDelay: Double {
        didSet { defaults.set(notificationAutoHideDelay, forKey: notificationAutoHideDelayKey) }
    }

    @Published var browseVideoGridPreset: BrowseVideoGridPreset {
        didSet {
            defaults.set(browseVideoGridPreset.rawValue, forKey: browseVideoGridPresetKey)
            defaults.set(browseVideoGridPreset.cardWidth, forKey: browseVideoCardWidthKey)
        }
    }

    @Published var sponsorBlockEnabled: Bool {
        didSet { defaults.set(sponsorBlockEnabled, forKey: sponsorBlockEnabledKey) }
    }

    @Published var sponsorBlockCategoryBehaviors: [SponsorBlockCategory: SponsorBlockBehavior] {
        didSet { persistSponsorBlockCategoryBehaviors() }
    }

    @Published var playerControlLayout: PlayerControlLayout {
        didSet { defaults.set(playerControlLayout.rawValue, forKey: playerControlLayoutKey) }
    }

    @Published var sendWatchProgressToYouTube: Bool {
        didSet { defaults.set(sendWatchProgressToYouTube, forKey: sendWatchProgressToYouTubeKey) }
    }

    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: onboardingCompletedKey) }
    }

    init() {
        let storedAppearance = defaults.string(forKey: "appearanceMode") ?? ""
        let hasMigratedAppearance = defaults.bool(forKey: appearanceModeMigrationKey)
        let resolvedAppearance: AppAppearanceMode

        if hasMigratedAppearance {
            resolvedAppearance = AppAppearanceMode(rawValue: storedAppearance)
                ?? (storedAppearance == "oledDark" ? .midnight : .dark)
        } else {
            switch storedAppearance {
            case "midnight":
                resolvedAppearance = .dark
                defaults.set(AppAppearanceMode.dark.rawValue, forKey: "appearanceMode")
            case "oledDark":
                resolvedAppearance = .midnight
                defaults.set(AppAppearanceMode.midnight.rawValue, forKey: "appearanceMode")
            default:
                resolvedAppearance = AppAppearanceMode(rawValue: storedAppearance) ?? .dark
                if storedAppearance.isEmpty == false {
                    defaults.set(resolvedAppearance.rawValue, forKey: "appearanceMode")
                }
            }
            defaults.set(true, forKey: appearanceModeMigrationKey)
        }

        self.appearanceMode = resolvedAppearance
        self.defaultQuality = DefaultQuality(rawValue: defaults.string(forKey: "defaultQuality") ?? "") ?? .auto

        let storedDefaultPlaybackSpeed = defaults.double(forKey: "defaultPlaybackSpeed")
        self.defaultPlaybackSpeed = Self.playbackSpeedOptions.contains(storedDefaultPlaybackSpeed)
            ? storedDefaultPlaybackSpeed
            : 1.0

        let storedSpacebarHoldPlaybackSpeed = defaults.double(forKey: "spacebarHoldPlaybackSpeed")
        self.spacebarHoldPlaybackSpeed = Self.spacebarHoldPlaybackSpeedOptions.contains(storedSpacebarHoldPlaybackSpeed)
            ? storedSpacebarHoldPlaybackSpeed
            : 2.0

        let storedShortSeek = defaults.integer(forKey: "shortSeekSeconds")
        self.shortSeekSeconds = storedShortSeek > 0 ? storedShortSeek : 5

        let storedMediumSeek = defaults.integer(forKey: "mediumSeekSeconds")
        self.mediumSeekSeconds = storedMediumSeek > 0
            ? storedMediumSeek
            : max(defaults.integer(forKey: "jlSeekSeconds"), 10)

        let storedLongSeek = defaults.integer(forKey: "longSeekSeconds")
        self.longSeekSeconds = storedLongSeek > 0 ? storedLongSeek : 30

        self.keyboardLockKey = KeyboardLockKey(rawValue: defaults.string(forKey: "keyboardLockKey") ?? "") ?? .disabled
        self.keyBindings = Self.loadPersistedKeyBindings(from: defaults)

        let storedOrder = (defaults.array(forKey: sidebarOrderKey) as? [String]) ?? []
        let orderedItems = storedOrder.compactMap(SidebarItemKind.init(rawValue:))
        let missingItems = SidebarItemKind.allCases.filter { !orderedItems.contains($0) }
        self.sidebarItemOrder = orderedItems + missingItems
        self.hiddenSidebarItems = Set((defaults.array(forKey: sidebarHiddenKey) as? [String]) ?? [])
        self.sidebarPlaylistOrder = (defaults.array(forKey: sidebarPlaylistOrderKey) as? [String]) ?? []
        self.hiddenSidebarPlaylistIDs = Set((defaults.array(forKey: hiddenSidebarPlaylistIDsKey) as? [String]) ?? [])
        self.notificationDisplayMode = NotificationDisplayMode(
            rawValue: defaults.string(forKey: notificationDisplayModeKey) ?? ""
        ) ?? .errorsOnly
        self.notificationPlacement = NotificationPlacement(
            rawValue: defaults.string(forKey: notificationPlacementKey) ?? ""
        ) ?? .bottomRight

        let storedNotificationDelay = defaults.double(forKey: notificationAutoHideDelayKey)
        self.notificationAutoHideDelay = Self.notificationAutoHideDelayOptions.contains(storedNotificationDelay)
            ? storedNotificationDelay
            : 4

        if let storedGridPreset = BrowseVideoGridPreset(rawValue: defaults.string(forKey: browseVideoGridPresetKey) ?? "") {
            self.browseVideoGridPreset = storedGridPreset
        } else {
            let storedBrowseVideoCardWidth = defaults.double(forKey: browseVideoCardWidthKey)
            switch storedBrowseVideoCardWidth {
            case let width where width >= 390:
                self.browseVideoGridPreset = .large
            case let width where width > 0 && width < 320:
                self.browseVideoGridPreset = .compact
            default:
                self.browseVideoGridPreset = .standard
            }
        }
        if defaults.object(forKey: sponsorBlockEnabledKey) == nil {
            self.sponsorBlockEnabled = true
        } else {
            self.sponsorBlockEnabled = defaults.bool(forKey: sponsorBlockEnabledKey)
        }

        let legacyAutoSkipEnabled: Bool
        if defaults.object(forKey: sponsorBlockAutoSkipKey) == nil {
            legacyAutoSkipEnabled = true
        } else {
            legacyAutoSkipEnabled = defaults.bool(forKey: sponsorBlockAutoSkipKey)
        }
        self.sponsorBlockCategoryBehaviors = Self.loadSponsorBlockCategoryBehaviors(
            from: defaults,
            legacyAutoSkipEnabled: legacyAutoSkipEnabled
        )
        self.playerControlLayout = PlayerControlLayout(rawValue: defaults.string(forKey: playerControlLayoutKey) ?? "") ?? .standard
        if defaults.object(forKey: sendWatchProgressToYouTubeKey) == nil {
            self.sendWatchProgressToYouTube = true
        } else {
            self.sendWatchProgressToYouTube = defaults.bool(forKey: sendWatchProgressToYouTubeKey)
        }
        if defaults.object(forKey: onboardingCompletedKey) == nil {
            let hasExistingProfile = defaults.object(forKey: "appearanceMode") != nil
                || defaults.object(forKey: browseVideoCardWidthKey) != nil
                || defaults.object(forKey: sponsorBlockEnabledKey) != nil
            self.onboardingCompleted = hasExistingProfile
        } else {
            self.onboardingCompleted = defaults.bool(forKey: onboardingCompletedKey)
        }
    }

    static let seekSecondsOptions = [3, 5, 10, 15, 30, 45, 60, 90]
    static let playbackSpeedOptions: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static let spacebarHoldPlaybackSpeedOptions: [Double] = [1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let notificationAutoHideDelayOptions: [Double] = [2, 4, 6, 8, 12]
    var browseVideoCardWidth: Double {
        browseVideoGridPreset.cardWidth
    }

    var preferredColorScheme: ColorScheme {
        appearanceMode.preferredColorScheme
    }

    var windowBackgroundColor: Color {
        appearanceMode.windowBackgroundColor
    }

    var cardBackgroundColor: Color {
        appearanceMode.cardBackgroundColor
    }

    var sidebarBackgroundColor: Color {
        appearanceMode.sidebarBackgroundColor
    }

    var elevatedBackgroundColor: Color {
        appearanceMode.elevatedBackgroundColor
    }

    var hoverCardBackgroundColor: Color {
        appearanceMode.hoverCardBackgroundColor
    }

    var separatorColor: Color {
        appearanceMode.separatorColor
    }

    var notificationStackAlignment: Alignment {
        switch notificationPlacement {
        case .bottomLeft:
            return .bottomLeading
        case .bottomRight:
            return .bottomTrailing
        }
    }

    func shouldDisplayNotification(accent: AppNotificationAccent) -> Bool {
        switch notificationDisplayMode {
        case .errorsOnly:
            return accent == .red
        case .all:
            return true
        case .none:
            return false
        }
    }

    func binding(for action: PlayerKeyAction) -> KeyBinding {
        keyBindings[action] ?? action.defaultBinding
    }

    func setBinding(_ binding: KeyBinding, for action: PlayerKeyAction) {
        keyBindings[action] = binding
    }

    func resetAllKeyBindings() {
        keyBindings = Dictionary(uniqueKeysWithValues: PlayerKeyAction.allCases.map { ($0, $0.defaultBinding) })
    }

    func seekSeconds(for category: SeekCategory) -> Double {
        switch category {
        case .short: return Double(shortSeekSeconds)
        case .medium: return Double(mediumSeekSeconds)
        case .long: return Double(longSeekSeconds)
        }
    }

    func sponsorBlockBehavior(for category: SponsorBlockCategory) -> SponsorBlockBehavior {
        sponsorBlockCategoryBehaviors[category] ?? category.defaultBehavior
    }

    func sponsorBlockBehavior(forRawCategory rawCategory: String) -> SponsorBlockBehavior {
        guard let category = SponsorBlockCategory(rawValue: rawCategory) else {
            return .disabled
        }
        return sponsorBlockBehavior(for: category)
    }

    func setSponsorBlockBehavior(_ behavior: SponsorBlockBehavior, for category: SponsorBlockCategory) {
        sponsorBlockCategoryBehaviors[category] = behavior
    }

    func setSeekSeconds(_ seconds: Int, for category: SeekCategory) {
        switch category {
        case .short:
            shortSeekSeconds = seconds
        case .medium:
            mediumSeekSeconds = seconds
        case .long:
            longSeekSeconds = seconds
        }
    }

    func isSidebarItemVisible(_ item: SidebarItemKind) -> Bool {
        if item == .home { return true }
        return !hiddenSidebarItems.contains(item.rawValue)
    }

    func setSidebarItem(_ item: SidebarItemKind, visible: Bool) {
        guard item != .home else { return }
        if visible {
            hiddenSidebarItems.remove(item.rawValue)
        } else {
            hiddenSidebarItems.insert(item.rawValue)
        }
    }

    func isSidebarPlaylistVisible(_ playlistID: String) -> Bool {
        !hiddenSidebarPlaylistIDs.contains(playlistID)
    }

    func setSidebarPlaylist(_ playlistID: String, visible: Bool) {
        if visible {
            hiddenSidebarPlaylistIDs.remove(playlistID)
        } else {
            hiddenSidebarPlaylistIDs.insert(playlistID)
        }
    }

    func moveSidebarItems(from source: IndexSet, to destination: Int) {
        sidebarItemOrder.move(fromOffsets: source, toOffset: destination)
    }

    func moveSidebarItem(_ item: SidebarItemKind, direction: Int) {
        guard let currentIndex = sidebarItemOrder.firstIndex(of: item) else { return }
        let destinationIndex = currentIndex + direction
        guard sidebarItemOrder.indices.contains(destinationIndex) else { return }

        var updatedOrder = sidebarItemOrder
        updatedOrder.swapAt(currentIndex, destinationIndex)
        sidebarItemOrder = updatedOrder
    }

    func orderedSidebarPlaylists(_ playlists: [PlaylistSummary]) -> [PlaylistSummary] {
        let lookup = Dictionary(uniqueKeysWithValues: playlists.map { ($0.playlistId, $0) })
        let ordered = sidebarPlaylistOrder.compactMap { lookup[$0] }
        let missing = playlists.filter { !sidebarPlaylistOrder.contains($0.playlistId) }
        return ordered + missing
    }

    func moveSidebarPlaylists(from source: IndexSet, to destination: Int, availablePlaylists: [PlaylistSummary]) {
        var orderedIDs = orderedSidebarPlaylists(availablePlaylists).map(\.playlistId)
        orderedIDs.move(fromOffsets: source, toOffset: destination)
        sidebarPlaylistOrder = orderedIDs
    }

    func moveSidebarPlaylist(_ playlistID: String, direction: Int, availablePlaylists: [PlaylistSummary]) {
        var orderedIDs = orderedSidebarPlaylists(availablePlaylists).map(\.playlistId)
        guard let currentIndex = orderedIDs.firstIndex(of: playlistID) else { return }
        let destinationIndex = currentIndex + direction
        guard orderedIDs.indices.contains(destinationIndex) else { return }

        orderedIDs.swapAt(currentIndex, destinationIndex)
        sidebarPlaylistOrder = orderedIDs
    }

    func reorderSidebarItem(_ dragged: SidebarItemKind, before target: SidebarItemKind) {
        guard dragged != target,
              let targetIndex = sidebarItemOrder.firstIndex(of: target) else {
            return
        }

        reorderSidebarItem(dragged, to: targetIndex)
    }

    func reorderSidebarItem(_ dragged: SidebarItemKind, to destinationIndex: Int) {
        guard let sourceIndex = sidebarItemOrder.firstIndex(of: dragged) else {
            return
        }

        var updatedOrder = sidebarItemOrder
        updatedOrder.remove(at: sourceIndex)
        let clampedDestination = max(0, min(destinationIndex, sidebarItemOrder.count))
        let adjustedDestination = sourceIndex < destinationIndex
            ? min(clampedDestination - 1, updatedOrder.count)
            : min(clampedDestination, updatedOrder.count)
        updatedOrder.insert(dragged, at: adjustedDestination)
        sidebarItemOrder = updatedOrder
    }

    func visibleSidebarItems(isAuthenticated: Bool) -> [SidebarItemKind] {
        let available = sidebarItemOrder.filter { item in
            switch item {
            case .home:
                return true
            case .history, .playlists, .watchLater, .likedVideos:
                return isAuthenticated
            }
        }

        let visible = available.filter(isSidebarItemVisible)
        return visible.isEmpty ? [.home] : visible
    }

    static func playbackSpeedLabel(_ speed: Double) -> String {
        let rounded = (speed * 100).rounded() / 100
        let rawText: String
        if abs(rounded * 10 - (rounded * 10).rounded()) < 0.001 {
            rawText = String(format: "%.1f", rounded)
        } else {
            rawText = String(format: "%.2f", rounded)
        }
        let trimmed = rawText
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(trimmed)x"
    }

    enum DefaultQuality: String, CaseIterable, Identifiable {
        case auto   = "Auto"
        case p360   = "360p"
        case p480   = "480p"
        case p720   = "720p"
        case p1080  = "1080p"
        case p1440  = "1440p"
        case p2160  = "2160p"

        var id: String { rawValue }

        var preferredHeight: Int? {
            switch self {
            case .auto: return nil
            case .p360: return 360
            case .p480: return 480
            case .p720: return 720
            case .p1080: return 1080
            case .p1440: return 1440
            case .p2160: return 2160
            }
        }
    }

    enum KeyboardLockKey: String, CaseIterable, Identifiable {
        case disabled = "disabled"
        case backtick = "backtick"
        case backslash = "backslash"
        case z = "z"
        case x = "x"

        var id: String { rawValue }

        var keyCode: UInt16? {
            switch self {
            case .disabled: return nil
            case .backtick: return 50
            case .backslash: return 42
            case .z: return 6
            case .x: return 7
            }
        }

        var displayName: String {
            switch self {
            case .disabled: return "Disabled"
            case .backtick: return "` (Backtick)"
            case .backslash: return "\\ (Backslash)"
            case .z: return "Z"
            case .x: return "X"
            }
        }
    }
}

private extension AppSettings {
    static func loadPersistedKeyBindings(from defaults: UserDefaults) -> [PlayerKeyAction: KeyBinding] {
        if let payload = defaults.data(forKey: "playerKeyBindings"),
           let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: payload) {
            var resolved = Dictionary(uniqueKeysWithValues: PlayerKeyAction.allCases.map { ($0, $0.defaultBinding) })
            for (rawKey, binding) in decoded {
                guard let action = PlayerKeyAction(rawValue: rawKey) else { continue }
                resolved[action] = binding
            }
            return resolved
        }

        var migrated = Dictionary(uniqueKeysWithValues: PlayerKeyAction.allCases.map { ($0, $0.defaultBinding) })

        if let playPause = legacyBinding(forKey: "playPauseKey", defaults: defaults) {
            migrated[.playPause] = playPause
        }
        if let seekBack = legacyBinding(forKey: "seekBackKey", defaults: defaults) {
            migrated[.seekMediumBack] = seekBack
        }
        if let seekForward = legacyBinding(forKey: "seekFwdKey", defaults: defaults) {
            migrated[.seekMediumForward] = seekForward
        }
        if let frameBack = legacyBinding(forKey: "frameBackKey", defaults: defaults) {
            migrated[.frameBack] = frameBack
        }
        if let frameForward = legacyBinding(forKey: "frameFwdKey", defaults: defaults) {
            migrated[.frameForward] = frameForward
        }
        if let theater = legacyBinding(forKey: "theaterKey", defaults: defaults) {
            migrated[.theaterMode] = theater
        }
        if let fullscreen = legacyBinding(forKey: "fullscreenKey", defaults: defaults) {
            migrated[.fullscreen] = fullscreen
        }
        if let subtitles = legacyBinding(forKey: "subtitleKey", defaults: defaults) {
            migrated[.subtitles] = subtitles
        }

        return migrated
    }

    static func legacyBinding(forKey key: String, defaults: UserDefaults) -> KeyBinding? {
        guard let rawValue = defaults.string(forKey: key),
              rawValue.isEmpty == false else {
            return nil
        }
        return KeyBinding.legacyCharacter(rawValue)
    }

    func persistKeyBindings() {
        let payload = Dictionary(uniqueKeysWithValues: keyBindings.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: keyBindingsKey)
    }

    static func loadSponsorBlockCategoryBehaviors(
        from defaults: UserDefaults,
        legacyAutoSkipEnabled: Bool
    ) -> [SponsorBlockCategory: SponsorBlockBehavior] {
        if let payload = defaults.data(forKey: "sponsorBlockCategoryBehaviors"),
           let decoded = try? JSONDecoder().decode([String: SponsorBlockBehavior].self, from: payload) {
            var resolved = Dictionary(uniqueKeysWithValues: SponsorBlockCategory.allCases.map { ($0, $0.defaultBehavior) })
            for (rawCategory, behavior) in decoded {
                guard let category = SponsorBlockCategory(rawValue: rawCategory) else { continue }
                resolved[category] = behavior
            }
            return resolved
        }

        return Dictionary(uniqueKeysWithValues: SponsorBlockCategory.allCases.map { category in
            (category, category.defaultBehavior)
        })
    }

    func persistSponsorBlockCategoryBehaviors() {
        let payload = Dictionary(uniqueKeysWithValues: sponsorBlockCategoryBehaviors.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: sponsorBlockCategoryBehaviorsKey)
    }
}
