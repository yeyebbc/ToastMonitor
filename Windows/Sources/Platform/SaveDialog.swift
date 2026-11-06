import Foundation
import WinSDK
import WinUI

/// The stock backend ignores file types, and the UWP broker does not present on
/// an isolated desktop. The system Common Item Dialog stays in-process and binds
/// directly to the requesting window; no backend or native C bridge is needed.
@MainActor
enum WindowsSaveDialog {
    private static var active = false

    static func exportModels() {
        choose(owner: "dashboard", filename: "ToastMonitor-models.csv", extension: "csv", description: "CSV model analysis") { WindowsModel.shared.exportAnalysis(to: $0.path) }
    }
    static func exportDatabase() {
        choose(owner: "settings", filename: "ToastMonitor-export.db", extension: "db", description: "SQLite database") { WindowsModel.shared.exportDatabase(to: $0.path) }
    }
    private static func choose(owner: String, filename: String, extension suffix: String, description: String, save: (URL) -> Void) {
        guard !active else { return }
        guard let hwnd = WindowsWindowController.shared.window(for: owner)?.getHWND() else {
            WindowsModel.shared.message = "Export dialog could not open because its window is unavailable."
            return
        }
        active = true
        defer { active = false }
        do {
            var classID = GUID(Data1: 0xC0B4_E2F3, Data2: 0xBA21, Data3: 0x4773, Data4: (0x8D, 0xBA, 0x33, 0x5E, 0xC9, 0x46, 0xEB, 0x8B))
            var interfaceID = GUID(Data1: 0x84BC_CD23, Data2: 0x5FDE, Data3: 0x4CDB, Data4: (0xAE, 0xA4, 0xAF, 0x64, 0xB8, 0x3D, 0x78, 0xAB))
            var raw: UnsafeMutableRawPointer?
            try check(CoCreateInstance(&classID, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &interfaceID, &raw))
            guard let raw else { throw DialogError(code: HRESULT(bitPattern: 0x8000_4003)) }
            let dialog = raw.assumingMemoryBound(to: IFileSaveDialog.self)
            defer { _ = dialog.pointee.lpVtbl.pointee.Release(dialog) }
            var options: FILEOPENDIALOGOPTIONS = 0
            try check(dialog.pointee.lpVtbl.pointee.GetOptions(dialog, &options))
            try check(dialog.pointee.lpVtbl.pointee.SetOptions(dialog, options | UInt32(FOS_FORCEFILESYSTEM.rawValue) | UInt32(FOS_PATHMUSTEXIST.rawValue) | UInt32(FOS_OVERWRITEPROMPT.rawValue) | UInt32(FOS_NOCHANGEDIR.rawValue)))
            try wide(description) { title in
                try wide("*." + suffix) { pattern in
                    var filter = COMDLG_FILTERSPEC(pszName: title, pszSpec: pattern)
                    try check(dialog.pointee.lpVtbl.pointee.SetFileTypes(dialog, 1, &filter))
                }
            }
            try wide(filename) { try check(dialog.pointee.lpVtbl.pointee.SetFileName(dialog, $0)) }
            try wide(suffix) { try check(dialog.pointee.lpVtbl.pointee.SetDefaultExtension(dialog, $0)) }
            try wide("Export") { try check(dialog.pointee.lpVtbl.pointee.SetOkButtonLabel(dialog, $0)) }
            try wide("Export " + description) { try check(dialog.pointee.lpVtbl.pointee.SetTitle(dialog, $0)) }
            let result = dialog.pointee.lpVtbl.pointee.Show(dialog, hwnd)
            if UInt32(bitPattern: result) == 0x8007_04C7 { return } // User cancelled.
            try check(result)
            var item: UnsafeMutablePointer<IShellItem>?
            try check(dialog.pointee.lpVtbl.pointee.GetResult(dialog, &item))
            guard let item else { throw DialogError(code: HRESULT(bitPattern: 0x8000_4003)) }
            defer { _ = item.pointee.lpVtbl.pointee.Release(item) }
            var path: PWSTR?
            try check(item.pointee.lpVtbl.pointee.GetDisplayName(item, SIGDN_FILESYSPATH, &path))
            guard let path else { throw DialogError(code: HRESULT(bitPattern: 0x8000_4003)) }
            defer { CoTaskMemFree(path) }
            save(URL(fileURLWithPath: String(decodingCString: path, as: UTF16.self)))
        } catch {
            WindowsModel.shared.message = "Export dialog could not complete: \(error.localizedDescription)"
        }
    }
    private static func check(_ result: HRESULT) throws {
        if result < 0 { throw DialogError(code: result) }
    }
    private static func wide<T>(_ text: String, _ body: (UnsafePointer<WCHAR>) throws -> T) rethrows -> T {
        try (Array(text.utf16) + [0]).withUnsafeBufferPointer { try body($0.baseAddress!) }
    }
    private struct DialogError: LocalizedError {
        let code: HRESULT
        var errorDescription: String? { String(format: "Windows error 0x%08X", UInt32(bitPattern: code)) }
    }
}
