import Foundation
import NaturalLanguage

/// How a sentence sounds, for the face to show while it is said.
///
/// Apple's on-device sentiment score, used only on its glad side. On its
/// other side it is no use here: it scored "How was the walk?" -0.6 and
/// "I'm sorry to hear that" -1.0, so a plain question would look as sad as
/// sympathy. "That's a lovely idea" scored 0.6, "Biscuit sounds like great
/// company" 0.4.
enum Tone {
    static let glad = 0.4

    static func isCheerful(_ sentence: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = sentence
        let (tag, _) = tagger.tag(at: sentence.startIndex, unit: .paragraph, scheme: .sentimentScore)
        return (tag.flatMap { Double($0.rawValue) } ?? 0) >= glad
    }
}
