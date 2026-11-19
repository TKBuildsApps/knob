import AppKit

/// A small level pill under the menu bar icon while the volume keys are pressed. Drawn with two
/// plain layers (no blur), built on first use and kept for reuse.
@MainActor
final class VolumeHUD {
    private let size = NSSize(width: 200, height: 36)
    private var panel: NSPanel?
    private let icon = NSImageView()
    private let track = CALayer()
    private let fill = CALayer()
    private var hideTimer: Timer?

    func show(level: Double, muted: Bool, below button: NSStatusBarButton?) {
        let panel = panel ?? makePanel()
        let shown = muted ? 0 : level
        icon.image = NSImage(systemSymbolName: muted || level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             accessibilityDescription: "Volume")
        panel.contentView?.effectiveAppearance.performAsCurrentDrawingAppearance {
            panel.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
            panel.contentView?.layer?.borderColor = NSColor.separatorColor.cgColor
            track.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            fill.backgroundColor = NSColor.labelColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * shown, height: track.bounds.height)
        CATransaction.commit()

        panel.setFrameOrigin(origin(below: button))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // A key pressed during the fade brings the pill back; only hide if it stayed faded.
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func origin(below button: NSStatusBarButton?) -> NSPoint {
        guard let window = button?.window, let screen = window.screen ?? NSScreen.main else { return .zero }
        let anchor = window.frame
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: visible.maxY - size.height - 8)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = size.height / 2
        content.layer?.borderWidth = 0.5
        content.layer?.masksToBounds = true

        icon.frame = NSRect(x: 14, y: (size.height - 16) / 2, width: 18, height: 16)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .labelColor
        content.addSubview(icon)

        track.frame = NSRect(x: 42, y: (size.height - 6) / 2, width: size.width - 42 - 18, height: 6)
        track.cornerRadius = 3
        track.masksToBounds = true
        track.addSublayer(fill)
        content.layer?.addSublayer(track)

        panel.contentView = content
        self.panel = panel
        return panel
    }
}
