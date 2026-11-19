import Foundation
import os

private let log = Logger(subsystem: "local.knob", category: "config")

/// What setup chose: the screen, whether Knob controls its sound, and which apps come with it.
/// One file is the single source: the app reads it at launch and the LaunchAgent is generated from it,
/// so starting and stopping can never disagree about which screen it is.
struct KnobConfig {
    struct App {
        let bundleID: String
        /// Passed at launch, e.g. a flag that starts the app in the menu bar without a window.
        let arguments: [String]
    }

    /// The screen's name as macOS shows it, e.g. "DELL U4025QW". Its audio device carries the same name.
    var screenName: String
    /// IOKit matching rule for something that exists exactly while the screen is connected.
    var match: [String: Any]
    /// Whether Knob controls the screen's sound (volume keys, volume, balance).
    var sound: Bool
    /// Apps opened when the screen connects and quit when it is unplugged.
    var apps: [App]

    static let label = "local.knob"
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Knob/config.plist")
    static let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")

    /// Flags that open an app straight into the menu bar, as its own login item does.
    static let quietLaunchArguments: [String: [String]] = [
        "com.logitech.logitune": ["--tray"],
    ]

    static func load() -> KnobConfig? {
        guard let data = try? Data(contentsOf: fileURL) else {
            log.error("No setup found at \(fileURL.path, privacy: .public); run ./install.sh")
            return nil
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let screen = plist["Screen"] as? [String: Any],
              let name = screen["Name"] as? String, !name.isEmpty,
              let match = screen["Match"] as? [String: Any], match["IOProviderClass"] is String,
              let sound = plist["Sound"] as? Bool
        else {
            log.error("config.plist is incomplete; run ./install.sh --setup")
            return nil
        }
        let apps = (plist["Apps"] as? [[String: Any]] ?? []).compactMap { entry -> App? in
            guard let id = entry["BundleID"] as? String, !id.isEmpty else { return nil }
            return App(bundleID: id, arguments: entry["Arguments"] as? [String] ?? [])
        }
        return KnobConfig(screenName: name, match: match, sound: sound, apps: apps)
    }

    func save() throws {
        let plist: [String: Any] = [
            "Screen": ["Name": screenName, "Match": match],
            "Sound": sound,
            "Apps": apps.map { ["BundleID": $0.bundleID, "Arguments": $0.arguments] },
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.fileURL, options: .atomic)
    }

    /// The LaunchAgent that starts `program` when the screen appears. Nothing runs while it is unplugged.
    func launchAgent(program: String) -> [String: Any] {
        var trigger = match
        trigger["IOMatchLaunchStream"] = true
        return [
            "Label": Self.label,
            "Program": program,
            "RunAtLoad": true,  // Covers login with the screen already connected; Knob quits if it is not.
            "KeepAlive": ["Crashed": true],
            "LimitLoadToSessionType": "Aqua",
            "LaunchEvents": ["com.apple.iokit.matching": ["\(Self.label).screen": trigger]],
        ]
    }
}
