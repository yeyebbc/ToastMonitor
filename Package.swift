// swift-tools-version:5.10
import PackageDescription

#if os(Windows)
import Foundation

// Share upstream sources in place. Keep Windows presentation and native
// integrations outside the macOS target, and preserve its module/test imports.
let sharedSources = [
    "Core/AnalysisCSVRow.swift", "Core/BalanceRunway.swift",
    "Core/ClaudeNonLocalEstimator.swift", "Core/DataMaintenance.swift",
    "Core/CodexBillingModeCoordinator.swift",
    "Core/Database.swift", "Core/DebugLog.swift", "Core/EventIdentity.swift",
    "Core/FilePlatform.swift", "Core/Format.swift", "Core/ModelName.swift",
    "Core/Performance.swift", "Core/Pricing.swift", "Core/QuotaWindow.swift",
    "Core/RuntimePolicy.swift", "Core/SubscriptionMath.swift", "Core/Tool.swift",
    "Core/UsagePeriod.swift",
    "Collect/CLIRenewal.swift", "Collect/ClaudeCLIRefresher.swift",
    "Collect/ClaudeCodeParser.swift", "Collect/ClaudeQuotaClient.swift",
    "Collect/CodexParser.swift", "Collect/CodexQuotaClient.swift",
    "Collect/CollectorEngine.swift", "Collect/CommandCodePlanCatalog.swift",
    "Collect/CommandCodeQuotaClient.swift", "Collect/DSHParser.swift",
    "Collect/DeepSeekBilling.swift", "Collect/DeepSeekBillingClient.swift",
    "Collect/DeepSeekBrowserSession.swift", "Collect/FileScanner.swift",
    "Collect/GrokCLIRefresher.swift", "Collect/GrokQuotaClient.swift",
    "Collect/HermesParser.swift", "Collect/HermesRemoteClient.swift",
    "Collect/KeychainStore.swift", "Collect/NoRedirectDelegate.swift",
    "Collect/OmpParser.swift", "Collect/OpenCodeGoClient.swift",
    "Collect/OpenCodeParser.swift", "Collect/OpenRouterClient.swift",
    "Collect/ParserStateStore.swift", "Collect/PerfCollector.swift",
    "Collect/QuotaPolling.swift", "Collect/Zstd.swift",
    "App/QuotaAlertManager.swift", "App/SourceHealthHub.swift",
    "App/UsageQueryService.swift", "UI/AccountConnection.swift",
].map { "Sources/ToastMonitor/" + $0 }

let portableTests = [
    "BalanceRunwayTests.swift", "ClaudeCodeParserTests.swift",
    "ClaudeNonLocalEstimatorTests.swift", "CodexParserTests.swift",
    "ClaudeQuotaTests.swift", "CommandCodeQuotaTests.swift",
    "CodexPlanNameTests.swift", "CollectorEngineTests.swift",
    "CostNormalizationTests.swift", "DSHParserTests.swift",
    "DatabaseExportTests.swift", "DatabaseTests.swift",
    "DeepSeekBillingTests.swift", "FileScannerTests.swift", "FormatTests.swift",
    "HermesParserTests.swift", "HermesSourceSwitchTests.swift",
    "GrokQuotaTests.swift", "NetworkBoundaryTests.swift",
    "ManagedBackupTests.swift", "ModelNameTests.swift", "OmpParserTests.swift",
    "OpenCodeInitialUsageTests.swift", "PerfCollectorTests.swift",
    "PricingTests.swift", "QuotaWindowTests.swift", "RefreshBackoffTests.swift",
    "QuotaAlertTests.swift", "ReviewRegressionTests.swift",
    "RestoreSafetyTests.swift", "SourceRetryTests.swift",
    "SubscriptionMathTests.swift", "TurnRollupTests.swift",
    "UsagePeriodTests.swift", "UsageQueryServiceTests.swift",
]
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let testFiles = (try? FileManager.default.contentsOfDirectory(
    atPath: packageRoot.appendingPathComponent("Tests/ToastMonitorTests").path
)) ?? []

