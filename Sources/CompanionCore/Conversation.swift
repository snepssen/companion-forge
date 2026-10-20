import Foundation

/// One turn of a conversation, as it was heard or said.
public struct Turn: Codable, Equatable, Sendable {
    public enum Speaker: String, Codable, Sendable { case person, companion }

    public var speaker: Speaker
    public var text: String
    public var at: Date
    /// A reply cut off part way: `text` is only what was said before it stopped.
    public var interrupted: Bool

    public init(_ speaker: Speaker, _ text: String, at: Date = Date(), interrupted: Bool = false) {
        self.speaker = speaker
        self.text = text
        self.at = at
        self.interrupted = interrupted
    }
}

/// Every conversation in full, one JSON line per turn, a file per session.
///
/// This is the bottom of the memory: nothing is decided here about what is
/// worth keeping. Summaries will point back into these files by session and
/// turn, so they are only ever appended to.
public final class ConversationLog: @unchecked Sendable {
    public let file: URL
    public let session: String
    private let lock = NSLock()
    private var count = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public init(directory: URL, started: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd'T'HHmmss"
        session = format.string(from: started)
        file = directory.appending(path: "\(session).jsonl")
    }

    /// Append a turn; returns its index in the session.
    @discardableResult
    public func append(_ turn: Turn) throws -> Int {
        var line = try encoder.encode(turn)
        line.append(0x0A)
        return try lock.withLock {
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
            count += 1
            return count - 1
        }
    }

    public static func read(_ file: URL) throws -> [Turn] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .map { try decoder.decode(Turn.self, from: Data($0.utf8)) }
    }
}

/// How much of the conversation the model is shown.
///
/// A window that slides one turn at a time changes the start of the prompt
/// with every reply, and the model's cache is only good up to the first token
/// that changed: past 16 turns it re-read about 230 tokens a reply and its
/// first words came 1.86 s after the turn instead of 0.31 s (ccrun --long,
/// Gemma 4 E4B, this Mac). So the window grows a turn at a time and drops
/// `step` turns at once: the prompt's start moves once every `step` turns.
public enum Window {
    public static let recent = 16
    public static let step = 8
    /// What the loop keeps at most; trimmed `step * 2` at a time, which
    /// leaves `shown` where it was.
    public static let kept = 64

    /// How many of the last `count` turns to show.
    public static func shown(_ count: Int) -> Int {
        count <= recent ? count : recent + (count - recent) % step
    }

    /// How many turns to drop from the front of a history of `count`.
    public static func trim(_ count: Int) -> Int {
        count > kept ? step * 2 * ((count - kept + step * 2 - 1) / (step * 2)) : 0
    }
}
