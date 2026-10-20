import Foundation
import VoiceCore

/// Where things live: models and data in the app bundle when built by
/// build.sh, otherwise in this checkout and the snepssen projects beside it,
/// for development; what the companion learns in Application Support.
public enum Resources {
    static let checkout = URL(fileURLWithPath: #filePath)  // Sources/CompanionEngine/Resources.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let translateCore = checkout.deletingLastPathComponent().appending(path: "translate-core")
    static let voiceForge = checkout.deletingLastPathComponent().appending(path: "voice-forge")
    static let voiceName = "en_US-snepssen-medium.onnx"

    /// What the companion keeps: learned turn timing, conversation logs, models.
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Companion")
    }

    public static var conversations: URL { support.appending(path: "Conversations") }
    public static var timing: URL { support.appending(path: "turn-timing.json") }
    public static var memory: URL { support.appending(path: "memory.json") }

    /// voice-forge's English snepssen voice.
    public static var voice: URL? {
        first(bundled(voiceName),
              voiceForge.appending(path: "macos/Sources/VoiceForgeTTS/Resources/\(voiceName)"),
              voiceForge.appending(path: "cross-platform/resources/voices/\(voiceName)"))
    }

    /// voice-core's, the data every snepssen voice was trained with.
    public static var espeakData: URL? { EspeakData.directory }

    public static var vad: URL? {
        first(bundled("silero_vad.onnx"), checkout.appending(path: "models/silero_vad.onnx"),
              translateCore.appending(path: "models/silero_vad.onnx"))
    }

    private static func bundled(_ name: String) -> URL? { Bundle.main.resourceURL?.appending(path: name) }

    private static func first(_ candidates: URL?...) -> URL? {
        candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
