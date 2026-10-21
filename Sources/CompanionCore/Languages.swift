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
