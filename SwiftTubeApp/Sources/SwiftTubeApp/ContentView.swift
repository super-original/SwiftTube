import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var searchViewModel = SearchViewModel()
    @EnvironmentObject private var backend: BackendManager
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var authSession: AuthSessionModel

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)
    ]

    var body: some View {
        ZStack {
            backgroundView
            currentScreen
        }
        .overlay(backendOverlay)
        .sheet(isPresented: $authSession.isSheetPresented) {
            AuthConnectionSheet()
                .environmentObject(authSession)
        }
        .toolbar(id: "main") {
            ToolbarItem(id: "brand", placement: .navigation) {
                Button {
                    searchViewModel.clear()
                    if case .home = navigation.currentRoute {
                        viewModel.reload()
                    } else {
                        navigation.showHome()
                    }
                } label: {
                    BrandToolbarLabel()
                }
            }

            ToolbarSpacer(.fixed, placement: .navigation)

            ToolbarItem(id: "back", placement: .navigation) {
                Button(action: navigation.goBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!navigation.canGoBack)
            }

            ToolbarItem(id: "forward", placement: .navigation) {
                Button(action: navigation.goForward) {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!navigation.canGoForward)
            }

            ToolbarItem(id: "search", placement: .principal) {
                ToolbarSearchField(
                    text: $searchViewModel.query,
                    placeholder: "Search or paste YouTube URL",
                    onSubmit: { searchViewModel.submit(navigation: navigation) },
                    onClear: { searchViewModel.clear() }
                )
                .frame(minWidth: 300, maxWidth: 540)
            }

            ToolbarItem(id: "auth", placement: .primaryAction) {
                Button {
                    authSession.isSheetPresented = true
                } label: {
                    AuthToolbarLabel(status: authSession.status)
                }
                .disabled(!backend.isRunning)
            }

            ToolbarItem(id: "refresh", placement: .primaryAction) {
                Button(action: viewModel.reload) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!backend.isRunning)
            }

            ToolbarItem(id: "status", placement: .primaryAction) {
                BackendToolbarStatus(state: backend.state)
            }
        }
        .task(id: backend.state) {
            if backend.isRunning {
                await authSession.loadStatus()
                viewModel.reload()
            }
        }
        .task(id: authSession.contentRefreshID) {
            guard backend.isRunning else { return }
            viewModel.reload()
        }
    }
}

private extension ContentView {
    var backgroundView: some View {
        Color(NSColor.windowBackgroundColor)
            .ignoresSafeArea()
    }

    @ViewBuilder
    var currentScreen: some View {
        switch navigation.currentRoute {
        case .home:
            homeScreen
        case .video(let video):
            PlayerScreen(video: video)
                .id(video.id)
        }
    }

