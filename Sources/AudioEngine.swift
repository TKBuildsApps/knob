import CoreAudio
import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "local.knob", category: "audio")

/// The screen's audio output has no volume control of its own, so Knob reshapes the sound on its
/// way there: a muted Core Audio tap takes what every app sends to the screen, the mixer applies
/// volume and balance, and a private aggregate device plays the result back to the screen.
/// The audio path runs only while some app is actually sending sound to the screen.
final class AudioEngine {
    enum State: Equatable {
        case waitingForScreen
        case needsPermission
        case ready
        case failed(String)
    }

    private(set) var state: State = .waitingForScreen {
        didSet { if state != oldValue { onStateChange?() } }
    }
    var onStateChange: (() -> Void)?

    /// How long the audio path stays up after the last app goes quiet, so a sound that follows right
    /// after (the next track) starts instantly. Short, because a running stream wakes the screen's
    /// audio output, and speakers on it hiss a little while it is awake.
    private let idleStopDelay: TimeInterval = 3

    /// Audio cycle length in frames. Knob's output trails the original by two cycles: 256 frames
    /// at 48 kHz is ~11 ms, with no measurable CPU cost over 512 (128 halves it again but costs more).
    private static let bufferFrames: UInt32 = 256

    private let deviceName: String
    private var screen: HAL.Device?
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var isRunning = false
    private var pendingStop: DispatchWorkItem?
    private var playback: PlaybackWatcher?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var askedForPermission = false
    /// The device the last build failed on. Not retried on its own: tearing down a failed build
    /// changes the device list, which would otherwise start the next attempt straight away.
    private var failedOn: HAL.Device?

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    /// Whether the screen is the Mac's current sound output, i.e. whether volume keys belong to Knob.
    var isScreenTheOutput: Bool {
        guard state == .ready, let screen else { return false }
        return HAL.defaultOutputDevice() == screen.id
    }

    func start() {
        guard devicesListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        if HAL.addListener(HAL.system, kAudioHardwarePropertyDevices, listener) {
            devicesListener = listener
        } else {
            log.error("Could not watch the device list; Knob will not notice the screen's audio coming back")
        }
        refresh()
    }

    func stop() {
        if let devicesListener { HAL.removeListener(HAL.system, kAudioHardwarePropertyDevices, devicesListener) }
        devicesListener = nil
        teardown()
    }

    /// Re-reads the screen's audio device and the permission, and builds or tears down the audio path to match.
    func refresh() {
        let found = HAL.outputDevice(named: deviceName)
        if found != screen {
            teardown()
            screen = found
            failedOn = nil
        }
        guard let screen else {
            state = .waitingForScreen
            return
        }
        guard tap == kAudioObjectUnknown, screen != failedOn else { return }

        switch AudioCapturePermission.status {
        case .granted:
            build(on: screen)
        case .denied:
            state = .needsPermission
        case .undetermined:
            state = .needsPermission
            guard !askedForPermission else { return }
            askedForPermission = true
            AudioCapturePermission.request { [weak self] _ in self?.refresh() }
        }
    }

    /// One more try after a failure, e.g. when the menu opens; also re-reads the permission.
    func retry() {
        failedOn = nil
        refresh()
    }

    // MARK: Audio path

    private func build(on screen: HAL.Device) {
        // Knob's own output must stay out of the tap, or it would hear itself and feed back.
        guard let ownProcess = HAL.processObject(pid: getpid()) else {
            return fail("Could not identify Knob's own audio process")
        }

        let tapDescription = CATapDescription(excludingProcesses: [ownProcess], deviceUID: screen.uid, stream: 0)
        tapDescription.name = "Knob"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .muted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else { return fail("Could not tap the screen's audio", status) }
        tap = tapID

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Knob",
            kAudioAggregateDeviceUIDKey: "local.knob.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: screen.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: screen.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: false,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else { return fail("Could not create the output device", status) }
        aggregate = aggregateID

        // A short audio cycle keeps the added delay low: Knob's output trails the original by two cycles.
        var bufferFrames = Self.bufferFrames
        var bufferAddress = HAL.address(kAudioDevicePropertyBufferFrameSize)
        status = AudioObjectSetPropertyData(aggregate, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferFrames)
        if status != noErr { log.error("Could not shorten the audio cycle: \(status)") }

        guard HAL.streamsAreFloat32(aggregate) else { return fail("The screen uses an audio format Knob does not handle") }
        // The tap must be the only input, matching the screen's first output stream channel for channel.
        // A screen with a microphone would add its own input, which must never reach the speakers.
        let inputs = HAL.readObjects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let outputs = HAL.readObjects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard inputs.count == 1, let firstOutput = outputs.first,
              let tapChannels = HAL.channelCount(of: inputs[0]), tapChannels == HAL.channelCount(of: firstOutput)
        else { return fail("The screen's audio has a layout Knob does not handle (a microphone, perhaps)") }
        let pair = HAL.stereoPair(of: screen.id)
        Mixer.setStereoPair(left: pair.left, right: pair.right)

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, output, _ in
            Mixer.render(input, output)
        }
        guard status == noErr, let procID else { return fail("Could not start the audio callback", status) }
        ioProc = procID

