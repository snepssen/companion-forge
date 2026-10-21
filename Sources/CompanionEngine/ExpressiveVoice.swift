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
/// every time ("riding an oscillating wave"), so a question or an
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
    /// One reading of a sentence: its samples, mouth shapes, and where a
    /// question's rise would go.
    public struct Take: Sendable {
        public var samples: [Float]
        public var mouth: [VisemeSpan]?
        public var rising: (runs: [Rise.Run], from: Int, to: Int)?
        let rate: Double

        /// The same samples with the rise raised by `semitones` (`Rise`);
        /// unchanged where there is nowhere for it to go.
        public func raised(by semitones: Double) -> [Float] {
            guard let rising, semitones != 0 else { return samples }
            return Rise.apply(samples, runs: rising.runs, from: rising.from, to: rising.to, semitones: semitones, rate: rate)
        }

        /// The same samples with the stretch from the last stressed vowel to
        /// the last voiced sound glided up by `semitones` (`Rise.glide`).
        public func glided(by semitones: Double) -> [Float] {
            guard let rising, semitones != 0 else { return samples }
            return Rise.glide(samples, from: rising.from, to: rising.to, semitones: semitones)
        }
    }

    /// The voice's reading for the kind of sentence. `rising` is set for a
    /// yes-or-no question only.
    public func take(_ text: String, delivery: Delivery, readAs: String? = nil) throws -> Take {
        let settings = SynthesisSettings()
        let prosody = Self.prosody(delivery)
        let read = readAs ?? text
        let directions = engine.reading(for: read, settings: settings, prosody: prosody)
        let (samples, layout, frames) = try engine.renderTimed(read, settings: settings, directions: directions, lift: prosody.lift)
        let symbols = layout.slots.map { $0.symbol.first ?? "_" }
        let mouth = frames.isEmpty ? nil : Phonemes.spans(symbols, frames: frames, seconds: Double(samples.count) / engine.sampleRate)
        let rising = delivery == .question && Delivery.rises(text) ? Self.risingRuns(layout, frames: frames, samples: samples.count) : nil
        return Take(samples: samples, mouth: mouth, rising: rising, rate: engine.sampleRate)
    }

    /// Samples and mouth shapes, a yes-or-no question's ending raised by `rise` semitones.
    public func render(_ text: String, delivery: Delivery, rise: Double = 0) throws -> (samples: [Float], mouth: [VisemeSpan]?) {
        let take = try take(text, delivery: delivery)
        return (take.raised(by: rise), take.mouth)
    }

    /// Where a question's rise goes, from the voice's own durations: from the
    /// nucleus of the last word it stressed (or the last word with a vowel)
    /// to the end of the last voiced sound, shifting only the vowel and
    /// sonorant runs between. A blank token belongs to the sound it trails.
    static func risingRuns(_ layout: TokenLayout, frames: [Float], samples: Int) -> (runs: [Rise.Run], from: Int, to: Int)? {
        guard frames.count == layout.slots.count, samples > 0 else { return nil }
        let total = frames.reduce(0) { $0 + Double($1) }
        guard total > 0 else { return nil }
        let hop = Double(samples) / total
        var edges = [0]
        for f in frames { edges.append(edges[edges.count - 1] + Int(Double(f) * hop)) }

        let spoken = layout.slots.filter { $0.word >= 0 && $0.kind == .symbol }
        let stressed = Set(spoken.filter { $0.symbol == String(Phonology.primaryStress) }.map(\.word))
        let voweled = Set(spoken.filter { Phonology.isVowelish($0.symbol) }.map(\.word))
        guard let word = stressed.intersection(voweled).max() ?? voweled.max(),
              let first = TimingPlan.nucleus(layout, word: word).first else { return nil }

        func voiced(_ slot: TokenSlot) -> Bool {
            guard slot.kind == .symbol || slot.kind == .blank else { return false }
            let kind = Phonology.phonemeClass(slot.symbol)
            return kind == .vowel || kind == .vowelExtension || kind == .sonorant
        }
        var runs: [Rise.Run] = []
        var open: (start: Int, guarded: Bool)?
        var previous: PhonemeClass = .boundary
        for (i, slot) in layout.slots.enumerated() where i >= first.index {
            let kind = Phonology.phonemeClass(slot.symbol)
            if kind == .marker { continue }  // a stress mark between sounds
            if voiced(slot) {
                if open == nil {
                    open = (edges[i], [.plosive, .voicelessFricative, .voicedFricative].contains(previous))
                }
            } else if let o = open {
                runs.append(Rise.Run(start: o.start, end: edges[i], guarded: o.guarded))
                open = nil
            }
            if slot.kind == .symbol, slot.symbol != " " { previous = kind }
        }
        if let o = open { runs.append(Rise.Run(start: o.start, end: edges[layout.slots.count], guarded: o.guarded)) }
        runs = runs.filter { $0.end > $0.start }
        guard let last = runs.last else { return nil }
        return (runs, edges[first.index], last.end)
    }
}
