import Foundation
import ModelStore
import VoiceCore

/// Where things live: models and data in the app bundle when built by
/// build.sh, otherwise in this checkout and, for development, voice-polyglot
/// beside it. What the companion learns, and the language models it has
/// fetched or linked, are in Application Support.
public enum Resources {
    static let checkout = URL(fileURLWithPath: #filePath)  // Sources/CompanionEngine/Resources.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// What the companion keeps: learned turn timing, conversation logs, models.
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Companion")
    }

    public static var conversations: URL { support.appending(path: "Conversations") }
    public static var timing: URL { support.appending(path: "turn-timing.json") }
    public static var memory: URL { support.appending(path: "memory.json") }

    /// This app's models, then this checkout's models/. A mismatched symlink is left alone.
    public static let models = ModelStore(
        directory: support.appending(path: "Models"),
        alsoSearching: [checkout.appending(path: "models")],
        leaveLinks: true)

    static let voicePolyglot = checkout.deletingLastPathComponent().appending(path: "voice-polyglot")
    static let polyglotName = "snepssen-polyglot.onnx"

    /// The polyglot snepssen, English included.
    public static var voice: URL? { polyglotVoice }

    /// Bundled under one name; in development voice-polyglot's newest export
    /// beside this checkout, else the release scripts/polyglot-voice.sh fetched.
    public static var polyglotVoice: URL? {
        first(bundled(polyglotName), newestExport(in: voicePolyglot.appending(path: "work/runs/polyglot/exports")),
              checkout.appending(path: "models/voice/\(polyglotName)"))
    }

    static func newestExport(in folder: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.filter({ $0.wholeMatch(of: /epoch-\d+/) != nil }).sorted().reversed() {
            let model = folder.appending(path: "\(name)/snepssen-polyglot-\(name).onnx")
            if FileManager.default.fileExists(atPath: model.path) { return model }
        }
        return nil
    }

    /// voice-core's, the data every snepssen voice was trained with.
    public static var espeakData: URL? { EspeakData.directory }

    /// The offline dictionary (scripts/build-dictionary.sh).
    public static var dictionary: URL? {
        first(bundled("dictionary.sqlite"), checkout.appending(path: "models/dictionary.sqlite"))
    }

    public static var vad: URL? {
        first(bundled("silero_vad.onnx"), checkout.appending(path: "models/silero_vad.onnx"))
    }

    private static func bundled(_ name: String) -> URL? { Bundle.main.resourceURL?.appending(path: name) }

    private static func first(_ candidates: URL?...) -> URL? {
        candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
