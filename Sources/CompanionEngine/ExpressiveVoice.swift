import CompanionCore
import Foundation
import VoiceForgeCore
import VoiceForgeTTS

/// English through voice-forge's engine and its snepssen voice, which can be
/// told how long each sound lasts: its automatic reading (the point of each
/// phrase held and lifted, unstressed words giving way, a phrase settling at
/// its edge) and its lift, the one intonation control the voice answers to
/// natively, by its stress marks.
///
/// Pitch bent after the fact was tried in voice-forge five times and rejected
/// every time ("riding an oscillating wave"), and again here on this voice
/// (2026-10-21: a raised question ending, both by pitch marks and by a
/// varispeed glide, was inaudible: the voice is too breathy to carry a
/// melody, and fades at a sentence's end). So a question or an
/// exclamation is asked of the voice itself: a question is read lifted, with
/// a little more held at its end; an exclamation with full focus and accent.
public final class ExpressiveVoice: @unchecked Sendable {
    private let engine: VoiceEngine
    public var sampleRate: Double { engine.sampleRate }

    /// voice-forge's bundled voice, or the one at `model` (with its config
    /// beside it as `.onnx.json`). nil unless it can be told its timing.
    public init?(model: URL? = nil) {
        let profile = model.map {
            VoiceProfile(name: $0.deletingPathExtension().lastPathComponent, modelURL: $0,
                         configURL: $0.appendingPathExtension("json"), isBundled: false)
        } ?? VoiceEngine.bundledProfiles().first
        guard let profile, let engine = try? VoiceEngine(profile: profile), engine.directsTiming
        else { return nil }
        self.engine = engine
    }

    /// The reading for each kind of sentence.
    static func prosody(_ delivery: Delivery) -> ProsodySettings {
        switch delivery {
        case .statement:
            ProsodySettings()
        case .question:
            ProsodySettings(focus: 0.8, phraseFinal: 0.35, deaccentRepeats: 0.6, contrast: 0.2, nucleusHold: 0.15,
                            lift: 0.6)
        case .exclamation:
            ProsodySettings(focus: 1, phraseFinal: 0.1, deaccentRepeats: 0.4, contrast: 0.5, nucleusHold: 0.1,
                            accentDB: 6, lift: 1)
        }
    }

    /// Samples and the mouth, timed by the voice's own frames.
    func render(_ text: String, delivery: Delivery) throws -> (samples: [Float], mouth: [VisemeSpan]?) {
        let settings = SynthesisSettings()
        let prosody = Self.prosody(delivery)
        let directions = engine.reading(for: text, settings: settings, prosody: prosody)
        let (samples, layout, frames) = try engine.renderTimed(text, settings: settings, directions: directions,
                                                               lift: prosody.lift)
        let symbols = layout.slots.map { $0.symbol.first ?? "_" }
        let mouth = frames.isEmpty ? nil
            : Phonemes.spans(symbols, frames: frames, seconds: Double(samples.count) / engine.sampleRate)
        return (samples, mouth)
    }
}
