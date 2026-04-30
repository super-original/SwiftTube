import SwiftUI

enum SponsorBlockBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    case disabled
    case seekBar
    case manual
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled:
            return "Disable"
        case .seekBar:
            return "Show in seek bar"
        case .manual:
            return "Manual skip"
        case .auto:
            return "Auto skip"
        }
    }

    var showsInSeekBar: Bool {
        switch self {
        case .disabled:
            return false
        case .seekBar, .manual, .auto:
            return true
        }
    }

    var showsManualPrompt: Bool {
        self == .manual
    }

    var autoSkips: Bool {
        self == .auto
    }
}

enum SponsorBlockCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case sponsor
    case selfpromo
    case interaction
    case intro
    case outro
    case preview
    case hook
    case filler

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sponsor:
            return "Sponsor"
        case .selfpromo:
            return "Unpaid / Self Promotion"
        case .interaction:
            return "Interaction Reminder"
        case .intro:
            return "Intermission / Intro Animation"
        case .outro:
            return "Endcards / Credits"
        case .preview:
            return "Preview / Recap"
        case .hook:
            return "Hook / Teaser"
        case .filler:
            return "Tangents / Filler"
        }
    }

    var shortTitle: String {
        switch self {
        case .interaction:
            return "Reminder"
        case .intro:
            return "Intro"
        case .outro:
            return "Endcards"
        case .preview:
            return "Preview"
        case .selfpromo:
            return "Self Promo"
        case .hook:
            return "Hook"
        case .filler:
            return "Filler"
        case .sponsor:
            return "Sponsor"
        }
    }

    var description: String {
        switch self {
        case .sponsor:
            return "Paid promotions, referrals, and direct ads."
        case .selfpromo:
            return "Creator merch, monetized platforms, charity drives, or unpaid shout-outs."
        case .interaction:
            return "Reminders to like, subscribe, follow, comment, or click."
        case .intro:
            return "Repeated intro animations, title cards, pauses, and opening jingles."
        case .outro:
            return "Endcards, credits, and outro sections after the main content."
        case .preview:
            return "Previews or recaps where the information appears later."
        case .hook:
            return "Teasers, greetings, and goodbyes without new conclusions."
        case .filler:
            return "Tangents, jokes, B-roll, fake sponsors, or other non-essential scenes."
        }
    }

    var tint: Color {
        switch self {
        case .sponsor:
            return Color(red: 0.24, green: 0.82, blue: 0.51)
        case .selfpromo:
            return Color(red: 0.93, green: 0.58, blue: 0.21)
        case .interaction:
            return Color(red: 0.95, green: 0.24, blue: 0.32)
        case .intro:
            return Color(red: 0.28, green: 0.66, blue: 0.98)
        case .outro:
            return Color(red: 0.62, green: 0.67, blue: 0.78)
        case .preview:
            return Color(red: 0.72, green: 0.46, blue: 0.97)
        case .hook:
            return Color(red: 0.97, green: 0.44, blue: 0.73)
        case .filler:
            return Color(red: 0.97, green: 0.76, blue: 0.22)
        }
    }

    var defaultBehavior: SponsorBlockBehavior {
        switch self {
        case .sponsor, .selfpromo, .interaction, .intro:
            return .manual
        case .outro, .preview, .hook, .filler:
            return .disabled
        }
    }
}

extension SponsorBlockSegment {
    var resolvedCategory: SponsorBlockCategory? {
        SponsorBlockCategory(rawValue: category)
    }

    var categoryTitle: String {
        resolvedCategory?.title ?? category.capitalized
    }

    var categoryShortTitle: String {
        resolvedCategory?.shortTitle ?? category.capitalized
    }

    var categoryTint: Color {
        resolvedCategory?.tint ?? Color(red: 0.24, green: 0.82, blue: 0.51)
    }

    func contains(_ time: Double, leadIn: Double = 0, trailOut: Double = 0) -> Bool {
        time >= max(startTime - leadIn, 0) && time < endTime + trailOut
    }

    func skipTarget(within duration: Double) -> Double {
        min(max(endTime + 0.05, 0), duration)
    }
}
