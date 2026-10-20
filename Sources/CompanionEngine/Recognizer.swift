import FluidAudio
import Foundation

/// Parakeet Ultra through FluidAudio, as translate-core hears with it: the
/// Neural Engine, 25 European languages, punctuated. A turn is transcribed
/// whole, once, when the person pauses; turns are short and Parakeet is fast,
/// so there is nothing to gain from re-reading a moving window.
public actor Recognizer {
    private let manager: AsrManager

    public static func load(progress: (@Sendable (Double) -> Void)? = nil) async throws -> Recognizer {
        var handler: ProgressHandler?
        if let progress { handler = { progress($0.fractionCompleted) } }
        let directory = try await AsrModels.download(version: .ultra, progressHandler: handler)
        progress?(1)
        let models = try await AsrModels.load(from: directory, version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return Recognizer(manager: manager)
    }

    private init(manager: AsrManager) { self.manager = manager }

    /// What was said in `samples` (16 kHz mono); empty for nothing intelligible.
    public func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard samples.count >= 16_000 * 3 / 10 else { return "" }  // FluidAudio's minimum
        var state = TdtDecoderState.make()
        // English expected: left to guess, Parakeet wrote the name "Lin" in
        // Cyrillic once ("Лин"). The hint keeps it to the right alphabet.
        let result = try await manager.transcribe(samples, decoderState: &state, language: .english)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
