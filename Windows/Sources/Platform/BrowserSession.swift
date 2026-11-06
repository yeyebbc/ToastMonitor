import Foundation
import WindowsServicesNative

enum WindowsExternalBrowser {
    enum Failure: Error, LocalizedError {
        case invalidURL, launchFailed
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Only HTTP and HTTPS browser links are supported."
            case .launchFailed: return "Windows could not open the default browser. Check your default browser settings."
            }
        }
    }
    static func open(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { throw Failure.invalidURL }
        let text = Array(url.absoluteString.utf16) + [0]
        guard text.withUnsafeBufferPointer({ tm_open_url($0.baseAddress) }) != 0 else { throw Failure.launchFailed }
    }
}

enum DeepSeekBrowserSession {
    enum Browser: String, CaseIterable, Identifiable, Sendable {
        case system = "Default browser"
        var id: String { rawValue }
    }
    enum Failure: Error, LocalizedError {
        case manualConnectionRequired
        var errorDescription: String? {
            "Automatic browser-session import is not supported on Windows. Sign in at platform.deepseek.com, then paste your own Platform Session credential in Settings. The credential is stored in Windows Credential Manager."
        }
    }
    @MainActor static func open(_ browser: Browser) async throws {
        try WindowsExternalBrowser.open(URL(string: DeepSeekBilling.platformOrigin)!)
    }
    static func read(_ browser: Browser) async throws -> DeepSeekBilling.Credential {
        throw Failure.manualConnectionRequired
    }
}
