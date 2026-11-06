import Foundation
import WindowsServicesNative

/// Generic Windows credentials are protected by the signed-in user's Credential Manager.
/// A failed read/write never falls back to a settings file or a plaintext cache.
enum KeychainStore {
    enum ReadResult {
        case value(String)
        case missing
        case failure(status: UInt32)
    }

    static let service = "ToastMonitor"
    private static let invalidDataStatus: UInt32 = 13 // ERROR_INVALID_DATA
    private static let lock = NSLock()
    private static var status: UInt32 = 0
    static var lastSecStatus: UInt32 {
        lock.lock(); defer { lock.unlock() }; return status
    }
    static var lastWasInteractionNotAllowed: Bool {
        let result = lastSecStatus
        return result != 0 && result != 1168 // ERROR_NOT_FOUND
    }
    private static func record(_ result: UInt32) {
        lock.lock(); status = result; lock.unlock()
    }
    static func readResult(account: String) -> ReadResult {
        var pointer: UnsafeMutablePointer<UInt8>?
        var count: UInt32 = 0
        var missing: Int32 = 0
        let result = Array(account.utf16) + [0]
        let code = result.withUnsafeBufferPointer { tm_credential_read($0.baseAddress, &pointer, &count, &missing) }
        record(code)
        guard code == 0, let pointer else {
            return missing != 0 ? .missing : .failure(status: code)
        }
        let bytes = Data(
            bytesNoCopy: UnsafeMutableRawPointer(pointer),
            count: Int(count),
            deallocator: .custom { address, size in
                tm_credential_free(address.assumingMemoryBound(to: UInt8.self), UInt32(size))
            }
        )
        guard let value = String(data: bytes, encoding: .utf8) else {
            return .failure(status: Self.invalidDataStatus)
        }
        return .value(value)
    }
    static func get(account: String, allowPrompt: Bool = false) -> String? {
        guard case .value(let value) = readResult(account: account) else { return nil }
        return value
    }
    static func set(_ value: String, account: String, allowPrompt: Bool = false) -> Bool {
        var bytes = Array(value.utf8)
        defer { bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let target = Array(account.utf16) + [0]
        let code = target.withUnsafeBufferPointer { target in
            bytes.withUnsafeBufferPointer { tm_credential_write(target.baseAddress, $0.baseAddress, UInt32($0.count)) }
        }
        record(code)
        return code == 0
    }
    @discardableResult
    static func delete(account: String, allowPrompt: Bool = false) -> Bool {
        let target = Array(account.utf16) + [0]
        let code = target.withUnsafeBufferPointer { tm_credential_delete($0.baseAddress) }
        record(code)
        return code == 0 || code == 1168
    }
}
