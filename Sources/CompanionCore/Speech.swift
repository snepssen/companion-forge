import Foundation

/// A reply as it streams from the model, cut into sentences the voice can say
/// while the rest is still being written. The first sentence is what the
/// listener waits for, so it is let go as soon as it is whole.
public struct SentenceSplitter: Sendable {
    private var pending = ""
    /// Fewer words than this wait for the next sentence: "Oh." alone is a
    /// clip too short to be worth its own synthesis call.
    static let fewestWords = 3

    public init() {}

    /// Add streamed text; returns whatever sentences it completed.
    public mutating func feed(_ text: String) -> [String] {
        pending += text
        var out: [String] = []
        while let end = Self.boundary(in: pending) {
            out.append(String(pending[..<end]))
            pending = String(pending[end...])
        }
        return out.map(Speakable.clean).filter { !$0.isEmpty }
    }

    /// Whatever is left once the model has finished.
    public mutating func finish() -> [String] {
        let rest = Speakable.clean(pending)
        pending = ""
        return rest.isEmpty ? [] : [rest]
    }

    /// The end of the first sentence of at least `fewestWords` words that is
    /// followed by whitespace, or of a line.
    static func boundary(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" {
                return next
            }
            if ".!?…".contains(character), next < text.endIndex, text[next].isWhitespace,
               words(String(text[..<next])) >= fewestWords {
                return next
            }
            index = next
        }
        return nil
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// What a voice should be given: no markdown, no emoji, no list markers.
public enum Speakable {
    public static func clean(_ text: String) -> String {
        var out = text
        out = out.replacing(/\*{1,2}([^*\n]+)\*{1,2}/) { String($0.1) }
        out = out.replacing(/`([^`\n]+)`/) { String($0.1) }
        out = out.replacing(/(?m)^\s*(?:[-*•]|\d+[.)])\s+/) { _ in "" }
        out = out.replacing(/(?m)^#+\s*/) { _ in "" }
        out = String(String.UnicodeScalarView(out.unicodeScalars.filter { !isPictograph($0) }))
        out = out.replacing(/\s+/) { _ in " " }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Emoji and the symbols models use as emoji. Digits, `#` and `*` are
    /// emoji too, by Unicode's reckoning, which is why this isn't `isEmoji`.
    static func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmojiPresentation || scalar.value >= 0x1F000
            || (0x2600...0x27BF).contains(scalar.value) || scalar.value == 0xFE0F || scalar.value == 0x200D
    }
}

/// Whether speech heard over the reply is the reply itself, come back through
/// the speakers and past the echo canceller.
///
/// The canceller removes most of it; what gets through is quiet, and if it is
/// loud enough to be transcribed at all, it is transcribed as the words being
/// said. Someone interrupting says something else.
public enum Echo {
    /// Heard words that are in what is being said, as a share of all heard.
    static let overlap = 0.6

    public static func isEcho(heard: String, saying: String) -> Bool {
        let heardWords = words(heard)
        // Nothing intelligible over the reply: leftover echo, a breath, the room.
        guard !heardWords.isEmpty else { return true }
        let said = Set(words(saying))
        guard !said.isEmpty else { return false }
        let shared = heardWords.filter(said.contains).count
        return Double(shared) / Double(heardWords.count) >= overlap
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }
}

/// How loud the reply comes back into the microphone, learned while it talks,
/// and so whether sound over it is louder than its own echo could be.
///
/// The words alone can't settle it: a third of a second of quiet echo is as
/// likely to be transcribed as "Acts." as it is as the words being said. But
/// the companion knows exactly what it played. Whatever share of that comes
/// back through the canceller, quarter-second by quarter-second, is how loud its
/// echo is in this room on this device; someone talking over it is several
/// times louder than that.
public struct EchoLevel: Sendable {
    static let window = 4_000  // a quarter of a second at 16 kHz
    /// Below this the reply is between words, and the ratio is all room noise.
    static let audible = 0.01
    static let kept = 120
    /// A second of audible reply.
    static let enough = 4
    /// How much louder than its echo a person must be: 6 dB. Its own echo
    /// measures 0.9-1.1 times the learned level; people talking over it 2.3
    /// times and up when the canceller lets a lot through (ccrun --echo 0.3),
    /// 17 times when it doesn't (--echo 0.05).
    static let margin = 2.0

    private var ratios: [Double] = []
    private var mic = 0.0
    private var played = 0.0
    private var count = 0

    public init() {}

    /// What came back into the microphone, as a share of what was played. The
    /// median of the last half-minute's worth: an interruption or two, which
    /// are louder, barely move it.
    public var leak: Double? {
        guard ratios.count >= Self.enough else { return nil }
        let sorted = ratios.sorted()
        return sorted[sorted.count / 2]
    }

    /// A frame heard while the reply was playing, and what was played then.
    public mutating func hear(mic: [Float], played: [Float]) {
        mic.forEach { self.mic += Double($0 * $0) }
        played.forEach { self.played += Double($0 * $0) }
        count += mic.count
        guard count >= Self.window else { return }
        let (micLevel, playedLevel) = ((self.mic / Double(count)).squareRoot(), (self.played / Double(count)).squareRoot())
        if playedLevel > Self.audible {
            ratios.append(micLevel / playedLevel)
            if ratios.count > Self.kept { ratios.removeFirst(ratios.count - Self.kept) }
        }
        (self.mic, self.played, count) = (0, 0, 0)
    }

    /// Whether `mic` is no louder than the echo of `played`; nil until the
    /// leak has been learned, or when nothing audible was playing.
    public func isEcho(mic: [Float], played: [Float]) -> Bool? {
        guard let leak, Self.level(played) > Self.audible else { return nil }
        return Self.level(mic) <= leak * Self.level(played) * Self.margin
    }

    public static func level(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
    }
}
