import Foundation
import SwiftUI

enum MutationQueueKey {
    static func subscription(videoID: String) -> String {
        "subscription:\(videoID)"
    }

    static func rating(videoID: String) -> String {
        "rating:\(videoID)"
    }

    static func watchLater(videoID: String) -> String {
        "watch-later:\(videoID)"
    }

    static func playlist(videoID: String, playlistID: String) -> String {
        "playlist:\(videoID):\(playlistID)"
    }

    static func watchHistory(videoID: String) -> String {
        "history:\(videoID)"
    }

    static func playlistMembership(playlistID: String, setVideoID: String) -> String {
        "playlist-membership:\(playlistID):\(setVideoID)"
    }

    static func playlistPosition(playlistID: String, setVideoID: String) -> String {
        "playlist-position:\(playlistID):\(setVideoID)"
    }

    static func playlistOrder(playlistID: String) -> String {
        "playlist-order:\(playlistID)"
    }
}

enum AppNotificationAccent: String, Sendable {
    case blue
    case green
    case red
    case amber

    var color: Color {
        switch self {
        case .blue:
            return Color(red: 0.31, green: 0.61, blue: 1.0)
        case .green:
            return Color(red: 0.24, green: 0.84, blue: 0.55)
        case .red:
            return Color(red: 1.0, green: 0.38, blue: 0.44)
        case .amber:
            return Color(red: 1.0, green: 0.75, blue: 0.28)
        }
    }
}

struct NotificationColorValue: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }
}

struct MutationNotice: Sendable {
    let title: String
    let message: String?
    let symbol: String
    let accent: AppNotificationAccent
    let customColor: NotificationColorValue?

    init(
        title: String,
        message: String?,
        symbol: String,
        accent: AppNotificationAccent,
        customColor: NotificationColorValue? = nil
    ) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.accent = accent
        self.customColor = customColor
    }
}

struct AppNotificationItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String?
    let symbol: String
    let accent: AppNotificationAccent
    let customColor: NotificationColorValue?
}

private struct EmptyMutationResult: Sendable {}

private final class QueuedMutation: @unchecked Sendable {
    let revision: Int
    let successNotice: MutationNotice?
    let errorNotice: @Sendable (Error) -> MutationNotice
    let execute: @Sendable () async throws -> any Sendable
    let applySuccess: @MainActor (any Sendable) -> Void
    let applyFailure: @MainActor (Error) -> Void

    init(
        revision: Int,
        successNotice: MutationNotice?,
        errorNotice: @escaping @Sendable (Error) -> MutationNotice,
        execute: @escaping @Sendable () async throws -> any Sendable,
        applySuccess: @escaping @MainActor (any Sendable) -> Void,
        applyFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.revision = revision
        self.successNotice = successNotice
        self.errorNotice = errorNotice
        self.execute = execute
        self.applySuccess = applySuccess
        self.applyFailure = applyFailure
    }
}

@MainActor
final class AppMutationCenter: ObservableObject {
    static let shared = AppMutationCenter()

    @Published private(set) var notifications: [AppNotificationItem] = []
    @Published private(set) var pendingKeys: Set<String> = []

    private struct MutationState {
        var latestRevision = 0
        var queued: QueuedMutation? = nil
        var isRunning = false
    }

    private var states: [String: MutationState] = [:]

    private init() {}

    func isPending(_ key: String) -> Bool {
        pendingKeys.contains(key)
    }

    func submit(
        key: String,
        successNotice: MutationNotice?,
        errorNotice: @escaping @Sendable (Error) -> MutationNotice,
        optimistic: () -> Void,
        rollback: @escaping @MainActor (Error) -> Void = { _ in },
        execute: @escaping @Sendable () async throws -> Void
    ) {
        optimistic()
        enqueue(
            key: key,
            successNotice: successNotice,
            errorNotice: errorNotice,
            execute: {
                try await execute()
                return EmptyMutationResult()
            },
            applySuccess: { (_: EmptyMutationResult) in },
            applyFailure: rollback
        )
    }

    func submit<Output: Sendable>(
        key: String,
        successNotice: MutationNotice?,
        errorNotice: @escaping @Sendable (Error) -> MutationNotice,
        optimistic: () -> Void,
        rollback: @escaping @MainActor (Error) -> Void = { _ in },
        execute: @escaping @Sendable () async throws -> Output,
        applySuccess: @escaping @MainActor (Output) -> Void
    ) {
        optimistic()
        enqueue(
            key: key,
            successNotice: successNotice,
            errorNotice: errorNotice,
            execute: execute,
            applySuccess: applySuccess,
            applyFailure: rollback
        )
    }

