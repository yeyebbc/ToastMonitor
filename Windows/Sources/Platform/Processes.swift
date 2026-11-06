import Foundation
import WindowsServicesNative

enum WindowsCLI {
    static func locate(named name: String, env: [String: String], home: String,
                       fixedCandidates: [String]?) -> String? {
        guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).inverted) == nil else { return nil }
        let path = env.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        let appData = env.first { $0.key.caseInsensitiveCompare("APPDATA") == .orderedSame }?.value
        var roots = ["\(home)/.local/bin", "\(home)/.\(name)/bin"]
        if let appData { roots.append("\(appData)/npm") }
        roots += path.split(separator: ";").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let fixed = fixedCandidates ?? []
        let candidates = fixed + roots.filter { !$0.isEmpty }.flatMap { root in
            ["exe", "cmd"].map { URL(fileURLWithPath: root).appendingPathComponent("\(name).\($0)").path }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Windows CRT quoting. No cmd.exe/PowerShell parsing is involved, and caller arguments never contain credentials.
    private static func quote(_ value: String) -> String {
        var result = "\""
        var slashes = 0
        for character in value {
            if character == "\\" { slashes += 1; continue }
            if character == "\"" {
                result += String(repeating: "\\", count: slashes * 2 + 1) + "\""
            } else {
                result += String(repeating: "\\", count: slashes) + String(character)
            }
            slashes = 0
        }
        return result + String(repeating: "\\", count: slashes * 2) + "\""
    }

    private static func invocation(binary: String, arguments: [String]) -> (String, [String])? {
        guard !binary.contains("\0"), !arguments.contains(where: { $0.contains("\0") }) else { return nil }
        if URL(fileURLWithPath: binary).pathExtension.lowercased() == "exe" { return (binary, arguments) }
        // npm's generated .cmd launcher is data, never executed as shell code. Resolve only a
        // quoted, local node entrypoint; refuse arbitrary batch launchers and shell expansion.
        guard URL(fileURLWithPath: binary).pathExtension.lowercased() == "cmd",
              let data = try? Data(contentsOf: URL(fileURLWithPath: binary)), data.count <= 32_768,
              let shim = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""%dp0%[\\/]([^"\r\n]+)""#, options: .caseInsensitive) else { return nil }
        let directory = URL(fileURLWithPath: binary).deletingLastPathComponent()
        let matches = regex.matches(in: shim, range: NSRange(shim.startIndex..., in: shim))
        let script = matches.compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: shim) else { return nil }
            let relative = String(shim[range]).replacingOccurrences(of: "\\", with: "/")
            guard relative.hasPrefix("node_modules/"), !relative.contains("%"), !relative.contains("..") else { return nil }
            let url = directory.appendingPathComponent(relative)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: 32)) ?? Data()
            guard ["js", "mjs", "cjs"].contains(url.pathExtension.lowercased()) ||
                    prefix.starts(with: Array("#!/usr/bin/env node".utf8)) else { return nil }
            return url
        }.first
        guard let script else { return nil }
        let adjacentNode = directory.appendingPathComponent("node.exe").path
        let node = FileManager.default.fileExists(atPath: adjacentNode) ? adjacentNode : locate(named: "node", env: ProcessInfo.processInfo.environment, home: NSHomeDirectory(), fixedCandidates: nil)
        guard let node, URL(fileURLWithPath: node).pathExtension.lowercased() == "exe" else { return nil }
        return (node, [script.path] + arguments)
    }

    private static func start(binary: String, arguments: [String], terminal: Bool) -> OpaquePointer? {
        guard let (executable, args) = invocation(binary: binary, arguments: arguments) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("toastmonitor-cli-probe", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Suppress Claude's deep-link registration prompt only in this isolated probe directory.
            if terminal {
                let settingsDirectory = directory.appendingPathComponent(".claude", isDirectory: true)
                try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
                try Data("{\"disableDeepLinkRegistration\":\"disable\"}\n".utf8)
                    .write(to: settingsDirectory.appendingPathComponent("settings.local.json"), options: .atomic)
            }
        } catch { return nil }
        let path = Array(executable.utf16) + [0]
        var command = Array(([executable] + args).map(quote).joined(separator: " ").utf16) + [0]
        let cwd = Array(directory.path.utf16) + [0]
        return path.withUnsafeBufferPointer { path in
            command.withUnsafeMutableBufferPointer { command in
                cwd.withUnsafeBufferPointer { cwd in
                    tm_cli_start(path.baseAddress, command.baseAddress, cwd.baseAddress, terminal ? 1 : 0)
                }
            }
        }
    }

    static func run(binary: String, arguments: [String], timeout: TimeInterval) -> CLIRenewalOutcome {
        guard let child = start(binary: binary, arguments: arguments, terminal: false) else {
            return .failed("native CLI launch failed; install a Windows executable or a standard npm/node launcher")
        }
        defer { tm_cli_destroy(child) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var exit: UInt32 = 0
            if tm_cli_exited(child, &exit) != 0 { return exit == 0 ? .completed : .failed("exit \(exit)") }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return .failed("timed out after \(Int(timeout))s")
    }

    static func refreshClaude(binary: String, arguments: [String], renewed: (@Sendable () -> Bool)?) -> CLIRenewalOutcome {
        guard let child = start(binary: binary, arguments: arguments, terminal: true) else {
            return .failed("native Claude terminal launch failed; install Windows Claude Code and sign in")
        }
        defer { tm_cli_destroy(child) }
        let began = Date()
        let deadline = began.addingTimeInterval(25)
        var output = [UInt8]()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var sentStatus = false
        var nudged = false
        var nextCredentialCheck = began.addingTimeInterval(3)
        func send(_ text: String) {
            let data = Array(text.utf8)
            _ = data.withUnsafeBufferPointer { tm_cli_write(child, $0.baseAddress, UInt32($0.count)) }
        }
        while Date() < deadline {
            if Date() >= nextCredentialCheck {
                if renewed?() == true { send("/exit\r"); return .completed }
                nextCredentialCheck = Date().addingTimeInterval(3)
            }
            let count = bytes.withUnsafeMutableBufferPointer { tm_cli_read(child, $0.baseAddress, UInt32($0.count)) }
            if count > 0 {
                output.append(contentsOf: bytes.prefix(Int(count)))
                if output.count > 20_000 { output.removeFirst(output.count - 20_000) }
                let scan = ClaudeCLIRefresher.compact(output)
                if ClaudeCLIRefresher.dismissPromptTokens.contains(where: scan.contains) {
                    send("\r"); output.removeAll(keepingCapacity: true)
                }
                if sentStatus, ClaudeCLIRefresher.statusReadyTokens.contains(where: scan.contains) {
                    Thread.sleep(forTimeInterval: 1.5)
                    send("/exit\r")
                    Thread.sleep(forTimeInterval: 0.3)
                    return .completed
                }
            }
            if !sentStatus, Date().timeIntervalSince(began) >= 5 {
                send("/status\r"); sentStatus = true; output.removeAll(keepingCapacity: true)
            }
            if sentStatus, !nudged, Date().timeIntervalSince(began) >= 5.8 { send("\r"); nudged = true }
            var exit: UInt32 = 0
            if tm_cli_exited(child, &exit) != 0 { return .failed("exited before account status (\(exit))") }
            Thread.sleep(forTimeInterval: 0.08)
        }
        send("/exit\r")
        return .failed("no account info within 25s; open Claude Code to refresh your login")
    }
}
