import CompanionCore
import Foundation
import VoiceCore

/// A Piper voice on voice-core's engine: translate-core's, as is, for now
/// speaking English. The polyglot voice works too, if it is the one found.
///
/// Leaner than Voice Forge's `VoiceEngine`, whose expression and timing layer
/// is that app's subject and not this one's: Piper's plain id layout (`^`,
/// each phoneme and a blank, `$`), and for a Voice Forge voice its duration
/// input fed ones, which reproduces the stock voice exactly (`PiperModel`).
/// `pace` divides the length scale: the graph rounds each phoneme up to a
/// whole frame, so it delivers about half of a small request (x1.1 gives
/// x1.05) and most of a large one (x1.4 gives x1.35), as measured in Python.
///
/// A polyglot voice (voice-polyglot; its config carries a "polyglot" block)
/// speaks `language`: text goes through `Polyphon`, the corrected espeak-ng it
/// was trained through, one `^`...`$` run per sentence as in its training
/// data, and each language at its own length scale. Its Suno-made languages
/// were read faster than its English, and the scales, picked by ear, even
/// them out.
public final class Voice: @unchecked Sendable {
    public let sampleRate: Double
    private let model: PiperModel
    private let espeakData: URL
    /// One espeak-ng voice per name, made on first use. Under `lock`.
    private var phonemizers: [String: EspeakPhonemizer] = [:]
    private var speaking = "en"
    private let lock = NSLock()  // one ONNX run and one espeak call at a time

    public init(model: URL, espeakData: URL) throws {
        self.model = try PiperModel(model: model)
        self.espeakData = espeakData
        sampleRate = self.model.sampleRate
        _ = try phonemizer(self.model.config.espeak.voice)
    }

    /// The languages it was trained on: a polyglot voice's eight, else English.
    public var languages: [String] { model.config.polyglot?.languages ?? ["en"] }
    public var isPolyglot: Bool { model.config.polyglot != nil }

    /// What `speak` speaks. A language outside `languages` is read through
    /// plain espeak-ng, if espeak-ng has it: untrained, and it sounds it.
    public var language: String {
        get { lock.withLock { speaking } }
        set { lock.withLock { speaking = newValue } }
    }

    /// Mono samples at `sampleRate`, peak-normalised to 0.9.
    public func speak(_ text: String, pace: Double = 1) throws -> [Float] {
        try speakTimed(text, pace: pace).samples
    }

    /// The graph's own rounded duration of each id, in frames, where the
    /// export kept it (voice-forge's voices do; the name is the exporter's).
    static let framesOutput = "/Ceil_output_0"

    /// Samples, and the mouth shapes timed by how long the voice actually
    /// spent on each phoneme. The mouth is nil for the polyglot voice, whose
    /// layout differs, and for a graph without durations: the face then times
    /// the words by their spelling.
    public func speakTimed(_ text: String, pace: Double = 1) throws -> (samples: [Float], mouth: [VisemeSpan]?) {
        lock.lock()
        defer { lock.unlock() }
        let inference = model.config.inference
        var scale = inference.length_scale
        let ids: [Int]
        var symbols: [Character]?
        if let polyglot = model.config.polyglot {
            ids = try polyglotIDs(text, speaking)
            scale *= polyglot.length_scale?[speaking] ?? 1
        } else {
            let phonemes = try phonemizer(model.config.espeak.voice).phonemize(text)
            ids = model.ids(phonemes)
            let map = model.config.phoneme_id_map
            symbols = Phonemes.layout(phonemes) { map[String($0)]?.count ?? 0 }
        }
        guard ids.count > 3 else { return ([], nil) }
        let result = try model.infer(ids, noiseScale: inference.noise_scale, lengthScale: scale / pace,
                                     noiseW: inference.noise_w, extraOutputs: [Self.framesOutput])
        var samples = result.samples
        if let peak = samples.map(abs).max(), peak > 1e-8 {
            let gain = 0.9 / peak
            for i in samples.indices { samples[i] *= gain }
        }
        let mouth = symbols.flatMap { symbols in
            result.extra[Self.framesOutput].flatMap {
                Phonemes.spans(symbols, frames: $0, seconds: Double(samples.count) / sampleRate)
            }
        }
        return (samples, mouth)
    }

    /// Polyphon's ids for `text` in `language`, without speaking it.
    func polyglotIDs(_ text: String, language: String) throws -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return try polyglotIDs(text, language)
    }

    /// Under `lock`.
    private func polyglotIDs(_ text: String, _ language: String) throws -> [Int] {
        let espeak = try phonemizer(Polyphon.espeakVoice(language))
        return Polyphon.ids(try Polyphon.sentences(text, language: language, espeak: espeak),
                            map: model.config.phoneme_id_map)
    }

    /// Under `lock`, or from `init`.
    private func phonemizer(_ espeakVoice: String) throws -> EspeakPhonemizer {
        if let made = phonemizers[espeakVoice] { return made }
        let made = try EspeakPhonemizer(dataDirectory: espeakData, voice: espeakVoice)
        phonemizers[espeakVoice] = made
        return made
    }
}