        let watcher = PlaybackWatcher(device: screen.id, ownProcess: ownProcess) { [weak self] playing in
            self?.playbackChanged(playing)
        }
        playback = watcher
        state = .ready
        log.notice("Audio path ready on \(screen.uid, privacy: .public)")
        watcher.start()
    }

    private func playbackChanged(_ playing: Bool) {
        if playing {
            pendingStop?.cancel()
            pendingStop = nil
            guard !isRunning, let ioProc else { return }
            Mixer.fadeInOnNextStart()
            let status = AudioDeviceStart(aggregate, ioProc)
            guard status == noErr else { return fail("Could not start the audio path", status) }
            isRunning = true
        } else {
            guard isRunning, pendingStop == nil else { return }
            let stop = DispatchWorkItem { [weak self] in self?.stopIO() }
            pendingStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + idleStopDelay, execute: stop)
        }
    }

    private func stopIO() {
        pendingStop = nil
        guard isRunning, let ioProc else { return }
        AudioDeviceStop(aggregate, ioProc)
        isRunning = false
    }

    /// Stops and removes the audio path. Removing the tap unmutes the screen right away.
    func teardown() {
        pendingStop?.cancel()
        pendingStop = nil
        playback?.stop()
        playback = nil
        if let ioProc {
            if isRunning { AudioDeviceStop(aggregate, ioProc) }
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        isRunning = false
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    /// Any failure removes the tap, so the screen plays sound as it did before Knob rather than going silent.
    private func fail(_ message: String, _ status: OSStatus? = nil) {
        if let status {
            log.error("\(message, privacy: .public): \(status)")
        } else {
            log.error("\(message, privacy: .public)")
        }
        teardown()
        failedOn = screen
        state = .failed(message)
    }
}

/// Volume, balance and side swap applied on the real-time audio thread. Gains travel as Float bit
/// patterns in atomics: no locks and no allocation on that thread.
enum Mixer {
    private static let targetLeft = Atomic<UInt32>(0)
    private static let targetRight = Atomic<UInt32>(0)
    private static let targetOther = Atomic<UInt32>(0)
    private static let currentLeft = Atomic<UInt32>(0)
    private static let currentRight = Atomic<UInt32>(0)
    private static let currentOther = Atomic<UInt32>(0)
    /// 0 plays each side on its own channel, 1 plays it on the other one; in between is a crossfade.
    private static let targetSwap = Atomic<UInt32>(0)
    private static let currentSwap = Atomic<UInt32>(0)
    private static let leftChannel = Atomic<Int>(0)
    private static let rightChannel = Atomic<Int>(1)

    /// `left` and `right` apply to the stereo pair, `other` to any further channels (volume, no balance).
    static func setGains(left: Float, right: Float, other: Float) {
        targetLeft.store(left.bitPattern, ordering: .relaxed)
        targetRight.store(right.bitPattern, ordering: .relaxed)
        targetOther.store(other.bitPattern, ordering: .relaxed)
    }

    /// Plays the left side on the right channel and the other way round, for speakers wired the
    /// wrong way. `left` and `right` gains keep following the sides, so balance stays true to the ear.
    static func setSwapped(_ swapped: Bool) {
        targetSwap.store(Float(swapped ? 1 : 0).bitPattern, ordering: .relaxed)
    }

    /// Zero-based channels of the stereo pair; -1 for none (balance and swap then have no effect).
    static func setStereoPair(left: Int, right: Int) {
        leftChannel.store(left, ordering: .relaxed)
        rightChannel.store(right, ordering: .relaxed)
    }

    /// Ramp up from silence on the next start instead of clicking in at full level. The swap needs
    /// no crossfade out of silence, so it starts where it should be.
    static func fadeInOnNextStart() {
        currentLeft.store(Float(0).bitPattern, ordering: .relaxed)
        currentRight.store(Float(0).bitPattern, ordering: .relaxed)
        currentOther.store(Float(0).bitPattern, ordering: .relaxed)
        currentSwap.store(targetSwap.load(ordering: .relaxed), ordering: .relaxed)
    }

    static func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        // The tap is the only input and mirrors the screen's first output stream (checked when built).
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let source = inputs.first, let destination = outputs.first,
              let sourceData = source.mData, let destinationData = destination.mData
        else { return }
        let sourceStride = Int(source.mNumberChannels)
        let destinationStride = Int(destination.mNumberChannels)
        let channels = min(sourceStride, destinationStride)
        guard channels > 0 else { return }
        let frames = min(Int(source.mDataByteSize) / (MemoryLayout<Float>.size * sourceStride),
                         Int(destination.mDataByteSize) / (MemoryLayout<Float>.size * destinationStride))
        guard frames > 0 else { return }
        let samples = sourceData.assumingMemoryBound(to: Float.self)
        let out = destinationData.assumingMemoryBound(to: Float.self)
        let leftIndex = leftChannel.load(ordering: .relaxed)
        let rightIndex = rightChannel.load(ordering: .relaxed)
        // Swapping reads each side from the other channel, so both must lie inside this stream. If
        // not, each channel reads only itself and the swap stays off.
        let canSwap = (0..<channels).contains(leftIndex) && (0..<channels).contains(rightIndex)
        let leftPartner = canSwap ? rightIndex : leftIndex
        let rightPartner = canSwap ? leftIndex : rightIndex

        // Glide from the last gains to the new ones across the buffer, so changes never click.
        let toLeft = Float(bitPattern: targetLeft.load(ordering: .relaxed))
        let toRight = Float(bitPattern: targetRight.load(ordering: .relaxed))
        let toOther = Float(bitPattern: targetOther.load(ordering: .relaxed))
        let toSwap = canSwap ? Float(bitPattern: targetSwap.load(ordering: .relaxed)) : 0
        var left = Float(bitPattern: currentLeft.load(ordering: .relaxed))
        var right = Float(bitPattern: currentRight.load(ordering: .relaxed))
        var other = Float(bitPattern: currentOther.load(ordering: .relaxed))
        var swap = canSwap ? Float(bitPattern: currentSwap.load(ordering: .relaxed)) : 0
        let stepLeft = (toLeft - left) / Float(frames)
        let stepRight = (toRight - right) / Float(frames)
        let stepOther = (toOther - other) / Float(frames)
        let stepSwap = (toSwap - swap) / Float(frames)

        for frame in 0..<frames {
            left += stepLeft
            right += stepRight
            other += stepOther
            swap += stepSwap
            let from = frame * sourceStride
            let to = frame * destinationStride
            for channel in 0..<channels {
                // At swap 0 the partner term is exactly zero, and at 1 the own term is, so a still
                // swap (on or off) at full volume and centred balance stays sample for sample.
                out[to + channel] = if channel == leftIndex {
                    samples[from + channel] * left * (1 - swap) + samples[from + leftPartner] * right * swap
                } else if channel == rightIndex {
                    samples[from + channel] * right * (1 - swap) + samples[from + rightPartner] * left * swap
                } else {
                    samples[from + channel] * other
                }
            }
        }
        currentLeft.store(toLeft.bitPattern, ordering: .relaxed)
        currentRight.store(toRight.bitPattern, ordering: .relaxed)
        currentOther.store(toOther.bitPattern, ordering: .relaxed)
        currentSwap.store(toSwap.bitPattern, ordering: .relaxed)
    }
}

