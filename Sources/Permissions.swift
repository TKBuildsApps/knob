import ApplicationServices
import Foundation

/// "System Audio Recording" permission, which a Core Audio tap needs. macOS has no public call to
/// read it, so Knob uses the TCC calls the system prompt itself is built on. If they are ever
/// missing, Knob goes ahead and macOS asks on first use instead.
enum AudioCapturePermission {
    enum Status { case granted, denied, undetermined }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .granted }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt. `done` runs on the main queue.
    static func request(_ done: @escaping (Bool) -> Void) {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return done(true) }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }
}

enum SettingsPane {
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// "Screen & System Audio Recording", which holds the "System Audio Recording Only" list.
    static let audioRecording = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
