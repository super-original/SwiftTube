import SwiftUI
import WebKit

struct YouTubeWebLoginSheet: View {
    @EnvironmentObject private var authSession: AuthSessionModel
    @Environment(\.dismiss) private var dismiss

    let onConnected: () -> Void

    @State private var latestCookies: [WebSessionCookie] = []
    @State private var hasReachedYouTube = false
    @State private var isCompleting = false
    @State private var lastAttemptSignature: Int?
    @State private var completionError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sign in to YouTube")
                        .font(.headline)
                    Text("This secure session belongs only to SwiftTube.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isCompleting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Cancel") {
                    dismiss()
                }
                .disabled(isCompleting)
            }
            .padding(16)

            Divider()

            YouTubeLoginWebView { snapshot in
                latestCookies = snapshot.cookies
                hasReachedYouTube = hasReachedYouTube || snapshot.hasReachedYouTube
                completeSignInIfPossible()
            }

            if let completionError, completionError.isEmpty == false {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(completionError)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try Again") {
                        lastAttemptSignature = nil
                        completeSignInIfPossible()
                    }
                    .disabled(isCompleting || hasAuthenticationCookie == false || hasReachedYouTube == false)
                }
                .padding(14)
            }
        }
        .frame(width: 720, height: 720)
        .interactiveDismissDisabled(isCompleting)
    }

    private var authenticationCookieSignature: Int? {
        let values = latestCookies
            .filter { cookie in
                Self.authenticationCookieNames.contains(cookie.name)
                    && Self.isYouTubeOrGoogleDomain(cookie.domain)
            }
            .map { "\($0.name)=\($0.value)" }
            .sorted()
        guard values.isEmpty == false else { return nil }
        return values.joined(separator: ";").hashValue ^ latestCookies.count
    }

    private var hasAuthenticationCookie: Bool {
        authenticationCookieSignature != nil
    }

    private func completeSignInIfPossible() {
        guard hasReachedYouTube else { return }
        guard let signature = authenticationCookieSignature else { return }
        guard signature != lastAttemptSignature, isCompleting == false else { return }

        lastAttemptSignature = signature
        completionError = nil
        isCompleting = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            let connected = await authSession.connect(webCookies: latestCookies)
            isCompleting = false
            if connected {
                onConnected()
                dismiss()
            } else {
                completionError = authSession.errorMessage ?? "YouTube did not accept this sign-in session."
            }
        }
    }

    private static let authenticationCookieNames = Set([
        "SAPISID",
        "__Secure-3PAPISID",
        "__Secure-1PAPISID",
        "APISID",
    ])

    private static func isYouTubeOrGoogleDomain(_ domain: String) -> Bool {
        let domain = domain.lowercased()
        return domain.contains("youtube.com") || domain.contains("google.com")
    }
}

private struct YouTubeWebLoginSnapshot {
    let cookies: [WebSessionCookie]
    let hasReachedYouTube: Bool
}

private struct YouTubeLoginWebView: NSViewRepresentable {
    let onCookiesChanged: @MainActor (YouTubeWebLoginSnapshot) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesChanged: onCookiesChanged)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.userAgent
        context.coordinator.observe(configuration.websiteDataStore.httpCookieStore, in: webView)

        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        nsView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private let onCookiesChanged: @MainActor (YouTubeWebLoginSnapshot) -> Void
        private weak var cookieStore: WKHTTPCookieStore?
        private weak var webView: WKWebView?

        init(onCookiesChanged: @escaping @MainActor (YouTubeWebLoginSnapshot) -> Void) {
            self.onCookiesChanged = onCookiesChanged
        }

        func observe(_ cookieStore: WKHTTPCookieStore, in webView: WKWebView) {
            self.cookieStore = cookieStore
            self.webView = webView
            cookieStore.add(self)
            publishCookies(from: cookieStore)
        }

        func stopObserving() {
            cookieStore?.remove(self)
            cookieStore = nil
            webView = nil
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor [weak self] in
                self?.publishCookies(from: cookieStore)
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            publishCookies(from: webView.configuration.websiteDataStore.httpCookieStore)
        }

        private func publishCookies(from cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                let sessionCookies = cookies.map {
                    WebSessionCookie(
                        domain: $0.domain,
                        path: $0.path,
                        isSecure: $0.isSecure,
                        expiresAt: $0.expiresDate,
                        name: $0.name,
                        value: $0.value
                    )
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let host = self.webView?.url?.host?.lowercased() ?? ""
                    self.onCookiesChanged(
                        YouTubeWebLoginSnapshot(
                            cookies: sessionCookies,
                            hasReachedYouTube: host == "youtube.com" || host.hasSuffix(".youtube.com")
                        )
                    )
                }
            }
        }
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let loginURL = URL(
        string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps%253A%252F%252Fwww.youtube.com%252F"
    )!
}
