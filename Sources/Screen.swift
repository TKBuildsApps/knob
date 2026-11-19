import Foundation
import IOKit
import os

private let log = Logger(subsystem: "local.knob", category: "screen")

/// Watches the IOKit object that stands for the screen (its Thunderbolt hub or DisplayPort link) and
/// calls `onGone` when it disappears. Event driven: the kernel wakes the app only when it goes away.
final class ScreenPresence {
    private let matching: [String: Any]
    private let onGone: () -> Void
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0

    init(matching: [String: Any], onGone: @escaping () -> Void = {}) {
        self.matching = matching
        self.onGone = onGone
    }

    deinit {
        if iterator != 0 { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    var isConnected: Bool {
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, rule(), &services) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(services) }
        return Self.drain(services)
    }

    func watch() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let status = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, rule(), { context, iterator in
            guard let context else { return }
            let presence = Unmanaged<ScreenPresence>.fromOpaque(context).takeUnretainedValue()
            if ScreenPresence.drain(iterator) { presence.onGone() }
        }, Unmanaged.passUnretained(self).toOpaque(), &iterator)
        guard status == KERN_SUCCESS else {
            log.error("Could not watch the screen (\(status)); Knob will not quit on unplug")
            return
        }
        _ = Self.drain(iterator)  // Arms the notification.
    }

    /// A fresh copy each time: IOKit takes ownership of the rule it is given.
    private func rule() -> CFDictionary { NSMutableDictionary(dictionary: matching) }

    private static func drain(_ iterator: io_iterator_t) -> Bool {
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            found = true
        }
        return found
    }
}
