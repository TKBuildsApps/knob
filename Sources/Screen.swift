import AppKit
import IOKit
import os

private let log = Logger(subsystem: "local.knob", category: "screen")

/// Whether the screen is connected, and a call when that changes. Event driven either way.
final class ScreenPresence {
    enum Source {
        /// The IOKit object that stands for the screen (its Thunderbolt hub or DisplayPort link). It
        /// stays while the screen sleeps. Only its disappearance is reported: launchd handles arrival.
        case registry([String: Any])
        /// The screen itself, by name, for connections with no such object (HDMI, for one).
        case display(name: String)
    }

    private let source: Source
    private let onChange: (Bool) -> Void
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var displayObserver: NSObjectProtocol?
    private var lastConnected = false

    init(_ source: Source, onChange: @escaping (_ connected: Bool) -> Void = { _ in }) {
        self.source = source
        self.onChange = onChange
    }

    deinit {
        if iterator != 0 { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }

    var isConnected: Bool {
        switch source {
        case .registry(let matching):
            var services: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, Self.rule(matching), &services) == KERN_SUCCESS else { return false }
            defer { IOObjectRelease(services) }
            return Self.drain(services)
        case .display(let name):
            // Knob runs on the main thread throughout: as an app, and as the setup command.
            return MainActor.assumeIsolated { NSScreen.screens.contains { $0.localizedName == name } }
        }
    }

    func watch() {
        switch source {
        case .registry(let matching): watchRegistry(matching)
        case .display: watchDisplays()
        }
    }

    private func watchRegistry(_ matching: [String: Any]) {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let status = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.rule(matching), { context, iterator in
            guard let context else { return }
            let presence = Unmanaged<ScreenPresence>.fromOpaque(context).takeUnretainedValue()
            if ScreenPresence.drain(iterator) { presence.onChange(false) }
        }, Unmanaged.passUnretained(self).toOpaque(), &iterator)
        guard status == KERN_SUCCESS else {
            log.error("Could not watch the screen (\(status)); Knob will not quit on unplug")
            return
        }
        _ = Self.drain(iterator)  // Arms the notification.
    }

    /// AppKit posts the notification when a screen is added or removed (and when one changes
    /// resolution or arrangement, which leaves the answer as it was and is ignored).
    private func watchDisplays() {
        guard displayObserver == nil else { return }
        lastConnected = isConnected
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let connected = isConnected
            guard connected != lastConnected else { return }
            lastConnected = connected
            onChange(connected)
        }
    }

    /// A fresh copy each time: IOKit takes ownership of the rule it is given.
    private static func rule(_ matching: [String: Any]) -> CFDictionary {
        NSMutableDictionary(dictionary: matching)
    }

    private static func drain(_ iterator: io_iterator_t) -> Bool {
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            found = true
        }
        return found
    }
}
