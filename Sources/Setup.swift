import AppKit
import CoreAudio
import IOKit

/// A connected external screen and what Knob can do with it.
struct DetectedScreen {
    let name: String
    /// IOKit rule for the screen, or nil if Knob cannot tell when this screen comes and goes.
    let match: [String: Any]?
    let connection: String?
    let audio: HAL.Device?
    let audioHasOwnVolume: Bool
}

/// Finds external screens and how to recognise each one when it connects.
@MainActor
enum Detect {
    static func screens() -> [DetectedScreen] {
        let hubs = thunderboltHubs()
        let links = displayPortLinks()
        return externalScreenNames().map { name in
            var match: [String: Any]?
            var connection: String?
            // A Thunderbolt hub is the steadiest sign: it stays while the screen sleeps.
            if let hub = hubs.first(where: { name.localizedCaseInsensitiveContains($0.model) }) {
                match = ["IOProviderClass": "IOThunderboltSwitch",
                         "IOPropertyMatch": ["Device Vendor ID": hub.vendorID, "Device Model Name": hub.model]]
                connection = "Thunderbolt"
            } else if links.contains(name) {
                match = ["IOProviderClass": "IOPortTransportStateDisplayPort", "IOPropertyMatch": ["ProductName": name]]
                connection = "DisplayPort"
            }
            // Only keep a rule that finds the screen right now.
            if let rule = match, !ScreenPresence(matching: rule).isConnected {
                match = nil
                connection = nil
            }
            let audio = HAL.outputDevice(named: name)
            return DetectedScreen(name: name, match: match, connection: connection, audio: audio,
                                  audioHasOwnVolume: audio.map { HAL.hasOwnVolume($0.id) } ?? false)
        }
    }

    private static func externalScreenNames() -> [String] {
        var names = [String]()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0,
                  !names.contains(screen.localizedName)
            else { continue }
            names.append(screen.localizedName)
        }
        return names
    }

    private static func thunderboltHubs() -> [(model: String, vendorID: Int)] {
        registry("IOThunderboltSwitch", keys: ["Device Model Name", "Device Vendor ID"]).compactMap { entry in
            guard let model = entry["Device Model Name"] as? String, !model.isEmpty,
                  let vendor = (entry["Device Vendor ID"] as? NSNumber)?.intValue,
                  vendor != 0x05AC  // The Mac's own Thunderbolt controllers.
            else { return nil }
            return (model, vendor)
        }
    }

    private static func displayPortLinks() -> Set<String> {
        Set(registry("IOPortTransportStateDisplayPort", keys: ["ProductName"]).compactMap { $0["ProductName"] as? String })
    }

    private static func registry(_ className: String, keys: [String]) -> [[String: Any]] {
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &services) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(services) }
        var entries = [[String: Any]]()
        while case let service = IOIteratorNext(services), service != 0 {
            var entry = [String: Any]()
            for key in keys {
                entry[key] = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            IOObjectRelease(service)
            entries.append(entry)
        }
        return entries
    }
}

/// The command-line side of Knob: `--setup`, `--check` and `--write-agent`.
@MainActor
enum Setup {
    private static let interactive = isatty(STDIN_FILENO) != 0

    static func run() -> Bool {
        say("Knob setup\n")
        let screens = Detect.screens()
        guard !screens.isEmpty else {
            say("No external screen is connected. Connect it and run setup again.")
            return false
        }
        let usable = screens.filter { $0.match != nil }
        for screen in screens where screen.match == nil {
            say("• \(screen.name): Knob can't tell when this screen connects, so it can't be used.")
        }
        guard let screen = pick(usable) else { return false }
        say("Screen: \(screen.name) (\(screen.connection ?? "?"))")

        var sound = false
        if screen.audio == nil {
            say("This screen has no sound output, so there's no sound to control.")
        } else if screen.audioHasOwnVolume {
            say("macOS can already set this screen's volume, so Knob's sound control isn't needed.")
            sound = ask("Use Knob's sound control anyway?", default: false)
        } else {
            sound = ask("Control the screen's sound (volume keys, volume and balance)?", default: true)
        }

        var apps = [KnobConfig.App]()
        for (id, arguments) in KnobConfig.quietLaunchArguments.sorted(by: { $0.key < $1.key }) {
            guard let name = appName(id) else { continue }
            if ask("Open \(name) when the screen connects (menu bar only, no window)?", default: true) {
                apps.append(.init(bundleID: id, arguments: arguments))
            }
        }
        if interactive {
            let answer = prompt("Other apps to open with the screen? Names, separated by commas (Return to skip): ")
            for query in answer.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !query.isEmpty {
                guard let id = findApp(query) else {
                    say("  Couldn't find \"\(query)\", skipped.")
                    continue
                }
                if !apps.contains(where: { $0.bundleID == id }) {
                    apps.append(.init(bundleID: id, arguments: KnobConfig.quietLaunchArguments[id] ?? []))
                }
            }
        }

        guard sound || !apps.isEmpty else {
            say("\nNothing to do: choose sound control, an app, or both.")
            return false
        }
        let config = KnobConfig(screenName: screen.name, match: screen.match!, sound: sound, apps: apps)
        do {
            try config.save()
        } catch {
            say("Couldn't save the setup: \(error.localizedDescription)")
            return false
        }
        say("\nSaved: \(summary(config))")
        return true
    }

