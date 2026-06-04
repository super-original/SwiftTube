import SwiftUI

struct ShimmerText: View {
    let text: String
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.4) / 1.4

            Text(text)
                .font(font)
                .foregroundStyle(.secondary)
                .overlay {
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.primary.opacity(0.18),
                                Color.primary.opacity(0.92),
                                Color.primary.opacity(0.18),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.72)
                        .offset(x: -width * 0.68 + width * 1.58 * phase)
                    }
                    .mask(Text(text).font(font))
                }
        }
    }
}

struct SwiftTubeSpinner: View {
    var size: CGFloat = 26

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: max(size * 0.16, 4)) {
                ForEach(0..<3, id: \.self) { index in
                    let localPhase = phase * 3.2 - Double(index) * 0.32
                    let lift = sin(localPhase * .pi)
                    Circle()
                        .fill(Color.white.opacity(0.56 + max(lift, 0) * 0.36))
                        .frame(width: size * 0.22, height: size * 0.22)
                        .offset(y: -max(lift, 0) * size * 0.24)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

struct LoadingStatusView: View {
    let text: String
    var iconSize: CGFloat = 22
    var spinnerSize: CGFloat = 24
    var browsers: [BrowserLoginOption] = []

    var body: some View {
        HStack(spacing: 9) {
            SwiftTubeSpinner(size: spinnerSize)
            ShimmerText(text: text)

            if browsers.isEmpty == false {
                HStack(spacing: 4) {
                    ForEach(Array(browsers.enumerated()), id: \.element.id) { index, browser in
                        BrowserLoadingIcon(browser: browser, index: index, size: iconSize)
                    }
                }
                .padding(.leading, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LoadingMoreIndicator: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            SwiftTubeSpinner(size: 24)
            ShimmerText(text: text, font: .callout.weight(.semibold))
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

private struct BrowserLoadingIcon: View {
    let browser: BrowserLoginOption
    let index: Int
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 2.2 + Double(index) * 0.42
            let lift = max(sin(phase * .pi), 0)

            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .brightness(lift * 0.10)
                .opacity(0.74 + lift * 0.26)
                .scaleEffect(0.94 + lift * 0.06)
                .offset(y: -lift * 3)
                .help(browser.displayName)
        }
        .frame(width: size, height: size)
    }

    private var icon: NSImage {
        if let bundleID = browser.primaryBundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: browser.fallbackSymbol, accessibilityDescription: browser.displayName)
            ?? NSImage(size: NSSize(width: size, height: size))
    }
}
