import Foundation
import SwiftCrossUI

private struct WindowsBuildMetadata: Decodable {
    let version: String
    let commit: String?
    let builtAtUtc: String
    let isDevelopment: Bool
    static let current: Self? = {
        guard let executable = CommandLine.arguments.first else { return nil }
        let url = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("ToastMonitor-buildinfo.json")
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }()
}

struct WindowsBuildInformation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let metadata = WindowsBuildMetadata.current {
                WindowsValueRow(label: "Current version", value: metadata.version + (metadata.isDevelopment ? " · Development" : ""))
                WindowsValueRow(label: "Built", value: metadata.builtAtUtc)
                if let commit = metadata.commit { Text("Source base: \(commit)").font(.caption).textSelectionEnabled() }
                Text("The source base identifies the checkout commit, not any local modifications included in this build.").font(.caption)
            } else { Text("Build information is unavailable for this executable.").font(.caption) }
            Text("Windows updates are manual downloads. No automatic update check has been performed.").font(.caption)
        }
    }
}
