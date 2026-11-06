import SwiftCrossUI

// Keep upstream engine declarations internal to ToastMonitor on both platforms.
// These are the UI backend's real publishers, not a Combine emulation.
typealias ObservableObject = SwiftCrossUI.ObservableObject
typealias Published<Value> = SwiftCrossUI.Published<Value>
