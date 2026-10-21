import CompanionCore
import Foundation
import SQLite3

/// The offline dictionary, from English Wiktionary (scripts/build-dictionary.py):
/// translations between English and the languages it is asked about, and
/// what English words mean. Looked up before a reply, so a small model is
/// handed the word instead of guessing one: none of the three knew
/// "micul dejun".
public final class Dictionary: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init?(file: URL) {
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    /// What to tell the model about what they just said, if it asked
    /// something the dictionary answers.
    public func aside(for text: String) -> String? {
        Lookup.request(in: text).map(answer)
    }

    /// What to tell the model, for a question the dictionary can answer.
    public func answer(_ lookup: Lookup) -> String {
        switch lookup {
        case let .translate(phrase, into: language):
            let name = Languages.name(of: language)
            let found = translations(of: phrase, into: language)
            guard !found.isEmpty else {
                return "Your dictionary has no \(name) for \"\(phrase)\". Say you don't know it rather than guess."
            }
            let words = found.map { $0.roman.isEmpty ? $0.word : "\($0.word) (\($0.roman))" }
            let sense = found.first.map { $0.sense.isEmpty ? "" : ", meaning \($0.sense)" } ?? ""
            return "From your dictionary: \"\(phrase)\"\(sense) in \(name) is \(words.joined(separator: ", or ")). "
                + "Use that, put the \(name) word in quotation marks, and don't guess another."
        case let .meaning(word):
            let meanings = self.meanings(of: word)
            if !meanings.isEmpty {
                return "From your dictionary, \"\(word)\" means: \(meanings.joined(separator: "; ")). Explain it simply."
            }
            let english = reverse(word)
            if let first = english.first {
                let alternatives = english.dropFirst().map(\.english)
                return "From your dictionary: \"\(word)\" is \(Languages.name(of: first.language)) for \"\(first.english)\""
                    + (alternatives.isEmpty ? "" : " (also \(alternatives.map { "\"\($0)\"" }.joined(separator: ", ")))")
                    + ". Say so simply."
            }
            return "Your dictionary doesn't have \"\(word)\". Say you don't know it rather than guess."
        }
    }

    /// Words for `phrase` in `language`, the commonest sense first.
    func translations(of phrase: String, into language: String, limit: Int = 3) -> [(word: String, roman: String, sense: String)] {
        rows("""
             SELECT t.word, t.roman, s.text FROM translations t JOIN senses s ON s.id = t.sense
             WHERE t.english = (SELECT id FROM words WHERE text = ?1) AND t.lang = ?2 ORDER BY t.rowid LIMIT ?3
             """,
             [phrase.lowercased(), language, String(limit)]) { ($0[0], $0[1], $0[2]) }
    }

    /// English for a word in one of the other languages.
    func reverse(_ word: String, limit: Int = 3) -> [(english: String, language: String)] {
        var seen = Set<String>()
        return rows("""
                    SELECT w.text, t.lang FROM translations t JOIN words w ON w.id = t.english
                    WHERE t.word = ?1 COLLATE NOCASE LIMIT 12
                    """, [word]) { ($0[0], $0[1]) }
            .filter { seen.insert($0.0).inserted }.prefix(limit).map { $0 }
    }

    /// What an English word means.
    func meanings(of word: String, limit: Int = 2) -> [String] {
        rows("SELECT gloss FROM meanings WHERE word = (SELECT id FROM words WHERE text = ?1) ORDER BY rank LIMIT ?2",
             [word.lowercased(), String(limit)]) { $0[0] }
    }

    private func rows<T>(_ sql: String, _ arguments: [String], _ row: ([String]) -> T) -> [T] {
        lock.withLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, argument) in arguments.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
            }
            var out: [T] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let columns = (0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                }
                out.append(row(columns))
            }
            return out
        }
    }
}