    var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if searchViewModel.isActive {
                    searchContentView
                } else {
                    if let notice = viewModel.notice {
                        NoticeBanner(text: notice)
                    }
                    contentView
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    var contentView: some View {
        if viewModel.videos.isEmpty {
            if viewModel.isLoading {
                placeholderGrid
            } else if let error = viewModel.errorMessage {
                EmptyStateView(
                    title: "Couldn’t load recommendations",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    viewModel.reload()
                }
            } else {
                EmptyStateView(
                    title: "No videos yet",
                    message: "The feed is empty. Try refreshing once the backend is running.",
                    actionTitle: "Refresh"
                ) {
                    viewModel.reload()
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(viewModel.videos, id: \.id) { video in
                    Button {
                        navigation.showVideo(video)
                    } label: {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        viewModel.loadMoreIfNeeded(currentVideo: video)
                    }
                }
            }

            if viewModel.isLoading {
                ProgressView("Loading more...")
                    .padding(.top, 16)
            }
        }
    }

    @ViewBuilder
    var searchContentView: some View {
        HStack {
            Text("Results for \"\(searchViewModel.lastQuery)\"")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Clear") {
                searchViewModel.clear()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }

        if searchViewModel.results.isEmpty {
            if searchViewModel.isSearching {
                placeholderGrid
            } else if let error = searchViewModel.errorMessage {
                EmptyStateView(
                    title: "Search failed",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    searchViewModel.submit(navigation: navigation)
                }
            } else {
                EmptyStateView(
                    title: "No results",
                    message: "No videos found for \"\(searchViewModel.query)\".",
                    actionTitle: "Clear Search"
                ) {
                    searchViewModel.clear()
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(searchViewModel.results, id: \.id) { video in
                    Button {
                        navigation.showVideo(video)
                    } label: {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        searchViewModel.loadMoreIfNeeded(currentVideo: video)
                    }
                }
            }

            if searchViewModel.isSearching {
                ProgressView("Loading more...")
                    .padding(.top, 16)
            }
        }
    }

    var placeholderGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(0..<8, id: \.self) { _ in
                PlaceholderCard()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    var backendOverlay: some View {
        switch backend.state {
        case .idle, .preparing, .installing, .starting:
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text(backend.statusMessage)
                        .font(.headline)
                    if let logLine = backend.lastLogLine {
                        Text(logLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(radius: 12)
                )
            }
        case .failed(let message):
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("Backend Error")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    if let logLine = backend.lastLogLine {
                        Text(logLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Button("Retry") {
                        backend.retry()
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(radius: 12)
                )
            }
        case .running:
            EmptyView()
        }
    }
}

private struct BrandToolbarLabel: View {
    var body: some View {
        HStack(spacing: 8) {
            if let logo = BrandAssets.logo {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 20)
            }

            Text("SwiftTube")
                .font(.headline)
        }
    }
}

private struct BackendToolbarStatus: View {
    let state: BackendState

    private var label: String {
        switch state {
        case .running:
            return "Online"
        case .failed:
            return "Error"
        case .installing:
            return "Installing"
        case .starting:
            return "Starting"
        case .preparing:
            return "Preparing"
        case .idle:
            return "Idle"
        }
    }

    private var color: Color {
        switch state {
        case .running:
            return Color.green
        case .failed:
            return Color.red
        default:
            return Color.orange
        }
    }

    var body: some View {
        Label(label, systemImage: "circle.fill")
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(color, .secondary)
    }
}

private struct AuthToolbarLabel: View {
    let status: AuthStatusResponse

    var body: some View {
        Label {
            Text(status.authenticated ? (status.browserLabel ?? "YouTube") : "Connect YouTube")
        } icon: {
            Image(systemName: status.authenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
        }
        .font(.caption)
    }
}

private struct AuthConnectionSheet: View {
    @EnvironmentObject private var authSession: AuthSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect Your YouTube Session")
                    .font(.title2.weight(.bold))
                Text("SwiftTube uses the browser session you already have on this Mac. Your Google password never goes through the app.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(BrowserLoginOption.allCases) { browser in
                    Button {
                        Task {
                            let connected = await authSession.connect(using: browser)
                            if connected {
                                dismiss()
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(browser.title)
                                .font(.headline)
                            Text(browser.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(authSession.isWorking)
                }
            }

            if authSession.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting your YouTube session...")
                        .foregroundStyle(.secondary)
                }
            }

            if authSession.status.authenticated {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Connected via \(authSession.status.browserLabel ?? "your browser")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let message = authSession.status.message {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(NSColor.controlBackgroundColor))
                )

                Button("Disconnect") {
                    Task {
                        await authSession.disconnect()
                    }
                }
                .disabled(authSession.isWorking)
            }

            if let errorMessage = authSession.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            Text("If the import fails, make sure you are signed into YouTube in that browser and then try again.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle) {
                action()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct NoticeBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onClear: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = ResignableSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.focusRingType = .default
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// NSSearchField subclass that resigns first responder when
    /// clicking outside, matching native macOS search bar behaviour.
    final class ResignableSearchField: NSSearchField {
        private nonisolated(unsafe) var clickMonitor: Any?

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { installClickOutsideMonitor() }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            removeClickOutsideMonitor()
            return result
        }

        private func installClickOutsideMonitor() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let fieldEditor = self.currentEditor() else { return event }
                let locationInField = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(locationInField) {
                    // Also check the field editor (which might be slightly different)
                    let locationInEditor = fieldEditor.convert(event.locationInWindow, from: nil)
                    if !fieldEditor.bounds.contains(locationInEditor) {
                        self.window?.makeFirstResponder(nil)
                    }
                }
                return event
            }
        }

        private func removeClickOutsideMonitor() {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }

        deinit {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
            if field.stringValue.isEmpty {
                parent.onClear()
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if control.stringValue.isEmpty {
                    // Empty field: just deselect
                    control.window?.makeFirstResponder(nil)
                } else {
                    // Has text: clear it and the search results
                    parent.text = ""
                    (control as? NSSearchField)?.stringValue = ""
                    parent.onClear()
                }
                return true
            }
            return false
        }
    }
}

private struct PlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(16 / 9, contentMode: .fit)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
                .frame(height: 16)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
                .frame(height: 12)
                .padding(.trailing, 80)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .redacted(reason: .placeholder)
    }
}
