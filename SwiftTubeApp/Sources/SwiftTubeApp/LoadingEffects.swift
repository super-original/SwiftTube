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
            ZStack {
                ForEach(0..<10, id: \.self) { index in
                    Capsule()
                        .fill(segmentColor(index: index, phase: phase))
                        .frame(width: max(size * 0.12, 3), height: size * 0.32)
                        .offset(y: -size * 0.34)
                        .rotationEffect(.degrees(Double(index) * 36))
                }
            }
            .rotationEffect(.degrees(phase * 220))
            .frame(width: size, height: size)
        }
    }

    private func segmentColor(index: Int, phase: TimeInterval) -> Color {
        let head = Int((phase * 10).rounded(.down)) % 10
        let distance = (index - head + 10) % 10
        let opacity = max(0.18, 1.0 - Double(distance) * 0.095)
        return BrandAssets.swiftTubeBlue.opacity(opacity)
    }
}

struct LoadingStatusView: View {
    let text: String
    var iconSize: CGFloat = 22
    var spinnerSize: CGFloat = 24
    var browsers: [BrowserLoginOption] = []

    var body: some View {
        HStack(spacing: 10) {
            SwiftTubeSpinner(size: spinnerSize)
            ShimmerText(text: text)

            if browsers.isEmpty == false {
                HStack(spacing: -5) {
                    ForEach(browsers) { browser in
                        BrowserLoadingIcon(browser: browser, size: iconSize)
                    }
                }
                .padding(.leading, 2)
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
    let size: CGFloat

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .padding(4)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            .help(browser.displayName)
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
