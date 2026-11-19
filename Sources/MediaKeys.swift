import AppKit
import os

private let log = Logger(subsystem: "local.knob", category: "keys")

/// Catches the volume keys. The handler decides per press whether the key is Knob's; keys it
/// declines go on to macOS untouched. Needs Accessibility permission to hold a key back.
@MainActor
final class MediaKeys {
    enum Key { case up, down, mute }

    /// Return true to keep the key from macOS.
    private let handler: (Key, _ fine: Bool) -> Bool
    private var tap: CFMachPort?
    private var permissionObserver: NSObjectProtocol?
    private var heldKeys = Set<Int>()

    init(handler: @escaping (Key, Bool) -> Bool) {
        self.handler = handler
    }

    var isAllowed: Bool { AXIsProcessTrusted() }

    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            askForPermissionOnce()
            return
        }
        // Key and media events only (NX_SYSDEFINED): ordinary typing never reaches Knob.
        let mask = CGEventMask(1) << 14
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mediaKeyCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.error("Could not listen for the volume keys")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if let permissionObserver { DistributedNotificationCenter.default().removeObserver(permissionObserver) }
        permissionObserver = nil
        log.notice("Volume keys on")
    }

    private func askForPermissionOnce() {
        if !UserDefaults.standard.bool(forKey: "askedForAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        // macOS posts this when the Accessibility list changes; the grant lands a moment later.
        guard permissionObserver == nil else { return }
        permissionObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.start() }
            }
        }
    }

    fileprivate func handle(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = (key.data1 & 0xFFFF_0000) >> 16
        let isDown = (key.data1 & 0xFF00) >> 8 == 0xA
        let mapped: Key
        switch code {
        case 0: mapped = .up        // NX_KEYTYPE_SOUND_UP
        case 1: mapped = .down      // NX_KEYTYPE_SOUND_DOWN
        case 7: mapped = .mute      // NX_KEYTYPE_MUTE
        default: return Unmanaged.passUnretained(event)
        }
        if isDown {
            let fine = key.modifierFlags.isSuperset(of: [.shift, .option])
            guard handler(mapped, fine) else {
                heldKeys.remove(code)
                return Unmanaged.passUnretained(event)
            }
            heldKeys.insert(code)
            return nil
        }
        // A key-up follows whoever took the key-down.
        return heldKeys.remove(code) == nil ? Unmanaged.passUnretained(event) : nil
    }
}

private func mediaKeyCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    return MainActor.assumeIsolated {
        Unmanaged<MediaKeys>.fromOpaque(context).takeUnretainedValue().handle(event, type: type)
    }
}
