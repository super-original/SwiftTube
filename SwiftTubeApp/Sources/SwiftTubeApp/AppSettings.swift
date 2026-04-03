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
    case light
    case sunrise
    case sky
    case mint
    case rose
    case sand
    case lavender
    case citrus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .midnight: return "Midnight"
        case .midnightOcean: return "Midnight Ocean"
        case .midnightForest: return "Midnight Forest"
        case .midnightRose: return "Midnight Rose"
        case .midnightAurora: return "Midnight Aurora"
        case .midnightEmber: return "Midnight Ember"
        case .midnightAmethyst: return "Midnight Amethyst"
        case .light: return "Light"
        case .sunrise: return "Sunrise"
        case .sky: return "Sky"
        case .mint: return "Mint"
        case .rose: return "Rose"
        case .sand: return "Sand"
        case .lavender: return "Lavender"
        case .citrus: return "Citrus"
        }
    }

    var subtitle: String {
        switch self {
        case .dark: return "Matches the native macOS dark baseline at #1E1E1E."
        case .midnight: return "Low-glare neutral dark built around #0F0F0F."
        case .midnightOcean: return "Deep blue midnight with a cool neon cast."
        case .midnightForest: return "Dark evergreen tones with calmer contrast."
        case .midnightRose: return "Dark charcoal with a subtle cherry-magenta glow."
        case .midnightAurora: return "A vivid blue-violet midnight with aurora highlights."
        case .midnightEmber: return "Warm charcoal with copper and ember undertones."
        case .midnightAmethyst: return "A plush midnight purple with a richer glow."
        case .light: return "Bright, native macOS styling across the app."
        case .sunrise: return "Warm paper-like light theme with a peach tint."
        case .sky: return "Airy light theme with cool blue surfaces."
        case .mint: return "Soft mint light theme with gentle green cards."
        case .rose: return "Rosy light theme with a soft editorial feel."
        case .sand: return "Soft neutral light theme with warm beige surfaces."
        case .lavender: return "A pale violet light theme with softer contrast."
        case .citrus: return "Fresh cream theme with lemon-lime highlights."
        }
    }

    var preferredColorScheme: ColorScheme {
        switch self {
        case .dark, .midnight, .midnightOcean, .midnightForest, .midnightRose, .midnightAurora, .midnightEmber, .midnightAmethyst:
            return .dark
        case .light, .sunrise, .sky, .mint, .rose, .sand, .lavender, .citrus:
            return .light
        }
    }

    var windowBackgroundColor: Color {
        Color(nsColor: nsWindowBackgroundColor)
    }

    var cardBackgroundColor: Color {
        Color(nsColor: nsCardBackgroundColor)
    }

    var sidebarBackgroundColor: Color {
        Color(nsColor: nsSidebarBackgroundColor)
    }

    var elevatedBackgroundColor: Color {
        Color(nsColor: nsElevatedBackgroundColor)
    }

    var hoverCardBackgroundColor: Color {
        Color(nsColor: nsHoverCardBackgroundColor)
    }

    var separatorColor: Color {
        Color(nsColor: nsSeparatorColor)
    }

    var previewGradient: LinearGradient {
        LinearGradient(colors: previewColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var nsWindowBackgroundColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
        case .midnight:
            return NSColor(calibratedRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
        case .midnightOcean:
            return NSColor(calibratedRed: 13 / 255, green: 18 / 255, blue: 28 / 255, alpha: 1)
        case .midnightForest:
            return NSColor(calibratedRed: 14 / 255, green: 20 / 255, blue: 17 / 255, alpha: 1)
        case .midnightRose:
            return NSColor(calibratedRed: 24 / 255, green: 16 / 255, blue: 23 / 255, alpha: 1)
        case .midnightAurora:
            return NSColor(calibratedRed: 15 / 255, green: 18 / 255, blue: 32 / 255, alpha: 1)
        case .midnightEmber:
            return NSColor(calibratedRed: 28 / 255, green: 18 / 255, blue: 16 / 255, alpha: 1)
        case .midnightAmethyst:
            return NSColor(calibratedRed: 20 / 255, green: 16 / 255, blue: 31 / 255, alpha: 1)
        case .light:
            return NSColor.windowBackgroundColor
        case .sunrise:
            return NSColor(calibratedRed: 249 / 255, green: 242 / 255, blue: 236 / 255, alpha: 1)
        case .sky:
            return NSColor(calibratedRed: 239 / 255, green: 245 / 255, blue: 252 / 255, alpha: 1)
        case .mint:
            return NSColor(calibratedRed: 238 / 255, green: 248 / 255, blue: 243 / 255, alpha: 1)
        case .rose:
            return NSColor(calibratedRed: 252 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
        case .sand:
            return NSColor(calibratedRed: 245 / 255, green: 238 / 255, blue: 228 / 255, alpha: 1)
        case .lavender:
            return NSColor(calibratedRed: 245 / 255, green: 241 / 255, blue: 252 / 255, alpha: 1)
        case .citrus:
            return NSColor(calibratedRed: 248 / 255, green: 247 / 255, blue: 229 / 255, alpha: 1)
        }
    }

    private var nsCardBackgroundColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedRed: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1)
        case .midnight:
            return NSColor(calibratedRed: 24 / 255, green: 24 / 255, blue: 24 / 255, alpha: 1)
        case .midnightOcean:
            return NSColor(calibratedRed: 24 / 255, green: 31 / 255, blue: 44 / 255, alpha: 1)
        case .midnightForest:
            return NSColor(calibratedRed: 25 / 255, green: 34 / 255, blue: 29 / 255, alpha: 1)
        case .midnightRose:
            return NSColor(calibratedRed: 36 / 255, green: 24 / 255, blue: 35 / 255, alpha: 1)
        case .midnightAurora:
            return NSColor(calibratedRed: 26 / 255, green: 32 / 255, blue: 52 / 255, alpha: 1)
        case .midnightEmber:
            return NSColor(calibratedRed: 44 / 255, green: 29 / 255, blue: 24 / 255, alpha: 1)
        case .midnightAmethyst:
            return NSColor(calibratedRed: 34 / 255, green: 27 / 255, blue: 50 / 255, alpha: 1)
        case .light:
            return NSColor.controlBackgroundColor
        case .sunrise:
            return NSColor(calibratedRed: 1, green: 249 / 255, blue: 244 / 255, alpha: 1)
        case .sky:
            return NSColor(calibratedRed: 248 / 255, green: 251 / 255, blue: 1, alpha: 1)
        case .mint:
            return NSColor(calibratedRed: 246 / 255, green: 1, blue: 250 / 255, alpha: 1)
        case .rose:
            return NSColor(calibratedRed: 1, green: 247 / 255, blue: 250 / 255, alpha: 1)
        case .sand:
            return NSColor(calibratedRed: 252 / 255, green: 247 / 255, blue: 240 / 255, alpha: 1)
        case .lavender:
            return NSColor(calibratedRed: 250 / 255, green: 247 / 255, blue: 1, alpha: 1)
        case .citrus:
            return NSColor(calibratedRed: 1, green: 253 / 255, blue: 239 / 255, alpha: 1)
        }
    }

    private var nsSidebarBackgroundColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedRed: 36 / 255, green: 36 / 255, blue: 36 / 255, alpha: 1)
        case .midnight:
            return NSColor(calibratedRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
        case .midnightOcean:
            return NSColor(calibratedRed: 18 / 255, green: 26 / 255, blue: 42 / 255, alpha: 1)
        case .midnightForest:
            return NSColor(calibratedRed: 18 / 255, green: 28 / 255, blue: 23 / 255, alpha: 1)
        case .midnightRose:
            return NSColor(calibratedRed: 31 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1)
        case .midnightAurora:
            return NSColor(calibratedRed: 20 / 255, green: 24 / 255, blue: 44 / 255, alpha: 1)
        case .midnightEmber:
            return NSColor(calibratedRed: 35 / 255, green: 22 / 255, blue: 18 / 255, alpha: 1)
        case .midnightAmethyst:
            return NSColor(calibratedRed: 27 / 255, green: 22 / 255, blue: 40 / 255, alpha: 1)
        case .light:
            return NSColor(calibratedRed: 243 / 255, green: 245 / 255, blue: 248 / 255, alpha: 1)
        case .sunrise:
            return NSColor(calibratedRed: 245 / 255, green: 236 / 255, blue: 228 / 255, alpha: 1)
        case .sky:
            return NSColor(calibratedRed: 231 / 255, green: 239 / 255, blue: 249 / 255, alpha: 1)
        case .mint:
            return NSColor(calibratedRed: 230 / 255, green: 242 / 255, blue: 235 / 255, alpha: 1)
        case .rose:
            return NSColor(calibratedRed: 247 / 255, green: 233 / 255, blue: 239 / 255, alpha: 1)
        case .sand:
            return NSColor(calibratedRed: 241 / 255, green: 234 / 255, blue: 223 / 255, alpha: 1)
        case .lavender:
            return NSColor(calibratedRed: 239 / 255, green: 233 / 255, blue: 249 / 255, alpha: 1)
        case .citrus:
            return NSColor(calibratedRed: 240 / 255, green: 246 / 255, blue: 218 / 255, alpha: 1)
        }
    }

    private var nsElevatedBackgroundColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedRed: 45 / 255, green: 45 / 255, blue: 45 / 255, alpha: 1)
        case .midnight:
            return NSColor(calibratedRed: 28 / 255, green: 28 / 255, blue: 28 / 255, alpha: 1)
        case .midnightOcean:
            return NSColor(calibratedRed: 30 / 255, green: 38 / 255, blue: 56 / 255, alpha: 1)
        case .midnightForest:
            return NSColor(calibratedRed: 30 / 255, green: 40 / 255, blue: 33 / 255, alpha: 1)
        case .midnightRose:
            return NSColor(calibratedRed: 42 / 255, green: 28 / 255, blue: 40 / 255, alpha: 1)
        case .midnightAurora:
            return NSColor(calibratedRed: 31 / 255, green: 36 / 255, blue: 61 / 255, alpha: 1)
        case .midnightEmber:
            return NSColor(calibratedRed: 47 / 255, green: 30 / 255, blue: 24 / 255, alpha: 1)
        case .midnightAmethyst:
            return NSColor(calibratedRed: 40 / 255, green: 31 / 255, blue: 57 / 255, alpha: 1)
        case .light:
            return NSColor.white
        case .sunrise:
            return NSColor(calibratedRed: 1, green: 246 / 255, blue: 241 / 255, alpha: 1)
        case .sky:
            return NSColor(calibratedRed: 247 / 255, green: 250 / 255, blue: 1, alpha: 1)
        case .mint:
            return NSColor(calibratedRed: 245 / 255, green: 252 / 255, blue: 248 / 255, alpha: 1)
        case .rose:
            return NSColor(calibratedRed: 1, green: 245 / 255, blue: 248 / 255, alpha: 1)
        case .sand:
            return NSColor(calibratedRed: 250 / 255, green: 245 / 255, blue: 236 / 255, alpha: 1)
        case .lavender:
            return NSColor(calibratedRed: 250 / 255, green: 247 / 255, blue: 1, alpha: 1)
        case .citrus:
            return NSColor(calibratedRed: 251 / 255, green: 1, blue: 244 / 255, alpha: 1)
        }
    }

    private var nsHoverCardBackgroundColor: NSColor {
        switch self.preferredColorScheme {
        case .dark:
            return NSColor.white.withAlphaComponent(0.07)
        case .light:
            return NSColor.black.withAlphaComponent(0.06)
        @unknown default:
            return NSColor.black.withAlphaComponent(0.06)
        }
    }

    private var nsSeparatorColor: NSColor {
        switch self.preferredColorScheme {
        case .dark:
            return NSColor.white.withAlphaComponent(0.08)
        case .light:
            return NSColor.black.withAlphaComponent(0.08)
        @unknown default:
            return NSColor.black.withAlphaComponent(0.08)
        }
    }

    private var previewColors: [Color] {
        switch self {
        case .dark:
            return [Color(red: 46 / 255, green: 46 / 255, blue: 46 / 255), Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)]
        case .midnight:
            return [Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255), Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)]
        case .midnightOcean:
            return [Color(red: 49 / 255, green: 74 / 255, blue: 124 / 255), Color(red: 13 / 255, green: 18 / 255, blue: 28 / 255)]
        case .midnightForest:
            return [Color(red: 74 / 255, green: 108 / 255, blue: 85 / 255), Color(red: 14 / 255, green: 20 / 255, blue: 17 / 255)]
        case .midnightRose:
            return [Color(red: 123 / 255, green: 67 / 255, blue: 110 / 255), Color(red: 24 / 255, green: 16 / 255, blue: 23 / 255)]
        case .midnightAurora:
            return [Color(red: 74 / 255, green: 111 / 255, blue: 1), Color(red: 90 / 255, green: 52 / 255, blue: 184 / 255)]
        case .midnightEmber:
            return [Color(red: 215 / 255, green: 117 / 255, blue: 55 / 255), Color(red: 76 / 255, green: 35 / 255, blue: 19 / 255)]
        case .midnightAmethyst:
            return [Color(red: 149 / 255, green: 110 / 255, blue: 1), Color(red: 67 / 255, green: 45 / 255, blue: 126 / 255)]
        case .light:
            return [Color.white, Color(red: 228 / 255, green: 232 / 255, blue: 238 / 255)]
        case .sunrise:
            return [Color(red: 1, green: 232 / 255, blue: 210 / 255), Color(red: 249 / 255, green: 242 / 255, blue: 236 / 255)]
        case .sky:
            return [Color(red: 202 / 255, green: 227 / 255, blue: 1), Color(red: 239 / 255, green: 245 / 255, blue: 252 / 255)]
        case .mint:
            return [Color(red: 198 / 255, green: 241 / 255, blue: 224 / 255), Color(red: 238 / 255, green: 248 / 255, blue: 243 / 255)]
        case .rose:
            return [Color(red: 1, green: 218 / 255, blue: 230 / 255), Color(red: 252 / 255, green: 240 / 255, blue: 244 / 255)]
        case .sand:
            return [Color(red: 234 / 255, green: 212 / 255, blue: 175 / 255), Color(red: 248 / 255, green: 240 / 255, blue: 225 / 255)]
        case .lavender:
            return [Color(red: 225 / 255, green: 206 / 255, blue: 1), Color(red: 239 / 255, green: 233 / 255, blue: 249 / 255)]
        case .citrus:
            return [Color(red: 211 / 255, green: 244 / 255, blue: 119 / 255), Color(red: 1, green: 236 / 255, blue: 154 / 255)]
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

