import Foundation

enum AppConfig {
    static var backendBaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["SWIFTTUBE_BACKEND"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://127.0.0.1:4891")!
    }
}
