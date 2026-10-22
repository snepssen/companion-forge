@preconcurrency import AVFoundation
import Foundation
import ObjCExceptions

/// Samples the microphone has delivered, 16 kHz mono, shared between the audio
/// thread that appends and the loop that reads. (interpreter-forge's, as is.)
public final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var base = 0  // stream index of samples[0]
    private var rms: Float = 0
    public var level: Float { lock.withLock { rms } }

    public var count: Int { lock.withLock { base + samples.count } }

    public init() {}

    /// Handed each block as it arrives, on the audio thread: keep it quick.
    public var listener: (@Sendable ([Float]) -> Void)? {
        get { lock.withLock { heard } }
        set { lock.withLock { heard = newValue } }
    }
    private var heard: (@Sendable ([Float]) -> Void)?

    public func append(_ block: [Float]) {
        let rms = block.isEmpty ? 0 : (block.reduce(0) { $0 + $1 * $1 } / Float(block.count)).squareRoot()
        let listener = lock.withLock {
            samples += block
            self.rms = rms
            return heard
        }
        listener?(block)
    }

    /// Stream samples from `start` to `end`, whatever of them is still held.
    public func read(_ start: Int, _ end: Int) -> [Float] {
        lock.withLock {
            let lo = max(start, base) - base
            let hi = min(end, base + samples.count) - base
            return lo < hi ? Array(samples[lo..<hi]) : []
        }
    }

    /// Let go of everything before stream index `index`.
    public func drop(before index: Int) {
        lock.withLock {
            let n = min(max(0, index - base), samples.count)
            samples.removeFirst(n)
            base += n
        }
    }
}

public enum AudioFailure: LocalizedError {
    case noInput
    case noPermission
    public var errorDescription: String? {
        switch self {
        case .noInput: "The microphone isn't delivering audio."
        case .noPermission: "Companion can't hear you. Allow it in System Settings → Privacy & Security → Microphone."
        }
    }
}

/// AVAudioEngine raises NSException for misuse; this makes it a Swift error.
func objc(_ body: () -> Void) throws {
    var error: NSError?
    if !TCTry(body, &error), let error { throw error }
}

/// What the conversation loop listens through and speaks into: the
/// microphone and speakers, or a recording played in for measuring.
public protocol AudioIO: AnyObject, Sendable {
    var buffer: SampleBuffer { get }
    /// Queue a clip after whatever is queued; when it starts and ends, on `Duplex.now`'s clock.
    @discardableResult func play(_ samples: [Float]) -> (start: Double, end: Double)
    /// Stop talking at once, queued clips included.
    func silence()
    /// Seconds still to be said.
    var backlog: Double { get }
    /// What was played between two times on `Duplex.now`'s clock, at 16 kHz:
    /// the reference its echo is measured against.
    func reference(from start: Double, to end: Double) -> [Float]
    /// How loud the microphone's two sides were just now, when it has two.
    var balance: (left: Double, right: Double)? { get }
}

extension AudioIO {
    public var balance: (left: Double, right: Double)? { nil }
}

/// What was played, at 16 kHz, kept for a minute to measure echo against.
struct PlayedClips {
    private var clips: [(start: Double, samples: [Float], cut: Double)] = []

    mutating func add(_ samples: [Float], rate: Double, at start: Double) {
        clips.removeAll { $0.start < start - 60 }
        clips.append((start, resample(samples, from: rate), .infinity))
    }

    /// Everything after `time` is never heard.
    mutating func cut(at time: Double) {
        clips = clips.filter { $0.start <= time }.map { ($0.start, $0.samples, min($0.cut, time)) }
    }

    func reference(from start: Double, to end: Double) -> [Float] {
        let count = max(0, Int((end - start) * 16_000))
        var out = [Float](repeating: 0, count: count)
        for clip in clips where clip.start < end && clip.start + Double(clip.samples.count) / 16_000 > start {
            for index in 0..<count {
                let time = start + Double(index) / 16_000
                guard time < clip.cut else { break }
                let at = Int((time - clip.start) * 16_000)
                if at >= 0 && at < clip.samples.count { out[index] += clip.samples[at] }
            }
        }
        return out
    }
}

/// Linear resampling: enough for measuring a level, not for listening to.
func resample(_ samples: [Float], from rate: Double, to target: Double = 16_000) -> [Float] {
    guard rate != target, !samples.isEmpty else { return samples }
    let count = Int(Double(samples.count) * target / rate)
    return (0..<count).map { index in
        let position = Double(index) * rate / target
        let low = Int(position)
        let high = min(low + 1, samples.count - 1)
        let fraction = Float(position - Double(low))
        return samples[low] * (1 - fraction) + samples[high] * fraction
    }
}

/// Where the voice comes from.
///
/// Spatial, it is a point in front of the listener and a little below, where
/// a phone or tablet held at the chest is, rendered for whatever is playing
/// it. On headphones that track the head (AirPods, iOS 18 and macOS 15 on),
/// it stays there when they turn their head, so it sounds like the face
/// talking rather than a voice inside their ears. On speakers it is the same
/// voice it always was.
enum VoiceStage {
    /// Metres: right, up, and forward (forward is negative).
    static let place = AVAudio3DPoint(x: 0, y: -0.15, z: -0.45)

