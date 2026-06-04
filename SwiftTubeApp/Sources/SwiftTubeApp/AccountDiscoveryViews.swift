import AppKit
import SwiftUI

struct SidebarAccountButton: View {
    let status: AuthStatusResponse
    let action: () -> Void

    private var title: String {
        status.displayName?.nonEmptyDisplayText
            ?? (status.authenticated ? "YouTube" : "Sign in")
    }

    private var subtitle: String {
        status.accountIdentifier?.nonEmptyDisplayText
            ?? status.browserLabel?.nonEmptyDisplayText
            ?? "Account"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AccountAvatarImage(url: status.avatarURL, size: 38, fallbackSymbol: status.authenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct AccountDiscoveryCard: View {
    let account: BrowserAccountDiscoveryResponse
    let isWorking: Bool
    let pendingSource: BrowserAccountSource?
    let action: (BrowserAccountSource) -> Void

    var body: some View {
        Button {
            if let source = account.sources.first {
                action(source)
            }
        } label: {
            HStack(alignment: .top, spacing: 16) {
                AccountAvatarImage(url: account.avatarURL, size: 58, fallbackSymbol: "person.crop.circle")

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName)
                            .font(.headline.weight(.bold))
                            .lineLimit(1)
                        if let identifier = account.identifier?.nonEmptyDisplayText {
                            Text(identifier)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    FlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(account.sources) { source in
                            BrowserSourcePill(source: source)
                        }
                    }
                }

                Spacer(minLength: 0)

                if account.sources.contains(where: { $0.id == pendingSource?.id }) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.right.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.separator.opacity(0.9), lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .disabled(isWorking || account.sources.isEmpty)
    }
}

struct BrowserSourcePill: View {
    let source: BrowserAccountSource

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: accountBrowserIcon(for: source))
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(source.browserLabel)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
        )
    }
}

struct AccountAvatarImage: View {
    let url: URL?
    let size: CGFloat
    let fallbackSymbol: String

    var body: some View {
        Group {
            if let url {
                CachedAsyncImage(url: url, maxPixelSize: Int(size * 3), contentMode: .fill) {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    private var fallback: some View {
        Circle()
            .fill(Color.primary.opacity(0.08))
            .overlay(
                Image(systemName: fallbackSymbol)
                    .font(.system(size: max(18, size * 0.46), weight: .semibold))
                    .foregroundStyle(.secondary)
            )
    }
}

func accountBrowserIcon(for source: BrowserAccountSource) -> NSImage {
    if let bundleIdentifier = source.bundleIdentifier,
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    if let browser = BrowserLoginOption(rawValue: source.browser),
       let symbol = NSImage(systemSymbolName: browser.fallbackSymbol, accessibilityDescription: nil) {
        return symbol
    }

    return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
}

private struct FlowLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(in: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * rowSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func rows(in availableWidth: CGFloat, subviews: Subviews) -> [FlowRow] {
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let candidateWidth = currentItems.isEmpty ? size.width : currentWidth + spacing + size.width
            if currentItems.isEmpty == false, candidateWidth > availableWidth {
                rows.append(FlowRow(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = [FlowItem(subview: subview, size: size)]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentItems.append(FlowItem(subview: subview, size: size))
                currentWidth = candidateWidth
                currentHeight = max(currentHeight, size.height)
            }
        }

        if currentItems.isEmpty == false {
            rows.append(FlowRow(items: currentItems, width: currentWidth, height: currentHeight))
        }

        return rows
    }

    private struct FlowRow {
        let items: [FlowItem]
        let width: CGFloat
        let height: CGFloat
    }

    private struct FlowItem {
        let subview: LayoutSubview
        let size: CGSize
    }
}

private extension String {
    var nonEmptyDisplayText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
