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

    /// A currency symbol and the words English says for it. Yen, won and lira
    /// do not take a plural s.
    private static let currencies: [(symbol: Character, singular: String, plural: String)] = [
        ("$", "dollar", "dollars"), ("£", "pound", "pounds"), ("€", "euro", "euros"),
        ("¥", "yen", "yen"), ("₩", "won", "won"), ("₺", "lira", "lira"),
        ("₽", "ruble", "rubles"), ("₹", "rupee", "rupees"), ("¢", "cent", "cents"),
    ]

    /// `$4.99` as English says it, "4 dollars 99", rather than symbol-first
    /// ("dollar four point nine nine"). Exactly two digits after the point are
    /// the minor unit ("4 dollars oh 5"); any other tail stays in the amount
    /// ("3.14159 dollars"). `$4.00` drops the minor unit. A symbol with no
    /// amount is left, so a bare `$` survives. The sentence kept in the
    /// conversation is not rewritten; only English speech hears this.
    public static func currency(_ text: String) -> String {
        guard text.contains(where: { symbol in currencies.contains { $0.symbol == symbol } }) else { return text }
        let chars = Array(text)
        var out = ""
        var index = 0
        while index < chars.count {
            guard let money = currencies.first(where: { $0.symbol == chars[index] }) else {
                out.append(chars[index])
                index += 1
                continue
            }
            var end = index + 1
            var whole = ""
            while end < chars.count, chars[end].isNumber || (chars[end] == "," && end + 1 < chars.count && chars[end + 1].isNumber) {
                whole.append(chars[end])
                end += 1
            }
            guard !whole.isEmpty else {
                out.append(chars[index])
                index += 1
                continue
            }
            var minor: String?
            if end < chars.count, chars[end] == "." {
                var after = end + 1
                var digits = ""
                while after < chars.count, chars[after].isNumber {
                    digits.append(chars[after])
                    after += 1
                }
                if digits.count == 2 {
                    minor = digits
                    end = after
                } else if !digits.isEmpty {
                    whole += "." + digits
                    end = after
                }
            }
            let one = whole.replacingOccurrences(of: ",", with: "") == "1"
            out += whole + " " + (one ? money.singular : money.plural)
            if let minor, minor != "00" {
                out += minor.hasPrefix("0") ? " oh \(minor.dropFirst())" : " \(minor)"
            }
            index = end
        }
        return out
    }
}

/// A question is given a little more time than the same words as a statement.
///
/// Heard on the Mac, 2026-10-22: "You are coming with me tonight?" took 1.60 s
/// and the statement 1.73 s, so the question was the shorter of the two. The
/// old voice made questions 18-29% longer and stretched words ("toniiight").
/// The aim here is roughly a tenth longer than the statement, 8-12%.
///
/// Piper's length scale is what asks for that. The graph rounds each phoneme
/// up to a whole frame and gives back about 0.05 less than it was asked
/// (x1.1 lands near x1.05, x1.4 near x1.35), so `scale` asks for 1.24 to be
/// heard near x1.19. 1.60 x 1.19 is about 1.10 times the 1.73 s statement.
/// One multiplier for the whole part: nothing is held phoneme by phoneme.
public enum QuestionTime {
    /// Multiplier on Piper's length scale for a part that asks.
    public static let scale = 1.24