// Explicitly exclude upstream macOS files without maintaining a second file list.
let sourceFiles = FileManager.default.enumerator(
    atPath: packageRoot.appendingPathComponent("Sources/ToastMonitor").path
)
let macOnlySources = (sourceFiles?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") }
    .map { "Sources/ToastMonitor/" + $0.replacingOccurrences(of: "\\", with: "/") }
    .filter { !sharedSources.contains($0) }
let package = Package(
    name: "ToastMonitor",
    products: [.library(name: "ToastMonitorRuntime", type: .dynamic, targets: ["ToastMonitor"])],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.10.0"),
        .package(url: "https://github.com/moreSwift/swift-winui", exact: "0.2.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.13.0"),
    ],
    targets: [
        .systemLibrary(name: "SQLite3", path: "Windows/SQLite3"),
        .target(
            name: "TaskbarHost", path: "Windows/TaskbarHost",
            publicHeadersPath: "include",
            cSettings: [.define("UNICODE"), .define("_UNICODE"),
                        .define("_WIN32_WINNT", to: "0x0A00")],
            linkerSettings: [
                .linkedLibrary("user32"), .linkedLibrary("gdi32"),
                .linkedLibrary("comctl32"), .linkedLibrary("advapi32"),
                .linkedLibrary("ole32"), .linkedLibrary("oleaut32"),
                .linkedLibrary("uuid"),
            ]
        ),
        .target(
            name: "StorageSupport", path: "Windows/StorageSupport",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("advapi32")]
        ),
        .target(
            name: "WindowsServicesNative", path: "Windows/ServicesNative",
            publicHeadersPath: "include",
            cSettings: [.define("UNICODE"), .define("_UNICODE"),
                        .define("_WIN32_WINNT", to: "0x0A00")],
            linkerSettings: [
                .linkedLibrary("advapi32"), .linkedLibrary("user32"),
                .linkedLibrary("powrprof"), .linkedLibrary("shell32"),
                .linkedLibrary("kernel32"),
            ]
        ),
        .target(
            name: "ToastMonitor",
            dependencies: [
                "SQLite3", "TaskbarHost", "StorageSupport", "WindowsServicesNative",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "WinUIBackend", package: "swift-cross-ui"),
                .product(name: "WinUI", package: "swift-winui"),
                .product(name: "WinAppSDK", package: "swift-winui"),
                .product(name: "UWP", package: "swift-winui"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: ".",
            exclude: [
                "Tests", "docs", "scripts", "artifacts", ".github",
                "Windows/Scripts", "Windows/SQLite3", "Windows/TaskbarHost",
                "Windows/StorageSupport", "Windows/ServicesNative", "Windows/Patches",
                "Windows/Launcher",
                "README.md", "PRODUCT.md", "CONTRIBUTING.md", "SECURITY.md",
                "CODE_OF_CONDUCT.md", "LICENSE", "appcast.json",
            ] + macOnlySources,
            sources: sharedSources + ["Windows/Sources"],
            // The native launcher calls this C entry point; tests keep their own main.
            swiftSettings: [.unsafeFlags([
                "-Xfrontend", "-entry-point-function-name", "-Xfrontend", "ToastMonitor_main",
            ])],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "/export:ToastMonitor_main",
            ])]
        ),
        .testTarget(
            name: "ToastMonitorTests", dependencies: ["ToastMonitor", "SQLite3"],
            path: "Tests/ToastMonitorTests",
            exclude: testFiles.filter { $0.hasSuffix(".swift") && !portableTests.contains($0) },
            sources: portableTests,
            resources: [.copy("Fixtures")]
        ),
    ]
)
#else

// SwiftPM has no application marketing-version field. Release versions are
// injected by scripts/build-app.sh from vMAJOR.MINOR[.PATCH] tags; untagged
// builds use the explicit development version 1.0.
let package = Package(
    name: "ToastMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ToastMonitor",
            path: "Sources/ToastMonitor",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "ToastMonitorTests",
            dependencies: ["ToastMonitor"],
            path: "Tests/ToastMonitorTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
#endif
