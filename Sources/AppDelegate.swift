import AppKit
import os

private let log = Logger(subsystem: "local.knob", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hud = VolumeHUD()
    private var config: KnobConfig?
    private var presence: ScreenPresence?
    private var settings: SoundSettings?
    private var engine: AudioEngine?
    private var keys: MediaKeys?
    private var menu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let config = KnobConfig.load() else { return NSApp.terminate(nil) }
        let presence = ScreenPresence(matching: config.match) { [weak self] in self?.screenUnplugged() }
        presence.watch()  // Before the check, so an unplug right after it is not missed.
        // At login the agent starts Knob whether or not the screen is there.
        guard presence.isConnected else { return NSApp.terminate(nil) }
        self.config = config
        self.presence = presence
        log.notice("Screen \(config.screenName, privacy: .public) connected")

        openApps()
        if config.sound { startSoundControl(deviceName: config.screenName) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    /// The menu bar icon, volume keys and audio path. Without sound control Knob shows nothing and
    /// only opens and quits the apps.
    private func startSoundControl(deviceName: String) {
        let settings = SoundSettings()
        let engine = AudioEngine(deviceName: deviceName)
        let keys = MediaKeys { [weak self] key, fine in self?.volumeKey(key, fine: fine) ?? false }
        let menu = StatusMenu(settings: settings, engine: engine, keys: keys)
        menu.onChange = { [weak self] in self?.applyGains() }
        engine.onStateChange = { [weak menu] in menu?.refresh() }
        self.settings = settings
        self.engine = engine
        self.keys = keys
        self.menu = menu

        applyGains()
        engine.start()
        keys.start()
    }

    private func screenUnplugged() {
        log.notice("Screen unplugged")
        quitApps()
        NSApp.terminate(nil)
    }

    private func applyGains() {
        guard let gains = settings?.gains else { return }
        Mixer.setGains(left: gains.left, right: gains.right, other: gains.other)
    }

    /// Keys are Knob's only while the screen is the sound output; otherwise macOS handles them as usual.
    private func volumeKey(_ key: MediaKeys.Key, fine: Bool) -> Bool {
        guard let engine, let settings, engine.isScreenTheOutput else { return false }
        switch key {
        case .up: settings.nudge(up: true, fine: fine)
        case .down: settings.nudge(up: false, fine: fine)
        case .mute: settings.muted.toggle()
        }
        applyGains()
        menu?.refresh()
        hud.show(level: settings.volume, muted: settings.muted, below: menu?.button)
        return true
    }

    private func openApps() {
        for app in config?.apps ?? [] where NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
                log.error("\(app.bundleID, privacy: .public) is not installed")
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = app.arguments
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    log.error("Could not open \(app.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func quitApps() {
        for app in config?.apps ?? [] {
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
        }
    }
}
