import Foundation

/// Speaking more than English: which parts of a sentence are in which
/// language, so the polyglot voice can say "micul dejun" as Romanian inside
/// an English sentence rather than reading it out as English spelling.
public enum Languages {
    /// Languages people name, as espeak-ng's voices know them. The polyglot
    /// voice was trained on eight (Polyphon.trained); the rest it reads
    /// through plain espeak-ng, with an accent.
    public static let names: [String: String] = [
        "english": "en", "romanian": "ro", "hungarian": "hu", "polish": "pl", "german": "de", "dutch": "nl",
        "french": "fr", "spanish": "es", "italian": "it", "portuguese": "pt", "czech": "cs", "slovak": "sk",
        "swedish": "sv", "danish": "da", "norwegian": "nb", "finnish": "fi", "greek": "el", "russian": "ru",
        "ukrainian": "uk", "bulgarian": "bg", "croatian": "hr", "serbian": "sr", "slovenian": "sl", "turkish": "tr",
        "japanese": "ja", "chinese": "cmn", "mandarin": "cmn", "korean": "ko", "latin": "la", "welsh": "cy",
        "irish": "ga", "estonian": "et", "latvian": "lv", "lithuanian": "lt", "catalan": "ca", "icelandic": "is",
    ]

    /// A language's name, from its code.
    public static func name(of code: String) -> String {
        names.first { $0.value == code && $0.key != "mandarin" }.map { $0.key.capitalized } ?? code
    }

    /// The language they asked about, if they named one: "how do I say
    /// breakfast in Romanian?" is Romanian. English isn't news.
    public static func named(in text: String) -> String? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.lazy.compactMap { names[$0] }.first { $0 != "en" }
    }

    /// A sentence cut where its quotation marks are: the quoted parts are
    /// where a word from another language usually sits.
    public static func segments(_ sentence: String) -> [(text: String, quoted: Bool)] {
        var out: [(text: String, quoted: Bool)] = []
        var current = ""
        var quoted = false
        func flush() {
            let text = current.trimmingCharacters(in: .whitespaces)
            if text.contains(where: { $0.isLetter }) { out.append((text, quoted)) }
            current = ""
        }
        for character in sentence {
            if "\"“”„«»".contains(character) {
                flush()
                quoted.toggle()
            } else {
                current.append(character)
            }
        }
        flush()
        return out
    }
}

/// A question the dictionary can answer, rather than the model guessing.
public enum Lookup: Equatable, Sendable {
    /// "How do you say breakfast in Romanian?"
    case translate(String, into: String)
    /// "What does köszönöm mean?", "What's the meaning of ephemeral?"
    case meaning(String)

    public static func request(in text: String) -> Lookup? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let language = #"(\p{L}+)"#
        let translations = [
            #"how (?:do|can|would|could|should) (?:you|i|we|one) (?:say|write|spell|call)\s+(.+?)\s+in\s+"# + language,
            #"what(?:'s| is| are) (?:the word for )?(.+?)\s+in\s+"# + language,
            #"what(?:'s| is) the\s+"# + language + #"\s+(?:word|term) for\s+(.+?)$"#,
            #"translate\s+(.+?)\s+(?:in|into|to)\s+"# + language,
            #"(?:say|tell me)\s+(.+?)\s+in\s+"# + language,
        ]
        for (index, pattern) in translations.enumerated() {
            guard let match = lower.firstMatch(of: try! Regex(pattern)) else { continue }
            let first = String(match.output[1].substring ?? "")
            let second = String(match.output[2].substring ?? "")
            // The "the L word for X" form names the language first.
            let (phrase, name) = index == 2 ? (second, first) : (first, second)
            guard let code = Languages.names[name], code != "en" else { continue }
            let cleaned = clean(phrase)
            if !cleaned.isEmpty { return .translate(cleaned, into: code) }
        }
        if let match = lower.firstMatch(of: #/what (?:does|do|did)\s+(.+?)\s+mean\b/#) ?? lower.firstMatch(of: #/(?:what(?:'s| is) the )?meaning of\s+(.+?)$/#) {
            let cleaned = clean(String(match.output.1))
            if !cleaned.isEmpty { return .meaning(cleaned) }
        }
        return nil
    }

    /// The word or phrase itself: no quotes, articles or trailing punctuation.
    static func clean(_ phrase: String) -> String {
        var out = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’„«».,!?:;"))
        for article in ["the word ", "the phrase ", "a ", "an ", "the ", "to "] where out.hasPrefix(article) {
            out = String(out.dropFirst(article.count))
            break
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’„«».,!?:;"))
        return out.split(separator: " ").count <= 4 ? out : ""
    }
}