/// Reports whether any app other than Knob is sending sound to the screen. Purely event driven:
/// Core Audio calls back when an app starts or stops playing.
final class PlaybackWatcher {
    private static let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
        (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
    ]

    private let device: AudioObjectID
    private let ownProcess: AudioObjectID
    private let onChange: (Bool) -> Void
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var isPlaying = false

    init(device: AudioObjectID, ownProcess: AudioObjectID, onChange: @escaping (Bool) -> Void) {
        self.device = device
        self.ownProcess = ownProcess
        self.onChange = onChange
    }

    func start() {
        guard listListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.syncProcesses() }
        if HAL.addListener(HAL.system, kAudioHardwarePropertyProcessObjectList, listener) {
            listListener = listener
        } else {
            log.error("Could not watch the app list; new apps will not wake the audio path")
        }
        syncProcesses()
    }

    func stop() {
        if let listListener { HAL.removeListener(HAL.system, kAudioHardwarePropertyProcessObjectList, listListener) }
        listListener = nil
        for (process, listener) in processListeners { unwatch(process, listener) }
        processListeners.removeAll()
    }

    private func syncProcesses() {
        var current = Set(HAL.processObjects())
        current.remove(ownProcess)
        for (process, listener) in processListeners where !current.contains(process) {
            unwatch(process, listener)
            processListeners[process] = nil
        }
        for process in current where processListeners[process] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
            for (selector, scope) in Self.watched { HAL.addListener(process, selector, scope: scope, listener) }
            processListeners[process] = listener
        }
        evaluate()
    }

    private func unwatch(_ process: AudioObjectID, _ listener: @escaping AudioObjectPropertyListenerBlock) {
        for (selector, scope) in Self.watched { HAL.removeListener(process, selector, scope: scope, listener) }
    }

    private func evaluate() {
        let playing = processListeners.keys.contains { HAL.isPlaying($0, on: device) }
        guard playing != isPlaying else { return }
        isPlaying = playing
        onChange(playing)
    }
}
