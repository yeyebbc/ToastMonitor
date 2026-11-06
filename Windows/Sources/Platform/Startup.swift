import Foundation
import WinSDK
import WindowsServicesNative

enum WindowsStartup {
    private static var executable: String? { Bundle.main.executableURL?.path }

    static var isEnabled: Bool {
        guard let executable else { return false }
        return executable.withCString(encodedAs: UTF16.self) { tm_startup_enabled($0) != 0 }
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard let executable else { throw CocoaError(.fileNoSuchFile) }
        let result = executable.withCString(encodedAs: UTF16.self) {
            tm_startup_set($0, enabled ? 1 : 0)
        }
        guard result != 0 else {
            throw NSError(domain: "Win32", code: Int(GetLastError()), userInfo: [
                NSLocalizedDescriptionKey: "Windows could not update the startup registration."
            ])
        }
    }
}
