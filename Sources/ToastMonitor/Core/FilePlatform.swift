import Foundation
#if os(Windows)
import StorageSupport
#else
import Darwin
#endif

/// Only filesystem mechanics differ; parsers, SQL and accounting stay shared.
enum FilePlatform {
    static var applicationSupport: URL {
        #if os(Windows)
        if let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !local.isEmpty {
            return URL(fileURLWithPath: local, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif
    }
    static func comparisonPath(_ path: String) -> String {
        #if os(Windows)
        return path.replacingOccurrences(of: "\\", with: "/").lowercased()
        #else
        return path
        #endif
    }


    static func fileStat(_ path: String) -> FileScanner.Stat? {
        #if os(Windows)
        var size: Int64 = 0, mtime: Int64 = 0, identity: Int64 = 0
        guard path.withCString(encodedAs: UTF16.self, { tm_file_info($0, &size, &mtime, &identity) }) != 0 else { return nil }
        return FileScanner.Stat(size: size, mtime: mtime, identity: identity)
        #else
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return FileScanner.Stat(size: st.st_size, mtime: mtime, identity: Int64(st.st_ino))
        #endif
    }

    static func sameFile(_ left: String, _ right: String) -> Bool {
        #if os(Windows)
        return left.withCString(encodedAs: UTF16.self) { a in
            right.withCString(encodedAs: UTF16.self) { b in tm_same_file(a, b) != 0 }
        }
        #else
        var a = stat(), b = stat()
        return stat(left, &a) == 0 && stat(right, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
        #endif
    }

    static func createPrivateDirectory(_ url: URL) throws {
        #if os(Windows)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path && !FileManager.default.fileExists(atPath: parent.path) {
            try createPrivateDirectory(parent)
        }
        guard url.path.withCString(encodedAs: UTF16.self, { tm_create_private_directory($0) }) != 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #endif
    }

    static func protect(_ path: String, directory: Bool = false) throws {
        #if os(Windows)
        guard path.withCString(encodedAs: UTF16.self, { tm_protect_path($0, directory ? 1 : 0) }) != 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        #else
        try FileManager.default.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: path)
        #endif
    }

    static func reservePrivateFile(_ path: String) -> Bool {
        #if os(Windows)
        return path.withCString(encodedAs: UTF16.self, { tm_reserve_private_file($0) }) != 0
        #else
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        return Darwin.close(descriptor) == 0
        #endif
    }

    static func replace(_ source: String, _ destination: String) -> Bool {
        #if os(Windows)
        return source.withCString(encodedAs: UTF16.self) { a in
            destination.withCString(encodedAs: UTF16.self) { b in tm_replace_file(a, b) != 0 }
        }
        #else
        return Darwin.rename(source, destination) == 0
        #endif
    }
}
