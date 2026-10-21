import CryptoKit
import Foundation

/// What it remembers, sealed: AES-GCM with a key that never leaves the
/// device (the app keeps it in the Keychain). Files written before sealing
/// still open, and are sealed the next time they're written.
public struct Sealer: Sendable {
    let key: SymmetricKey?

    /// Leaves everything as it is: for measuring, and for tests.
    public static let plain = Sealer(key: nil)

    public init(key: SymmetricKey?) { self.key = key }
    public var seals: Bool { key != nil }

    /// A whole file starts with this; a sealed log line with `lineMark`.
    static let magic = Data("CCSEAL1\n".utf8)
    static let lineMark = "~"

    public func seal(_ data: Data) throws -> Data {
        guard let key else { return data }
        guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.coderInvalidValue) }
        return Self.magic + sealed
    }

    public func open(_ data: Data) throws -> Data {
        guard data.starts(with: Self.magic) else { return data }  // from before sealing
        guard let key else { throw CocoaError(.fileReadNoPermission) }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count)), using: key)
    }

    /// One line of a log: sealed and written as text, so the log stays a
    /// file of lines that can be appended to.
    public func sealLine(_ line: Data) throws -> String {
        guard let key else { return String(decoding: line, as: UTF8.self) }
        guard let sealed = try AES.GCM.seal(line, using: key).combined else { throw CocoaError(.coderInvalidValue) }
        return Self.lineMark + sealed.base64EncodedString()
    }

    public func openLine(_ line: Substring) throws -> Data {
        guard line.hasPrefix(Self.lineMark) else { return Data(line.utf8) }
        guard let key, let sealed = Data(base64Encoded: String(line.dropFirst())) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }
}