    static func connect(_ player: AVAudioPlayerNode, in engine: AVAudioEngine, format: AVAudioFormat, spatial: Bool) {
        engine.attach(player)
        guard spatial else {
            engine.connect(player, to: engine.mainMixerNode, format: format)
            return
        }
        let stage = AVAudioEnvironmentNode()
        engine.attach(stage)
        // Only a mono source is placed; the voice is mono.
        engine.connect(player, to: stage, format: format)
        let rate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        engine.connect(stage, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2))
        player.renderingAlgorithm = .auto
        player.sourceMode = .pointSource
        player.pointSourceInHeadMode = .mono
        player.position = place
        stage.outputType = .auto
        stage.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        // Closer than the reference distance: no fading with distance, no room.
        stage.distanceAttenuationParameters.referenceDistance = 1
        stage.reverbParameters.enable = false
        if #available(iOS 18.0, macOS 15.0, *) { stage.isListenerHeadTrackingEnabled = true }
    }
}

/// The microphone and the voice on one audio engine, so the companion can talk
/// out of the speakers without hearing itself.
///
/// Apple's echo canceller is voice processing on the engine's input node. It
/// subtracts what the engine's own output is playing, which is why the voice
/// has to go out through this engine and no other: played anywhere else, the
/// canceller has nothing to subtract and the companion hears its own words as
/// the person interrupting. What leaks through anyway is caught later, by the
/// turn taker's stricter bar for talking over a reply and by `Echo`.
public final class Duplex: AudioIO, @unchecked Sendable {
    public let buffer = SampleBuffer()
    public let echoCancelling: Bool
    public let spatial: Bool
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var tapped = false
    private let lock = NSLock()
    private var end = 0.0  // uptime the last scheduled clip finishes
    private var played = PlayedClips()
    private var sides: (left: Double, right: Double, at: Double)?
    private var levels: [Double] = []

    /// Whether Apple's echo canceller is used where it is asked for.
    #if os(macOS)
    static let appleCanceller = false
    #else
    static let appleCanceller = true
    #endif

