import Foundation
import WinSDK
import _FoundationICU

/// Initializes Foundation from the stable Windows timezone ID, not its localized display name.
enum WindowsTimeZone {
    static func initialize() throws {
        let environment = ProcessInfo.processInfo.environment
        // Preserve explicit process timezone overrides supported by Foundation.
        if environment["TZ"] != nil || environment["TZFILE"] != nil { return }
        var information = DYNAMIC_TIME_ZONE_INFORMATION()
        guard GetDynamicTimeZoneInformation(&information) != DWORD(TIME_ZONE_ID_INVALID) else {
            throw windowsError("Windows could not read the system timezone.")
        }
        let identifier = withUnsafeBytes(of: &information.TimeZoneKeyName) {
            String(decoding: $0.bindMemory(to: UInt16.self).prefix(while: { $0 != 0 }), as: UTF16.self)
        }
        try useWindowsTimeZone(identifier)
    }

    static func useWindowsTimeZone(_ identifier: String) throws {
        let input = Array(identifier.utf16)
        var output = [UInt16](repeating: 0, count: 128)
        var status = U_ZERO_ERROR
        let length = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                ucal_getTimeZoneIDForWindowsID(inputBuffer.baseAddress, Int32(inputBuffer.count), nil,
                    outputBuffer.baseAddress, Int32(outputBuffer.count), &status)
            }
        }
        guard status.rawValue <= 0, length > 0, length < Int32(output.count) else {
            throw NSError(domain: "ToastMonitor.WindowsTimeZone", code: Int(status.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "The system timezone could not be mapped: \(identifier)."
            ])
        }
        let mapped = String(decoding: output.prefix(Int(length)), as: UTF16.self)
        guard let expected = TimeZone(identifier: mapped) else {
            throw NSError(domain: "ToastMonitor.WindowsTimeZone", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Foundation does not support the system timezone: \(mapped)."
            ])
        }

        // Swift 6.1 Foundation maps the localized Windows StandardName, which can fall back to GMT.
        // Prime its public caches through an OS-only TZ override. Do not change the CRT environment:
        // SQLite uses UCRT localtime, whose TZ syntax differs, and children must inherit the original TZ.
        let previous = ProcessInfo.processInfo.environment["TZ"]
        let name = Array("TZ".utf16) + [0]
        guard SetEnvironmentVariableW(name, Array(mapped.utf16) + [0]) else {
            throw windowsError("Windows could not initialize the process timezone.")
        }
        NSTimeZone.resetSystemTimeZone()
        let current = TimeZone.current
        let calendarZone = Calendar.current.timeZone
        _ = NSTimeZone.default
        _ = Calendar.autoupdatingCurrent.timeZone
        let restored: Bool
        if let previous {
            restored = SetEnvironmentVariableW(name, Array(previous.utf16) + [0])
        } else {
            restored = SetEnvironmentVariableW(name, nil)
        }
        guard restored else { throw windowsError("Windows could not restore the process timezone environment.") }
        // A second reset here would discard the corrected caches after restoring the environment.
        guard current == expected, calendarZone == expected else {
            throw NSError(domain: "ToastMonitor.WindowsTimeZone", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Foundation could not initialize the system timezone: \(mapped)."
            ])
        }
    }

    private static func windowsError(_ message: String) -> NSError {
        NSError(domain: "Win32", code: Int(GetLastError()), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