    /// By its last mark, after closing quotes. "?" asks; "!" does not.
    public static func asks(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)»"))
        return trimmed.last == "?"
    }

    /// The length-scale multiplier for one part of a sentence.
    ///
    /// A part ending in "?" asks. So does the last part when the sentence asks
    /// but the mark was left after a quote and is not on any part ("is it
    /// “micul dejun”?"): that word is the end of the question, so it gets the
    /// time. A quoted word earlier in the question does not.
    public static func scale(for part: String, in sentence: String, last: Bool) -> Double {
        if asks(part) || (last && asks(sentence)) { return scale }
        return 1
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

    /// The end of a reply comes back off the room a moment after the voice
    /// stops, and can be heard as the start of their turn: "like to do."
    /// after "…what kind of stuff do you like to do?". Words at the start of
    /// `heard` that are among the last few said are taken off; what is left
    /// is theirs, and nothing left means it was all echo.
    public static func strippingTail(_ heard: String, said: String, tail: Int = 10) -> String {
        let ending = Set(words(said).suffix(tail))
        guard !ending.isEmpty else { return heard }
        var kept = Substring(heard)
        while let range = kept.firstMatch(of: /^\s*([\p{L}\p{N}']+)[^\p{L}\p{N}']*/)?.range {
            let word = kept[range].lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
            guard ending.contains(word) else { break }
            kept = kept[range.upperBound...]
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// How late the reply's own voice comes back into the microphone: the
/// speakers' and microphone's latency and the room, 50 to 300 ms on a laptop.
///
/// The loudness of what was played and of what was heard, frame by frame,
/// rise and fall together, one behind the other; the lag at which they match
/// best is the delay. Everything comparing the microphone with what was
/// played needs it: without it, an echo 150 ms late is measured against the
/// wrong syllables, and the tail of a reply is still coming back after its
/// voice has stopped.
public struct EchoDelay: Sendable {
    /// Seconds per frame: the voice detector's 32 ms.
    public static let frame = 0.032
    static let window = 94  // three seconds
    static let longest = 15  // 480 ms
    /// How well the two must match for the lag to be believed.
    static let sure = 0.6

    private var heard: [Double] = []
    private var played: [Double] = []
    /// Seconds; 0 until it has been measured.
    public private(set) var delay = 0.0
    public private(set) var match = 0.0

    public init() {}

    /// One frame's loudness at the microphone, and of what was being played.
    public mutating func hear(mic: Double, played level: Double) {
        heard.append(mic)
        played.append(level)
        if heard.count > Self.window {
            heard.removeFirst(heard.count - Self.window)
            played.removeFirst(played.count - Self.window)
        }
        guard heard.count == Self.window, played.contains(where: { $0 > 1e-3 }) else { return }
        var best = (lag: 0, match: -1.0)
        for lag in 0...Self.longest {
            let a = Array(heard[lag...])
            let b = Array(played[..<(played.count - lag)])
            let match = Self.correlation(a, b)
            if match > best.match { best = (lag, match) }
        }
        match = best.match
        if best.match >= Self.sure { delay = Double(best.lag) * Self.frame }
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        guard n > 1 else { return 0 }
        let (ma, mb) = (a.reduce(0, +) / n, b.reduce(0, +) / n)
        var (ab, aa, bb) = (0.0, 0.0, 0.0)
        for (x, y) in zip(a, b) {
            ab += (x - ma) * (y - mb)
            aa += (x - ma) * (x - ma)
            bb += (y - mb) * (y - mb)
        }
        return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
    }
}

/// Catching it claiming to do what it can't. Told plainly in its
/// instructions, a 4B model still drifts into "I am looking into local
/// places that deliver… please hold on while I check" over a long evening.
/// A sentence like that is replaced with the truth, and the reply ends there.
public enum Honesty {
    public static let admission = "Actually, I can't look things up or check anything from here, sorry."

    /// What it says when it catches itself going round in circles.
    public static let unsure = "Sorry, I'm not sure of that one."

    /// A sentence taking back what came before it. A small model that
    /// doesn't know something can say "Wait, that's wrong… No… Actually…"
    /// for as long as it is let; the second one ends the reply.
    public static func corrects(_ sentence: String) -> Bool {
        let lower = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        let patterns = [
            #"^(?:no|nope|wait|hmm|oops|sorry)\b[.,!—–-]"#, #"^actually\b"#, #"\bthat's (?:wrong|not (?:it|right|the word))\b"#,
            #"\blet me correct\b"#, #"\bstill wrong\b"#, #"\bi'm messing (?:it )?up\b"#, #"\bno[ ,]+(?:that's|it's|wait)\b"#,
            #"\bcorrect (?:answer|word) is\b"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    public static func pretends(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        let patterns = [
            #"\b(?:i am|i'm|i will|i'll|let me|i can|i could|i'd)\s+(?:now\s+|just\s+|quickly\s+|go\s+and\s+)?(?:search|searching|look up|looking up|look into|looking into|look for places|looking for places|check|checking|browse|browsing|order|ordering|book|booking|call|calling|find (?:places|options|somewhere|a place|restaurants|delivery|out what's open))\b"#,
            #"\bi (?:have |'ve )?(?:found|checked|looked (?:it )?up|searched)\b"#,
            #"\bi am trying to (?:see|find|check)\b"#,
            #"\b(?:hold on|bear with me|give me (?:just )?a (?:moment|second|sec|minute))\b.*\b(?:check|look|search|find)"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}

/// Talking like a friend, not a help desk. Small models end nearly every
/// reply with "Is there anything else you need help with?" or "What would
/// you like to discuss next?", which the owner found impatient: those
/// sentences are left unsaid.
public enum Manners {
    public static func isFiller(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        let patterns = [
            #"\bis there anything else\b"#, #"\banything else (?:i can|you(?:'d| would)? (?:like|need|want)|on your mind)\b"#,
            #"\bwhat (?:else )?would you like to (?:talk about|discuss|do|know|chat about)(?: next| now)?\?"#,
            #"\bwhat(?:'s| is) next\b"#, #"\bwhat else (?:can i|would you|do you)\b"#,
            #"\bhow (?:else )?can i (?:help|assist)\b"#, #"\blet me know (?:if|when)\b"#, #"\bdoes that help\b"#,
            #"\bwould you like to know (?:more|anything else|how to say (?:anything|something) else)\b"#,
            #"\bdo you (?:want|need) (?:to know )?anything else\b"#, #"\bfeel free to ask\b"#,
            #"\bi(?:'m| am) here (?:to help|if you need)\b"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}