    /// The clock clips are scheduled on, and the face is drawn on.
    public static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// `output`, on a Mac, plays through that device rather than the
    /// system's default: the echo canceller pairs the microphone with the
    /// output, and can't with a virtual one in between.
    public init(sampleRate: Double, echoCancellation: Bool = true, spatial: Bool = true, output: UInt32? = nil) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        echoCancelling = echoCancellation
        self.spatial = spatial
        #if os(macOS)
        if let output { try AudioDevicesInfo.use(output, on: engine.outputNode) }
        #endif
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        // Without the echo canceller, which hands over one channel, the
        // phone's front microphones can be had in stereo: where a voice comes
        // from, for the face to turn to. A preference; the route may refuse.
        if !echoCancellation { Self.preferStereo(session) }
        #endif
        // Apple's echo canceller on a Mac proved unusable (M1 MacBook Pro,
        // 2026-10-20): its microphone side delivered nothing at all, whatever
        // devices it was pointed at, except once, with a virtual output
        // device present. On a Mac the microphone is taken as it is, and the
        // loop's own guards keep its voice out: talking over a reply has to
        // be louder than its learned echo and not its own words, and the
        // first words of a turn are checked against the end of the last reply.
        if echoCancellation && Self.appleCanceller {
            // Before anything is connected: switching it on rebuilds both I/O units.
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // Left alone it turns every other app's sound down while it listens.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // The mixer must be wired to the voice-processing output in that
            // output's own format: left to connect itself, the output unit
            // fails to initialise on a Mac (-10875, found on an M1 MacBook Pro).
            let output = engine.outputNode.inputFormat(forBus: 0)
            try objc { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: output) }
        }
        try objc { VoiceStage.connect(player, in: engine, format: format, spatial: spatial) }
    }

    /// The microphone as the engine has it, for diagnosing.
    public var inputDescription: String {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return "\(format.channelCount) channel(s) at \(Int(format.sampleRate)) Hz"
    }

    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Before microphone access is granted the input has no format at all,
        // and a tap on it raises an exception rather than failing.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFailure.noInput }
        // Voice processing on a Mac hands over several channels (5 or 7,
        // each the same cleaned voice), and asked to downmix them the
        // converter gives silence. So the first channel alone is converted.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1,
                                       interleaved: false) else { throw AudioFailure.noInput }
        converter = AVAudioConverter(from: mono, to: target)
        guard converter != nil else { throw AudioFailure.noInput }
        do {
            try objc {
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcm, _ in
                    self?.receive(pcm)
                }
                tapped = true
                engine.prepare()
            }
            try engine.start()
            try objc { player.play() }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        player.stop()
        engine.stop()
        lock.withLock { end = Self.now }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Queue a clip after whatever is already queued; returns when it will
    /// start and end, on `now`'s clock.
    @discardableResult
    public func play(_ samples: [Float]) -> (start: Double, end: Double) {
        let now = Self.now
        guard !samples.isEmpty,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return (now, now) }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return lock.withLock {
            let start = max(now, end)
            end = start + Double(samples.count) / format.sampleRate
            player.scheduleBuffer(pcm)
            played.add(samples, rate: format.sampleRate, at: start)
            return (start, end)
        }
    }

    /// Stop talking at once, queued clips included.
    public func silence() {
        lock.withLock {
            player.stop()
            player.play()
            end = Self.now
            played.cut(at: end)
        }
    }

    public func reference(from start: Double, to end: Double) -> [Float] {
        lock.withLock { played.reference(from: start, to: end) }
    }

    /// Each input channel's level just now, for diagnosing.
    public var channelLevels: [Double] { lock.withLock { levels } }

    public var balance: (left: Double, right: Double)? {
        lock.withLock { sides.flatMap { Self.now - $0.at < 0.25 ? ($0.left, $0.right) : nil } }
    }

    #if os(iOS)
    static func preferStereo(_ session: AVAudioSession) {
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let front = builtIn.dataSources?.first(where: { $0.orientation == .front }),
              front.supportedPolarPatterns?.contains(.stereo) == true
        else { return }
        try? front.setPreferredPolarPattern(.stereo)
        try? builtIn.setPreferredDataSource(front)
        try? session.setPreferredInput(builtIn)
        // So left and right are the viewer's, held upright.
        try? session.setPreferredInputOrientation(.portrait)
    }
    #endif

    /// Seconds still to be said.
    public var backlog: Double { lock.withLock { max(0, end - Self.now) } }

    private func receive(_ pcm: AVAudioPCMBuffer) {
        guard let converter else { return }
        if let data = pcm.floatChannelData, pcm.frameLength > 0 {
            func level(_ channel: Int) -> Double {
                var sum: Float = 0
                for i in 0..<Int(pcm.frameLength) { sum += data[channel][i] * data[channel][i] }
                return Double((sum / Float(pcm.frameLength)).squareRoot())
            }
            let levels = (0..<Int(pcm.format.channelCount)).map(level)
            lock.withLock {
                self.levels = levels
                // Two sides only from a stereo microphone: the echo
                // canceller's extra channels are something else.
                if !echoCancelling && levels.count == 2 { sides = (levels[0], levels[1], Self.now) }
            }
        }
        // The first channel alone: the cleaned voice when the canceller is on.
        guard let data = pcm.floatChannelData,
              let first = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: pcm.frameLength)
        else { return }
        first.frameLength = pcm.frameLength
        first.floatChannelData![0].update(from: data[0], count: Int(pcm.frameLength))
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * 16_000 / pcm.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return first
        }
        guard error == nil, let converted = out.floatChannelData else { return }
        buffer.append(Array(UnsafeBufferPointer(start: converted[0], count: Int(out.frameLength))))
    }

    /// Ask for the microphone, if it hasn't been asked for yet.
    public static func permission() async -> Bool {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #else
        return await AVAudioApplication.requestRecordPermission()
        #endif
    }
}

/// Something said out loud while nobody is talking with it: the voice alone,
/// no microphone and no echo canceller. Kept until it has been said.
public final class Blurt: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    public let start: Double
    public let end: Double

    public init(_ samples: [Float], rate: Double, spatial: Bool = true, volume: Float = 1) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        guard !samples.isEmpty, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw AudioFailure.noInput }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let (engine, player) = (AVAudioEngine(), AVAudioPlayerNode())
        try objc {
            VoiceStage.connect(player, in: engine, format: format, spatial: spatial)
            engine.mainMixerNode.outputVolume = volume
            engine.prepare()
        }
        try engine.start()
        try objc {
            player.scheduleBuffer(pcm)
            player.play()
        }
        self.engine = engine
        self.player = player
        start = Duplex.now
        end = start + Double(samples.count) / rate
    }

    public func stop() {
        player.stop()
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

#if os(macOS)
import CoreAudio

/// The system's audio devices, by name.
public enum AudioDevicesInfo {
    public struct Device: Sendable {
        public let id: AudioDeviceID
        public let name: String
        /// Built into the Mac, as opposed to virtual, USB or Bluetooth.
        public let builtIn: Bool
        public let outputs: Int
        public let inputs: Int
    }

    public static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            Device(id: id, name: name(id), builtIn: transport(id) == kAudioDeviceTransportTypeBuiltIn,
                   outputs: channels(id, kAudioObjectPropertyScopeOutput), inputs: channels(id, kAudioObjectPropertyScopeInput))
        }
    }

    static func use(_ id: AudioDeviceID, on node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { return }
        var id = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func name(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    /// The system's default devices, by name, for diagnosing.
    public static func defaults() -> (input: String, output: String) {
        (name(of: kAudioHardwarePropertyDefaultInputDevice), name(of: kAudioHardwarePropertyDefaultOutputDevice))
    }

    static func name(of selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return "?" }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }
}
#endif
