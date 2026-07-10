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
                AccountAvatarImage(
                    url: status.avatarURL,
                    size: 38,
                    fallbackSymbol: status.authenticated
                        ? "person.crop.circle.badge.checkmark"
                        : "person.crop.circle"
                )

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

private extension String {
    var nonEmptyDisplayText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
