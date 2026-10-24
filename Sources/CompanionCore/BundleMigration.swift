import Foundation

/// The Mac app's bundle ID used to be `local.companion-core.companion`.
/// Preferences and the saved window are named with it; the first launch of
/// `com.snepssen.companion` moves them across.
///
/// What the companion learns is not named with the bundle ID. It lives in
/// `~/Library/Application Support/Companion`, and the Mac app is not
/// sandboxed, so that folder is not inside `~/Library/Containers/<bundle id>`
/// either. The Keychain service is already `com.snepssen.companion`, with no
/// access group, and this does not touch it: the memory key is stored there.
public enum BundleMigration {
    /// What `build.sh` used to write as `CFBundleIdentifier`.
    public static let previousBundleID = "local.companion-core.companion"
    /// What the Mac app, the iOS app, and the Keychain service share.
    public static let bundleID = "com.snepssen.companion"

    public enum Outcome: Equatable, Sendable {
        /// Nothing at the old path.
        case absent
        /// The new path matches the old one byte for byte, and the old one is gone.
        case moved
        /// The new path was already there and differs. The old one is left in place.
        case leftInPlace
        /// The copy could not be checked. The old one is left in place.
        case unverified
    }

    /// Preferences (`~/Library/Preferences/<id>.plist`) and the saved window
    /// (`~/Library/Saved Application State/<id>.savedState`) for one home directory.
    /// Does nothing to Application Support. A second call finds the old paths
    /// gone and does nothing.
    @discardableResult
    ///
    /// `home` defaults to `NSHomeDirectory()`, not
    /// `FileManager.homeDirectoryForCurrentUser`: the second exists only on
    /// macOS, and as a default argument it is compiled for iOS too, where it
    /// broke the build. For the unsandboxed Mac app the two are the same folder.
    public static func migrateMacLibrary(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                                         fileManager: FileManager = .default) -> [Outcome] {
        let library = home.appending(path: "Library")
        return [
            moveVerified(from: library.appending(path: "Preferences").appending(path: "\(previousBundleID).plist"),
                         to: library.appending(path: "Preferences").appending(path: "\(bundleID).plist"),
                         fileManager: fileManager),
            moveVerified(from: library.appending(path: "Saved Application State").appending(path: "\(previousBundleID).savedState"),
                         to: library.appending(path: "Saved Application State").appending(path: "\(bundleID).savedState"),
                         fileManager: fileManager),
        ]
    }

    /// Copy `source` to `destination` when the destination is absent, then
    /// delete `source` only after the copy has been read back and matches.
    /// Idempotent: no source, nothing to do; a destination that already
    /// matches is the signal to remove a source left behind by a launch that
    /// stopped after the copy; a destination that differs is left alone.
    @discardableResult
    public static func moveVerified(from source: URL, to destination: URL, fileManager: FileManager = .default) -> Outcome {
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else { return .leftInPlace }
        guard fileManager.fileExists(atPath: source.path) else { return .absent }
        if fileManager.fileExists(atPath: destination.path) {
            guard sameContents(source, destination, fileManager) else { return .leftInPlace }
            return removeSource(source, fileManager) ? .moved : .unverified
        }

        // A leftover from a copy that never got into place. It is ours, not
        // the previous install's file, so it can go before we try again.
        let temporary = destination.appendingPathExtension("migrating")
        if fileManager.fileExists(atPath: temporary.path) {
            try? fileManager.removeItem(at: temporary)
            if fileManager.fileExists(atPath: temporary.path) { return .unverified }
        }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .unverified
        }
        guard sameContents(source, temporary, fileManager) else {
            try? fileManager.removeItem(at: temporary)
            return .unverified
        }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .unverified
        }
        // The rename is the copy that counts. If it doesn't match, drop it
        // (we just wrote it) and keep the source for the next launch.
        guard sameContents(source, destination, fileManager) else {
            try? fileManager.removeItem(at: destination)
            return .unverified
        }
        return removeSource(source, fileManager) ? .moved : .unverified
    }

    private static func removeSource(_ source: URL, _ fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: source)
        } catch {
            return !fileManager.fileExists(atPath: source.path)
        }
        return !fileManager.fileExists(atPath: source.path)
    }

    /// Files and directories, every name, every byte. A directory and a file
    /// at the same path are not the same.
    private static func sameContents(_ source: URL, _ destination: URL, _ fileManager: FileManager) -> Bool {
        let sourceIsDirectory = isDirectory(source, fileManager)
        guard sourceIsDirectory == isDirectory(destination, fileManager) else { return false }
        if sourceIsDirectory {
            guard let sourceNames = try? fileManager.contentsOfDirectory(atPath: source.path),
                  let destinationNames = try? fileManager.contentsOfDirectory(atPath: destination.path),
                  sourceNames.sorted() == destinationNames.sorted() else { return false }
            return sourceNames.allSatisfy { name in
                sameContents(source.appending(path: name), destination.appending(path: name), fileManager)
            }
        }
        guard let sourceBytes = try? Data(contentsOf: source), let destinationBytes = try? Data(contentsOf: destination) else {
            return false
        }
        return sourceBytes == destinationBytes
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