    func dismissNotification(id: UUID) {
        notifications.removeAll { $0.id == id }
    }

    func showPreview(_ notice: MutationNotice) {
        present(notice, bypassVisibility: true)
    }

    private func enqueue<Output: Sendable>(
        key: String,
        successNotice: MutationNotice?,
        errorNotice: @escaping @Sendable (Error) -> MutationNotice,
        execute: @escaping @Sendable () async throws -> Output,
        applySuccess: @escaping @MainActor (Output) -> Void,
        applyFailure: @escaping @MainActor (Error) -> Void
    ) {
        var state = states[key] ?? MutationState()
        state.latestRevision += 1
        let revision = state.latestRevision
        state.queued = QueuedMutation(
            revision: revision,
            successNotice: successNotice,
            errorNotice: errorNotice,
            execute: { try await execute() },
            applySuccess: { result in
                guard let typed = result as? Output else { return }
                applySuccess(typed)
            },
            applyFailure: applyFailure
        )

        let shouldStartRunner = !state.isRunning
        state.isRunning = true
        states[key] = state
        pendingKeys.insert(key)

        guard shouldStartRunner else { return }
        Task { [weak self] in
            await self?.runQueue(for: key)
        }
    }

    private func runQueue(for key: String) async {
        while true {
            guard var state = states[key], let queued = state.queued else {
                pendingKeys.remove(key)
                states.removeValue(forKey: key)
                return
            }

            state.queued = nil
            states[key] = state

            do {
                let result = try await queued.execute()
                let isLatest = states[key]?.latestRevision == queued.revision
                guard isLatest else { continue }
                queued.applySuccess(result)
                if let successNotice = queued.successNotice {
                    present(successNotice)
                }
            } catch {
                let isLatest = states[key]?.latestRevision == queued.revision
                guard isLatest else { continue }
                queued.applyFailure(error)
                present(queued.errorNotice(error))
            }

            if let currentState = states[key],
               currentState.queued == nil,
               currentState.latestRevision == queued.revision {
                pendingKeys.remove(key)
                states.removeValue(forKey: key)
                return
            }
        }
    }

    private func present(_ notice: MutationNotice, bypassVisibility: Bool = false) {
        let settings = AppSettings.shared
        guard bypassVisibility || settings.shouldDisplayNotification(accent: notice.accent) else { return }

        let item = AppNotificationItem(
            title: notice.title,
            message: notice.message,
            symbol: notice.symbol,
            accent: notice.accent,
            customColor: notice.customColor
        )

        notifications.append(item)
        if notifications.count > 8 {
            notifications.removeFirst(notifications.count - 8)
        }

        let delay = settings.notificationAutoHideDelay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.dismissNotification(id: item.id)
            }
        }
    }
}

struct MutationNotificationOverlay: View {
    @ObservedObject private var mutationCenter = AppMutationCenter.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: stackAlignment, spacing: 12) {
            ForEach(mutationCenter.notifications) { item in
                NotificationToast(item: item)
                    .transition(transition)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: settings.notificationStackAlignment)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: mutationCenter.notifications)
    }

    private var stackAlignment: HorizontalAlignment {
        switch settings.notificationPlacement {
        case .bottomLeft:
            return .leading
        case .bottomRight:
            return .trailing
        }
    }

    private var transition: AnyTransition {
        let edge: Edge = settings.notificationPlacement == .bottomLeft ? .leading : .trailing
        return .move(edge: edge).combined(with: .opacity).combined(with: .scale(scale: 0.96))
    }
}

private struct NotificationToast: View {
    let item: AppNotificationItem

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(iconColor.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: item.symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(iconColor)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let message = item.message, !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                Button {
                    AppMutationCenter.shared.dismissNotification(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass(.regular.interactive()))
                .buttonBorderShape(.circle)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 320, maxWidth: 420, alignment: .leading)
        .notificationGlassSurface(reduceTransparency: reduceTransparency)
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        .offset(x: dragOffset)
        .opacity(opacity)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    if abs(value.translation.width) > 90 {
                        AppMutationCenter.shared.dismissNotification(id: item.id)
                    } else {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

    private var opacity: Double {
        let fade = min(abs(dragOffset) / 180, 0.55)
        return 1 - fade
    }

    private var iconColor: Color {
        item.customColor?.color ?? item.accent.color
    }
}

private extension View {
    @ViewBuilder
    func notificationGlassSurface(reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if reduceTransparency {
            self
                .background(
                    shape
                        .fill(AppSettings.shared.elevatedBackgroundColor.opacity(0.97))
                        .overlay(
                            shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )
        } else {
            self.glassEffect(.regular, in: shape)
        }
    }
}
