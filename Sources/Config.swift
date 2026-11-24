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
    /// IOKit matching rule for something that exists exactly while the screen is connected (its
    /// Thunderbolt hub or DisplayPort link). nil when there is none, as over HDMI: Knob then starts
    /// at login and watches for the screen by name.
    var match: [String: Any]?
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

    /// Whether Knob starts at login and waits for the screen, rather than being started by it.
    var startsAtLogin: Bool { match == nil }

    /// How to tell whether the screen is connected.
    var presence: ScreenPresence.Source {
        match.map { .registry($0) } ?? .display(name: screenName)
    }

    static func load() -> KnobConfig? {
        guard let data = try? Data(contentsOf: fileURL) else {
            log.error("No setup found at \(fileURL.path, privacy: .public); run ./install.sh")
            return nil
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let screen = plist["Screen"] as? [String: Any],
              let name = screen["Name"] as? String, !name.isEmpty,
              let sound = plist["Sound"] as? Bool
        else {
            log.error("config.plist is incomplete; run ./install.sh --setup")
            return nil
        }
        // No rule means "watch by name"; a rule that is there must be usable.
        var match: [String: Any]?
        if let rule = screen["Match"] {
            guard let rule = rule as? [String: Any], rule["IOProviderClass"] is String else {
                log.error("config.plist has an unusable screen rule; run ./install.sh --setup")
                return nil
            }
            match = rule
        }
        let apps = (plist["Apps"] as? [[String: Any]] ?? []).compactMap { entry -> App? in
            guard let id = entry["BundleID"] as? String, !id.isEmpty else { return nil }
            return App(bundleID: id, arguments: entry["Arguments"] as? [String] ?? [])
        }
        return KnobConfig(screenName: name, match: match, sound: sound, apps: apps)
    }

    func save() throws {
        var screen: [String: Any] = ["Name": screenName]
        if let match { screen["Match"] = match }
        let plist: [String: Any] = [
            "Screen": screen,
            "Sound": sound,
            "Apps": apps.map { ["BundleID": $0.bundleID, "Arguments": $0.arguments] },
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.fileURL, options: .atomic)
    }

    /// The LaunchAgent for `program`. With a rule it starts Knob when the screen appears, and nothing
    /// runs while the screen is unplugged. Without one it starts Knob at login, to wait for the screen.
    func launchAgent(program: String) -> [String: Any] {
        var agent: [String: Any] = [
            "Label": Self.label,
            "Program": program,
            // At login. With a rule this covers a screen that is already connected; Knob quits if it is not.
            "RunAtLoad": true,
            "KeepAlive": ["Crashed": true],
            "LimitLoadToSessionType": "Aqua",
        ]
        if var trigger = match {
            trigger["IOMatchLaunchStream"] = true
            agent["LaunchEvents"] = ["com.apple.iokit.matching": ["\(Self.label).screen": trigger]]
        }
        return agent
    }
}