    /// Prints what Knob will do and whether the screen is connected now.
    static func check() -> Bool {
        guard let config = KnobConfig.load() else {
            say("Knob isn't set up yet. Run ./install.sh")
            return false
        }
        say("Knob: \(summary(config))")
        say("Screen connected now: \(ScreenPresence(matching: config.match).isConnected ? "yes" : "no")")
        if config.sound {
            if let device = HAL.outputDevice(named: config.screenName) {
                say("Sound output: \(device.uid)\(HAL.hasOwnVolume(device.id) ? " (has its own volume control)" : "")")
            } else {
                say("Sound output: not found right now")
            }
        }
        for app in config.apps where appName(app.bundleID) == nil {
            say("Not installed: \(app.bundleID)")
        }
        return true
    }

    /// Writes the LaunchAgent that starts `program` when the screen connects.
    static func writeAgent(program: String) -> Bool {
        guard let config = KnobConfig.load() else {
            say("Knob isn't set up yet. Run ./install.sh --setup")
            return false
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: config.launchAgent(program: program), format: .xml, options: 0)
            try FileManager.default.createDirectory(at: KnobConfig.agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: KnobConfig.agentURL, options: .atomic)
            return true
        } catch {
            say("Couldn't write the LaunchAgent: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Helpers

    private static func pick(_ screens: [DetectedScreen]) -> DetectedScreen? {
        switch screens.count {
        case 0:
            say("No screen Knob can use is connected.")
            return nil
        case 1:
            return screens[0]
        default:
            guard interactive else {
                say("Several screens are connected. Run ./install.sh --setup in Terminal to choose one.")
                return nil
            }
            for (index, screen) in screens.enumerated() { say("  \(index + 1). \(screen.name)") }
            let answer = prompt("Which screen? [1] ")
            guard let number = answer.isEmpty ? 1 : Int(answer), screens.indices.contains(number - 1) else {
                say("No such screen.")
                return nil
            }
            return screens[number - 1]
        }
    }

    private static func summary(_ config: KnobConfig) -> String {
        var parts = [config.screenName]
        if config.sound { parts.append("sound control on") }
        let names = config.apps.map { appName($0.bundleID) ?? $0.bundleID }
        if !names.isEmpty { parts.append("opens \(names.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    private static func appName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Finds an app by bundle ID or by name in the usual Applications folders.
    private static func findApp(_ query: String) -> String? {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) != nil { return query }
        let wanted = (query.hasSuffix(".app") ? query : query + ".app").lowercased()
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder),
                  let match = names.first(where: { $0.lowercased() == wanted })
            else { continue }
            return Bundle(path: "\(folder)/\(match)")?.bundleIdentifier
        }
        return nil
    }

    private static func ask(_ question: String, default yes: Bool) -> Bool {
        guard interactive else {
            say("\(question) \(yes ? "Yes" : "No") (default)")
            return yes
        }
        let answer = prompt("\(question) [\(yes ? "Y/n" : "y/N")] ").lowercased()
        return answer.isEmpty ? yes : answer.hasPrefix("y")
    }

    private static func prompt(_ text: String) -> String {
        print(text, terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func say(_ text: String) {
        print(text)
    }
}
