import Foundation
import OnnxRuntimeBindings
import VoiceCore

/// Silero VAD v5 on 32 ms frames, with hysteresis on its speech probability.
/// translate-core's, with the probability kept: talking over a reply takes a
/// surer voice than talking into silence. Each frame goes in with the last 64
/// samples of the one before, which the v5 graph expects.
public final class SileroVAD: @unchecked Sendable {
    public static let frame = 512  // samples at 16 kHz
    static let context = 64

    private let session: ORTSession
    private var state = [Float](repeating: 0, count: 2 * 1 * 128)
    private var previous = [Float](repeating: 0, count: context)
    private let on: Float
    private let off: Float
    public private(set) var speaking = false
    /// The last frame's speech probability.
    public private(set) var probability: Float = 0
    public private(set) var lastSpeech = -1e9  // stream time of the last frame heard as speech
    private nonisolated(unsafe) static let env = try? ORTEnv(loggingLevel: .warning)

    public init(model: URL, on: Float = 0.5, off: Float = 0.35) throws {
        guard let env = Self.env else { throw PiperModel.Failure.noRuntime }
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(env: env, modelPath: model.path, sessionOptions: options)
        self.on = on
        self.off = off
    }

    public func reset() {
        state = [Float](repeating: 0, count: 256)
        previous = [Float](repeating: 0, count: Self.context)
        speaking = false
        probability = 0
        lastSpeech = -1e9
    }

    /// Feed one frame ending at stream time `t`; returns whether it is speech.
    @discardableResult
    public func push(_ frame: ArraySlice<Float>, at t: Double) throws -> Bool {
        var input = previous + frame
        var sr = Int64(16_000)
        let inputs = [
            "input": try ORTValue(tensorData: NSMutableData(bytes: &input, length: input.count * 4),
                                  elementType: .float, shape: [1, NSNumber(value: input.count)]),
            "state": try ORTValue(tensorData: NSMutableData(bytes: &state, length: state.count * 4),
                                  elementType: .float, shape: [2, 1, 128]),
            "sr": try ORTValue(tensorData: NSMutableData(bytes: &sr, length: 8), elementType: .int64, shape: []),
        ]
        let outputs = try session.run(withInputs: inputs, outputNames: ["output", "stateN"], runOptions: nil)
        let p = try floats(outputs["output"]).first ?? 0
        probability = p
        state = try floats(outputs["stateN"])
        previous = Array(input.suffix(Self.context))
        speaking = p >= on || (speaking && p >= off)
        if speaking { lastSpeech = t }
        return speaking
    }

    public func silence(at now: Double) -> Double { speaking ? 0 : max(0, now - lastSpeech) }

    private func floats(_ value: ORTValue?) throws -> [Float] {
        guard let data = try value?.tensorData() as Data? else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
