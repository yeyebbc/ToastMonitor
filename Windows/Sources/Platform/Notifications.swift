import Foundation
import WindowsServicesNative

/// Unpackaged Windows builds use native notification dialogs, not a pretend toast API.
/// Delivery is serialized off the UI thread; the user can disable it in Settings.
enum WindowsAlertDelivery {
    private static let deliveryQueue = DispatchQueue(label: "ToastMonitor.Windows.notifications", qos: .utility)
    private static var scheduled: [String: DispatchWorkItem] = [:] // main-thread owned

    static func post(title: String, body: String) {
        deliveryQueue.async {
            let heading = Array(title.utf16) + [0]
            let message = Array(body.utf16) + [0]
            heading.withUnsafeBufferPointer { heading in
                message.withUnsafeBufferPointer { tm_notify(heading.baseAddress, $0.baseAddress) }
            }
        }
    }
    static func cancel(identifiers: [String]) {
        for identifier in identifiers {
            scheduled.removeValue(forKey: identifier)?.cancel()
        }
    }
    static func schedule(identifier: String, title: String, body: String, at date: Date) {
        scheduled.removeValue(forKey: identifier)?.cancel()
        let item = DispatchWorkItem {
            scheduled[identifier] = nil
            post(title: title, body: body)
        }
        scheduled[identifier] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow), execute: item)
    }
}
