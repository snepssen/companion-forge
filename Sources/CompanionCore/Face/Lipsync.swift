import Foundation

/// One mouth shape, held from `start` to `end` seconds into a clip.
public struct VisemeSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var viseme: Viseme

    public init(_ start: Double, _ end: Double, _ viseme: Viseme) {
        self.start = start
        self.end = end
        self.viseme = viseme
    }
}

/// The mouth from what the voice actually said: the IPA the voice was given
/// and how many frames it spent on each symbol, rather than spelling shared
/// out by guess. The polyglot voice's export does not report those frames
/// (`/Ceil_output_0` where a graph kept them), so each symbol's share of the
/// clip is estimated.
public enum Phonemes {
    /// What the mouth shows of one IPA symbol; nil for what it doesn't
    /// (t, d, k, g, n, h, stress marks, pauses), which ride on the vowels
    /// either side as the mouth glides between them.
    public static func viseme(_ symbol: Character) -> Viseme? {
        switch symbol {
        case "a", "ɑ", "æ", "ʌ", "ɐ", "ä": .ah
        case "e", "ɛ", "ə", "ɚ", "ɜ", "ɝ", "ᵻ": .eh
        case "i", "ɪ", "y", "j", "ɨ", "ʏ": .ee
        case "o", "ɔ", "ɒ", "ø", "œ", "ɵ": .oh
        case "u", "ʊ", "ɯ", "w", "ʃ", "ʒ", "ɹ", "r", "ʁ": .oo
        case "m", "b", "p": .mm
        case "f", "v": .ff
        case "θ", "ð", "s", "z": .th
        case "l", "ɫ": .ll
        default: nil
        }
    }

    /// The symbol each id stands for, in Piper's plain layout: `^`, a pad,
    /// each known symbol and a pad, then `$` (voice-core's `PiperModel.ids`).
    /// `ids(symbol)` is how many ids a symbol has, 0 for unknown ones.
    /// Walked scalar by scalar, as `PiperModel.ids` walks it: a combining
    /// mark is a symbol of its own there.
    public static func layout(_ phonemes: String, ids: (Character) -> Int) -> [Character] {
        var symbols: [Character] = ["^", "_"]
        for scalar in phonemes.unicodeScalars {
            let symbol = Character(scalar)
            let count = ids(symbol)
            if count > 0 { symbols += Array(repeating: symbol, count: count) + ["_"] }
        }
        return symbols + ["$"]
    }

    /// The polyglot voice's layout: each sentence its own `^`, symbols and
    /// pads, `$`, chained (voice-core's `Polyphon.ids`).
    public static func layout(sentences: [[Unicode.Scalar]], ids: (Character) -> Int) -> [Character] {
        sentences.flatMap { sentence -> [Character] in
            var symbols: [Character] = ["^", "_"]
            for scalar in sentence {
                let symbol = Character(scalar)
                let count = ids(symbol)
                if count > 0 { symbols += Array(repeating: symbol, count: count) + ["_"] }
            }
            return symbols + ["$"]
        }
    }

    /// Frames each symbol probably took, for a voice that doesn't report
    /// them (the polyglot snepssen's export doesn't): vowels longest, a pause
    /// at punctuation, a little between words. The shapes are right; their
    /// timing is an estimate, shared out over the clip.
    public static func estimatedFrames(_ symbols: [Character]) -> [Float] {
        symbols.map { symbol in
            switch symbol {
            case "^", "$": 1
            case "_": 0.3
            case " ": 1.5
            case ",", ";", ":": 4
            case ".", "!", "?": 6
            default:
                switch viseme(symbol) {
                case .ah?, .eh?, .ee?, .oh?: 2.2
                case nil: symbol.isLetter ? 1 : 0.2
                default: 1
                }
            }
        }
    }

    /// Spans of mouth shapes from the symbols and the frames each one took.
    /// A pad belongs to the symbol before it; a shape repeated is one span.
    /// nil if the frames don't line up with the symbols.
    public static func spans(_ symbols: [Character], frames: [Float], seconds: Double) -> [VisemeSpan]? {
        guard symbols.count == frames.count, seconds > 0 else { return nil }
        let total = frames.reduce(0) { $0 + Double($1) }
        guard total > 0 else { return nil }
        let frame = seconds / total
        var spans: [VisemeSpan] = []
        var time = 0.0
        var current: Viseme?
        for (symbol, count) in zip(symbols, frames) {
            let length = Double(count) * frame
            defer { time += length }
            if symbol == "_" {
                // The pad after a symbol sounds as that symbol.
                if current != nil, let last = spans.indices.last { spans[last].end += length }
                continue
            }
            current = viseme(symbol)
            guard let shape = current else { continue }
            if let last = spans.indices.last, spans[last].viseme == shape, abs(spans[last].end - time) < 1e-9 {
                spans[last].end += length
            } else {
                spans.append(VisemeSpan(time, time + length, shape))
            }
        }
        return spans
    }
}
