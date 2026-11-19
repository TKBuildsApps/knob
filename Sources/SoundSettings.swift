import Foundation

/// Volume, balance and mute, remembered between connections.
final class SoundSettings {
    /// macOS volume keys move in sixteenths; with Shift-Option held, in quarters of that.
    static let step = 1.0 / 16
    static let fineStep = 1.0 / 64

    private let defaults = UserDefaults.standard

    /// 0 to 1. 1 passes the sound through untouched, exactly as loud as without Knob.
    var volume: Double {
        didSet {
            volume = min(max(volume, 0), 1)
            defaults.set(volume, forKey: "volume")
        }
    }

    /// -1 (left only) to 1 (right only).
    var balance: Double {
        didSet {
            balance = min(max(balance, -1), 1)
            defaults.set(balance, forKey: "balance")
        }
    }

    var muted: Bool {
        didSet { defaults.set(muted, forKey: "muted") }
    }

    init() {
        volume = defaults.object(forKey: "volume") as? Double ?? 1
        balance = defaults.object(forKey: "balance") as? Double ?? 0
        muted = defaults.bool(forKey: "muted")
    }

    /// Moves the volume one step up or down on the step grid, unmuting like the native keys do.
    func nudge(up: Bool, fine: Bool) {
        let step = fine ? Self.fineStep : Self.step
        muted = false
        volume = ((volume / step).rounded() + (up ? 1 : -1)) * step
    }

    /// Amplitudes for the stereo pair and for any other channels. The cubic curve makes each step sound
    /// like an even change in loudness; balance turns the far side down and leaves the near side alone.
    var gains: (left: Float, right: Float, other: Float) {
        let level = muted ? 0 : volume * volume * volume
        return (Float(level * min(1, 1 - balance)), Float(level * min(1, 1 + balance)), Float(level))
    }
}
