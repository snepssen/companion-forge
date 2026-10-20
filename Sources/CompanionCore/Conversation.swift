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
