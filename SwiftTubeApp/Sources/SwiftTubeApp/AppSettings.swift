import Foundation

final class AppSettings: ObservableObject {
    nonisolated(unsafe) static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Playback

    @Published var defaultQuality: DefaultQuality {
        didSet { defaults.set(defaultQuality.rawValue, forKey: "defaultQuality") }
    }

    // MARK: - Controls

    @Published var arrowSeekSeconds: Int {
        didSet { defaults.set(arrowSeekSeconds, forKey: "arrowSeekSeconds") }
    }

    @Published var jlSeekSeconds: Int {
        didSet { defaults.set(jlSeekSeconds, forKey: "jlSeekSeconds") }
    }

    @Published var commaSeekMode: SeekMode {
        didSet { defaults.set(commaSeekMode.rawValue, forKey: "commaSeekMode") }
    }

    @Published var keyboardLockKey: KeyboardLockKey {
        didSet { defaults.set(keyboardLockKey.rawValue, forKey: "keyboardLockKey") }
    }

    // MARK: - Key bindings (single lowercase character, empty = disabled)

    @Published var playPauseKey: String {
        didSet { defaults.set(playPauseKey, forKey: "playPauseKey") }
    }
    @Published var seekBackKey: String {
        didSet { defaults.set(seekBackKey, forKey: "seekBackKey") }
    }
    @Published var seekFwdKey: String {
        didSet { defaults.set(seekFwdKey, forKey: "seekFwdKey") }
    }
    @Published var frameBackKey: String {
        didSet { defaults.set(frameBackKey, forKey: "frameBackKey") }
    }
    @Published var frameFwdKey: String {
        didSet { defaults.set(frameFwdKey, forKey: "frameFwdKey") }
    }
    @Published var theaterKey: String {
        didSet { defaults.set(theaterKey, forKey: "theaterKey") }
    }
    @Published var fullscreenKey: String {
        didSet { defaults.set(fullscreenKey, forKey: "fullscreenKey") }
    }
    @Published var subtitleKey: String {
        didSet { defaults.set(subtitleKey, forKey: "subtitleKey") }
    }

    // MARK: - Init

    init() {
        self.defaultQuality = DefaultQuality(rawValue: defaults.string(forKey: "defaultQuality") ?? "") ?? .auto
        let arrow = defaults.integer(forKey: "arrowSeekSeconds")
        self.arrowSeekSeconds = arrow > 0 ? arrow : 5
        let jl = defaults.integer(forKey: "jlSeekSeconds")
        self.jlSeekSeconds = jl > 0 ? jl : 10
        self.commaSeekMode = SeekMode(rawValue: defaults.string(forKey: "commaSeekMode") ?? "") ?? .frame
        self.keyboardLockKey = KeyboardLockKey(rawValue: defaults.string(forKey: "keyboardLockKey") ?? "") ?? .disabled

        let _pp = defaults.string(forKey: "playPauseKey")  ?? ""; self.playPauseKey  = _pp.isEmpty ? "k" : _pp
        let _sb = defaults.string(forKey: "seekBackKey")   ?? ""; self.seekBackKey   = _sb.isEmpty ? "j" : _sb
        let _sf = defaults.string(forKey: "seekFwdKey")    ?? ""; self.seekFwdKey    = _sf.isEmpty ? "l" : _sf
        let _fb = defaults.string(forKey: "frameBackKey")  ?? ""; self.frameBackKey  = _fb.isEmpty ? "," : _fb
        let _ff = defaults.string(forKey: "frameFwdKey")   ?? ""; self.frameFwdKey   = _ff.isEmpty ? "." : _ff
        let _th = defaults.string(forKey: "theaterKey")    ?? ""; self.theaterKey    = _th.isEmpty ? "t" : _th
        let _fs = defaults.string(forKey: "fullscreenKey") ?? ""; self.fullscreenKey = _fs.isEmpty ? "f" : _fs
        let _su = defaults.string(forKey: "subtitleKey")   ?? ""; self.subtitleKey   = _su.isEmpty ? "c" : _su
    }

    // MARK: - Types

    static let seekSecondsOptions = [5, 10, 15, 30, 60]



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
            case .auto:  return nil
            case .p360:  return 360
            case .p480:  return 480
            case .p720:  return 720
            case .p1080: return 1080
            case .p1440: return 1440
            case .p2160: return 2160
            }
        }
    }

    enum SeekMode: String, CaseIterable, Identifiable {
        case frame = "frame"
        case s1    = "1"
        case s5    = "5"
        case s10   = "10"
        case s30   = "30"

        var id: String { rawValue }

        var seconds: Double? {
            switch self {
            case .frame: return nil
            case .s1:    return 1
            case .s5:    return 5
            case .s10:   return 10
            case .s30:   return 30
            }
        }

        var label: String {
            switch self {
            case .frame: return "1 Frame"
            case .s1:    return "1s"
            case .s5:    return "5s"
            case .s10:   return "10s"
            case .s30:   return "30s"
            }
        }
    }

    enum KeyboardLockKey: String, CaseIterable, Identifiable {
        case disabled  = "disabled"
        case backtick  = "backtick"
        case backslash = "backslash"
        case z         = "z"
        case x         = "x"

        var id: String { rawValue }

        var character: Character? {
            switch self {
            case .disabled:  return nil
            case .backtick:  return "`"
            case .backslash: return "\\"
            case .z:         return "z"
            case .x:         return "x"
            }
        }

        var displayName: String {
            switch self {
            case .disabled:  return "Disabled"
            case .backtick:  return "` (Backtick)"
            case .backslash: return "\\ (Backslash)"
            case .z:         return "Z"
            case .x:         return "X"
            }
        }
    }
}
