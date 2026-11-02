import AVFoundation
import CoreAudio
import EarshotCore
import Foundation

/// An output device as Core Audio reports it.
struct OutputDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var transport: UInt32
    /// Built-in output currently routed to the headphone jack.
    var builtInHeadphones: Bool

    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    /// Our best guess at "something in or on your ears".
    var isHeadphones: Bool { isBluetooth || builtInHeadphones || transport == kAudioDeviceTransportTypeUSB }

    var kind: String {
        if isBluetooth { return "Bluetooth" }
        if builtInHeadphones { return "Headphone jack" }
        if isBuiltIn { return "Mac speakers" }
        switch transport {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Display"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "Virtual"
        default: return "Other"
        }
    }
}

enum CoreAudioQuery {
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return err == noErr ? value : nil
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr) == noErr else { return [] }
        let typed = ptr.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static var outputDevices: [OutputDevice] {
        array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self).compactMap { id in
            let streams = array(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self)
            guard !streams.isEmpty else { return nil }
            let transport: UInt32 = get(id, kAudioDevicePropertyTransportType, 0) ?? 0
            var headphones = false
            if transport == kAudioDeviceTransportTypeBuiltIn,
               let source: UInt32 = get(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, 0) {
                headphones = source == 0x6864_706E  // 'hdpn'
            }
            return OutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                                name: string(id, kAudioObjectPropertyName) ?? "Device \(id)",
                                transport: transport, builtInHeadphones: headphones)
        }
    }

    static var defaultOutputID: AudioDeviceID {
        Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0)) ?? 0
    }
}

/// Plays speech through AVAudioEngine: player → time-stretch → gain → limiter,
/// on a device chosen by the output policy.
@MainActor
final class AudioOutput: ObservableObject {
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var defaultDeviceID: AudioDeviceID = 0
    /// Called when the device list or default changes (headphones on/off).
    var onRouteChange: (() -> Void)?

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let stretch = AVAudioUnitTimePitch()
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var currentDevice: AudioDeviceID = 0

    init() {
        engine.attach(player)
        engine.attach(stretch)
        engine.attach(gain)
        engine.attach(limiter)
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: gain, format: format)
        engine.connect(gain, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        refreshDevices()
        listen(kAudioHardwarePropertyDevices)
        listen(kAudioHardwarePropertyDefaultOutputDevice)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            Log.write("audio: engine configuration changed")
        }
    }

    private func listen(_ selector: AudioObjectPropertySelector) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshDevices()
                self?.onRouteChange?()
            }
        }
    }

    func refreshDevices() {
        devices = CoreAudioQuery.outputDevices
        defaultDeviceID = CoreAudioQuery.defaultOutputID
    }

    func isAllowed(_ device: OutputDevice, settings: Settings) -> Bool {
        switch settings.outputPolicy {
        case .anyDevice: true
        case .headphonesOnly: device.isHeadphones
        case .chosenDevices: settings.allowedDeviceUIDs.contains(device.uid)
        }
    }

    /// The device to speak on: the system default when it is allowed, else any
    /// other allowed device that is connected. Nil means stay quiet.
    func target(settings: Settings) -> OutputDevice? {
        refreshDevices()
        if let d = devices.first(where: { $0.id == defaultDeviceID }), isAllowed(d, settings: settings) { return d }
        return devices.first { isAllowed($0, settings: settings) && $0.transport != kAudioDeviceTransportTypeVirtual }
    }

    /// Starts the engine on `device`.
    func prepare(device: OutputDevice) throws {
        if device.id != currentDevice || !engine.isRunning {
            engine.stop()
            var id = device.id
            if let unit = engine.outputNode.audioUnit {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            currentDevice = device.id
            engine.prepare()
            try engine.start()
            Log.write("audio: playing on \(device.name) (\(device.kind))")
        }
    }

    func apply(speedStretch: Double, volume: Double) {
        stretch.rate = Float(max(0.5, min(speedStretch, 4)))
        // Up to 1 is plain volume; above it, boost up to +12 dB into the limiter.
        player.volume = Float(min(volume, 1))
        gain.globalGain = volume > 1 ? Float((volume - 1) * 12) : 0
    }

    /// `leadIn` seconds of silence first, so Bluetooth earbuds are awake before the first word.
    /// The playable buffer, and how far the speech moved in it (seconds) from
    /// trimming silence and adding the lead-in, so word timings can follow.
    func buffer(for audio: SpeechAudio, leadIn: Double = 0) -> (buffer: AVAudioPCMBuffer, shift: Double)? {
        var samples = audio.samples
        if audio.sampleRate != format.sampleRate {
            samples = Self.resample(samples, from: audio.sampleRate, to: format.sampleRate)
        }
        guard let kept = Self.speechBounds(samples, rate: format.sampleRate) else { return nil }
        samples = Array(samples[kept])
        var shift = -Double(kept.lowerBound) / format.sampleRate
        if leadIn > 0 {
            samples = [Float](repeating: 0, count: Int(format.sampleRate * leadIn)) + samples
            shift += leadIn
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return (buf, shift)
    }

    /// How long after the player renders a sample it is heard (Bluetooth adds a lot).
    var outputLatency: Double { engine.outputNode.presentationLatency }

    func shutdown() {
        player.stop()
        engine.stop()
        currentDevice = 0
    }

    /// Keeps ~100 ms before and ~140 ms after speech so fast reading stays tight
    /// without clipping soft first sounds (s, f, h).
    static func trimSilence(_ s: [Float], rate: Double, threshold: Float = 0.003) -> [Float] {
        speechBounds(s, rate: rate, threshold: threshold).map { Array(s[$0]) } ?? []
    }

    static func speechBounds(_ s: [Float], rate: Double, threshold: Float = 0.003) -> Range<Int>? {
        guard let first = s.firstIndex(where: { abs($0) > threshold }),
              let last = s.lastIndex(where: { abs($0) > threshold }) else { return nil }
        return max(0, first - Int(rate * 0.10))..<min(s.count, last + Int(rate * 0.14))
    }

    nonisolated static func resample(_ s: [Float], from: Double, to: Double) -> [Float] {
        guard let inF = AVAudioFormat(standardFormatWithSampleRate: from, channels: 1),
              let outF = AVAudioFormat(standardFormatWithSampleRate: to, channels: 1),
              let conv = AVAudioConverter(from: inF, to: outF),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(s.count)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: AVAudioFrameCount(Double(s.count) * to / from) + 1024)
        else { return s }
        inBuf.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        var fed = false
        conv.convert(to: outBuf, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}