final class AppSettings: ObservableObject {
    nonisolated(unsafe) static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let sidebarOrderKey = "sidebarItemOrder"
    private let sidebarHiddenKey = "hiddenSidebarItems"
    private let keyBindingsKey = "playerKeyBindings"

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

    init() {
        let storedAppearance = defaults.string(forKey: "appearanceMode") ?? ""
        self.appearanceMode = AppAppearanceMode(rawValue: storedAppearance)
            ?? (storedAppearance == "oledDark" ? .midnight : .dark)
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
    }

    static let seekSecondsOptions = [3, 5, 10, 15, 30, 45, 60, 90]
    static let playbackSpeedOptions: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static let spacebarHoldPlaybackSpeedOptions: [Double] = [1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

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
        !hiddenSidebarItems.contains(item.rawValue)
    }

    func setSidebarItem(_ item: SidebarItemKind, visible: Bool) {
        if visible {
            hiddenSidebarItems.remove(item.rawValue)
        } else {
            hiddenSidebarItems.insert(item.rawValue)
        }
    }

    func moveSidebarItems(from source: IndexSet, to destination: Int) {
        sidebarItemOrder.move(fromOffsets: source, toOffset: destination)
    }

    func reorderSidebarItem(_ dragged: SidebarItemKind, before target: SidebarItemKind) {
        guard dragged != target,
              let sourceIndex = sidebarItemOrder.firstIndex(of: dragged),
              let targetIndex = sidebarItemOrder.firstIndex(of: target) else {
            return
        }

        var updatedOrder = sidebarItemOrder
        updatedOrder.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        updatedOrder.insert(dragged, at: adjustedTarget)
        sidebarItemOrder = updatedOrder
    }

    func visibleSidebarItems(isAuthenticated: Bool) -> [SidebarItemKind] {
        let available = sidebarItemOrder.filter { item in
            switch item {
            case .home:
                return true
            case .playlists, .watchLater, .likedVideos:
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
}
