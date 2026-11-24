import AppKit

/// The menu bar icon and its menu: volume, balance, mute, swapping sides, and any permission Knob still needs.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    var onChange: (() -> Void)?

    private let settings: SoundSettings
    private let engine: AudioEngine
    private let keys: MediaKeys
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let volumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeValue = NSTextField(labelWithString: "")
    private let balanceSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let balanceValue = NSTextField(labelWithString: "")
    private let muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "")
    private let swapItem = NSMenuItem(title: "Swap Left and Right", action: #selector(toggleSwap), keyEquivalent: "")
    private let notice = NSMenuItem()
    private let audioPermissionItem = NSMenuItem(title: "Allow System Audio Recording…", action: #selector(openAudioSettings), keyEquivalent: "")
    private let keysPermissionItem = NSMenuItem(title: "Turn On Volume Keys…", action: #selector(openKeysSettings), keyEquivalent: "")
    private var iconName = ""

    var button: NSStatusBarButton? { item.button }

    /// Hidden while the screen is unplugged, when Knob was started at login and keeps running.
    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    init(settings: SoundSettings, engine: AudioEngine, keys: MediaKeys) {
        self.settings = settings
        self.engine = engine
        self.keys = keys
        super.init()

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeMoved)
        balanceSlider.target = self
        balanceSlider.action = #selector(balanceMoved)
        balanceSlider.numberOfTickMarks = 1  // One mark, at the centre.

        menu.delegate = self
        menu.addItem(sliderRow("Volume", volumeSlider, volumeValue))
        menu.addItem(sliderRow("Balance", balanceSlider, balanceValue))
        menu.addItem(.separator())
        muteItem.target = self
        menu.addItem(muteItem)
        swapItem.target = self
        swapItem.toolTip = "For speakers wired the wrong way round: plays the left side on the right speaker and the right side on the left."
        menu.addItem(swapItem)
        notice.isEnabled = false
        menu.addItem(notice)
        audioPermissionItem.target = self
        menu.addItem(audioPermissionItem)
        keysPermissionItem.target = self
        menu.addItem(keysPermissionItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Knob", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.isVisible = true  // macOS remembers a hidden icon across launches; Knob starts shown.
        refresh()
    }

    /// Updates the icon, and the menu too if it is open.
    func refresh() {
        let level = settings.muted ? 0 : settings.volume
        let name = switch level {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
        if name != iconName, let image = NSImage(systemSymbolName: name, accessibilityDescription: "Volume") {
            image.isTemplate = true
            item.button?.image = image
            iconName = name
        }
        item.button?.appearsDisabled = engine.state != .ready
        syncMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        engine.retry()  // Picks up a permission granted since, or tries again after a failure.
        keys.start()
        syncMenu()
    }

    private func syncMenu() {
        volumeSlider.doubleValue = settings.volume
        volumeValue.stringValue = "\(Int((settings.volume * 100).rounded()))%"
        balanceSlider.doubleValue = settings.balance
        let side = Int((abs(settings.balance) * 100).rounded())
        balanceValue.stringValue = side == 0 ? "Centre" : "\(settings.balance < 0 ? "Left" : "Right") \(side)"
        muteItem.state = settings.muted ? .on : .off
        swapItem.state = settings.swapped ? .on : .off

        let ready = engine.state == .ready
        volumeSlider.isEnabled = ready
        balanceSlider.isEnabled = ready
        muteItem.isEnabled = ready
        swapItem.isEnabled = ready
        switch engine.state {
        case .ready: notice.title = ""
        case .waitingForScreen: notice.title = "Waiting for the screen’s sound…"
        case .needsPermission: notice.title = "Knob needs System Audio Recording"
        case .failed(let reason): notice.title = reason
        }
        notice.isHidden = ready
        audioPermissionItem.isHidden = engine.state != .needsPermission
        keysPermissionItem.isHidden = keys.isAllowed
    }

    @objc private func volumeMoved() {
        settings.muted = false
        settings.volume = volumeSlider.doubleValue
        changed()
    }

    @objc private func balanceMoved() {
        // Snap to the centre so it is easy to land on.
        settings.balance = abs(balanceSlider.doubleValue) < 0.05 ? 0 : balanceSlider.doubleValue
        changed()
    }

    @objc private func toggleMute() {
        settings.muted.toggle()
        changed()
    }

    @objc private func toggleSwap() {
        settings.swapped.toggle()
        changed()
    }

    @objc private func openAudioSettings() { NSWorkspace.shared.open(SettingsPane.audioRecording) }
    @objc private func openKeysSettings() { NSWorkspace.shared.open(SettingsPane.accessibility) }

    private func changed() {
        onChange?()
        refresh()
    }

    private func sliderRow(_ title: String, _ slider: NSSlider, _ value: NSTextField) -> NSMenuItem {
        let width: CGFloat = 260
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 50))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 28, width: 120, height: 17)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: width - 120, y: 28, width: 100, height: 17)
        slider.isContinuous = true
        slider.frame = NSRect(x: 18, y: 4, width: width - 36, height: 22)
        view.addSubview(label)
        view.addSubview(value)
        view.addSubview(slider)
        let row = NSMenuItem()
        row.view = view
        return row
    }
}
