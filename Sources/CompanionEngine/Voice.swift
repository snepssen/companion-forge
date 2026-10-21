import CompanionCore
import Foundation
import NaturalLanguage
import VoiceCore

/// A Piper voice on voice-core's engine, from translate-core: the polyglot
/// snepssen where it is found, so it can say words in other languages, else
/// voice-forge's English one.
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
    /// English with voice-forge's reading and lift, where its voice is here.
    private let expressive: ExpressiveVoice?

    public init(model: URL, espeakData: URL) throws {
        self.model = try PiperModel(model: model)
        self.espeakData = espeakData
        sampleRate = self.model.sampleRate
        let expressive = ExpressiveVoice()
        self.expressive = expressive?.sampleRate == sampleRate ? expressive : nil
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

    /// Samples, and the mouth shapes for the phonemes said: timed by how long
    /// the voice spent on each where the graph reports it, estimated where
    /// it doesn't (the polyglot voice).
    ///
    /// The polyglot voice speaks each part of a sentence in its own language:
    /// a quoted word in the language `hint` names ("how do I say breakfast in
    /// Romanian?") or that Apple's detector is sure of, and a whole sentence
    /// in another language in that language. The parts are spoken one by one
    /// and joined. Languages it wasn't trained on go through plain espeak-ng,
    /// accent and all.
    public func speakTimed(_ text: String, hint: String? = nil, pace: Double = 1)
        throws -> (samples: [Float], mouth: [VisemeSpan]?) {
        lock.lock()
        defer { lock.unlock() }
        let parts = isPolyglot ? self.parts(text, hint: hint) : [(text, "en")]
        var samples: [Float] = []
        var mouth: [VisemeSpan]? = []
        for (index, (part, language)) in parts.enumerated() {
            // English through voice-forge's reading: the sentence's own kind for
            // the part it ends with, a plain reading for the parts before.
            let delivery = index == parts.count - 1 ? Delivery.of(text) : .statement
            let (said, shapes) = language == "en" && pace == 1 && expressive != nil
                ? try expressive!.render(part, delivery: delivery)
                : try infer(part, language: language, pace: pace)
            let offset = Double(samples.count) / sampleRate
            mouth = shapes.flatMap { shapes in mouth.map { $0 + shapes.map { VisemeSpan($0.start + offset, $0.end + offset, $0.viseme) } } }
            samples += said
        }
        if let peak = samples.map(abs).max(), peak > 1e-8 {
            let gain = 0.9 / peak
            for i in samples.indices { samples[i] *= gain }
        }
        return (samples, samples.isEmpty ? nil : mouth)
    }

    /// One part in one language, unnormalised. Under `lock`.
    private func infer(_ text: String, language: String, pace: Double) throws -> (samples: [Float], mouth: [VisemeSpan]?) {
        let inference = model.config.inference
        var scale = inference.length_scale
        let ids: [Int]
        let symbols: [Character]
        let map = model.config.phoneme_id_map
        if let polyglot = model.config.polyglot {
            let sentences = try Polyphon.sentences(text, language: language,
                                                   espeak: phonemizer(Polyphon.espeakVoice(language)))
            ids = Polyphon.ids(sentences, map: map)
            symbols = Phonemes.layout(sentences: sentences) { map[String($0)]?.count ?? 0 }
            // Its trained languages at their own pace; the rest a little slower than English.
            scale *= polyglot.length_scale?[language] ?? (language == "en" ? 1 : 1.2)
        } else {
            let phonemes = try phonemizer(model.config.espeak.voice).phonemize(text)
            ids = model.ids(phonemes)
            symbols = Phonemes.layout(phonemes) { map[String($0)]?.count ?? 0 }
        }
        guard ids.count > 3 else { return ([], []) }
        let result = try model.infer(ids, noiseScale: inference.noise_scale, lengthScale: scale / pace,
                                     noiseW: inference.noise_w, extraOutputs: [Self.framesOutput])
        // The graph's own durations where it reports them; otherwise an estimate.
        let frames = result.extra[Self.framesOutput] ?? Phonemes.estimatedFrames(symbols)
        return (result.samples, Phonemes.spans(symbols, frames: frames, seconds: Double(result.samples.count) / sampleRate))
    }

    /// A sentence's parts and the language of each, neighbours in the same
    /// language joined.
    public func parts(_ text: String, hint: String?) -> [(String, String)] {
        var parts: [(String, String)] = []
        var near = hint
        for segment in Languages.segments(text) {
            // A language named just before a quote ("…in Hungarian is
            // 'köszönöm'") says more about it than the question did.
            if !segment.quoted, let named = Languages.named(in: segment.text) { near = named }
            let language = segment.quoted ? quotedLanguage(segment.text, hint: near) : sentenceLanguage(segment.text)
            if let last = parts.last, last.1 == language {
                parts[parts.count - 1].0 += " " + segment.text
            } else {
                parts.append((segment.text, language))
            }
        }
        return parts.isEmpty ? [(text, "en")] : parts
    }

    /// A quoted word or phrase: the language they asked about, unless the
    /// detector is sure it's something else; English if nothing says otherwise.
    func quotedLanguage(_ text: String, hint: String?) -> String {
        let guesses = Self.guesses(text, hint: hint)
        if let hint, available(hint), guesses[hint, default: 0] >= 0.15 || guesses.isEmpty { return hint }
        if let best = guesses.max(by: { $0.value < $1.value }), best.value >= 0.6, available(best.key) { return best.key }
        return hint.flatMap { available($0) ? $0 : nil } ?? "en"
    }

    /// A whole stretch of sentence: another language only when it is plainly
    /// one, several words long; otherwise English.
    func sentenceLanguage(_ text: String) -> String {
        guard text.split(separator: " ").count >= 3,
              let best = Self.guesses(text, hint: nil).max(by: { $0.value < $1.value }),
              best.value >= 0.85, available(best.key)
        else { return "en" }
        return best.key
    }

    /// Apple's on-device language detector, as espeak-ng's voice names.
    static func guesses(_ text: String, hint: String?) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        if let hint { recognizer.languageHints = [NLLanguage(rawValue: hint): 0.7] }
        recognizer.processString(text)
        var out: [String: Double] = [:]
        for (language, probability) in recognizer.languageHypotheses(withMaximum: 5) {
            let code = language.rawValue.hasPrefix("zh") ? "cmn" : String(language.rawValue.prefix(2))
            out[code, default: 0] += probability
        }
        return out
    }

    /// Whether espeak-ng can read it.
    func available(_ language: String) -> Bool {
        language == "en" || FileManager.default.fileExists(atPath: espeakData.appending(path: "\(language == "cmn" ? "cmn" : language)_dict").path)
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
