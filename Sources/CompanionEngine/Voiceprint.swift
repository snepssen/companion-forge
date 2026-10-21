import CompanionCore
import FluidAudio
import Foundation

/// A voice in a number: a few seconds of someone speaking, as a unit vector
/// that lies close to other recordings of the same voice and far from
/// other voices'. From FluidAudio, which also hears the words: CAM++, a
/// model made for telling speakers apart, or the WeSpeaker model its
/// diarizer uses.
public final class Voiceprinter: @unchecked Sendable {
    public enum Model: String, CaseIterable, Sendable { case campplus, wespeaker }

    public let model: Model
    static let shortest = 16_000  // its fbank stage wants 64 frames, a little over 0.64 s
    private let campplus: CampPlusEmbedder?
    private let diarizer: DiarizerManager?
    private let lock = NSLock()

    public init(_ model: Model) async throws {
        self.model = model
        switch model {
        case .campplus:
            campplus = try await CampPlusEmbedder.load()
            diarizer = nil
        case .wespeaker:
            let manager = DiarizerManager()
            manager.initialize(models: try await DiarizerModels.downloadIfNeeded())
            diarizer = manager
            campplus = nil
        }
    }

    /// 16 kHz mono speech to its voiceprint.
    public func print(_ samples: [Float]) async throws -> [Float] {
        // CAM++ takes about a second at least: a shorter "yeah" is repeated to it.
        var samples = samples
        if !samples.isEmpty, samples.count < Self.shortest {
            samples = Array(repeating: samples, count: Self.shortest / samples.count + 1).flatMap { $0 }
        }
        let raw: [Float]
        if let campplus { raw = try await campplus.embed(audio: samples) }
        else { raw = try lock.withLock { try diarizer!.extractSpeakerEmbedding(from: samples) } }
        // Unit length, whatever the model gives, so a dot product is the cosine.
        let length = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? raw.map { $0 / length } : raw
    }
}

/// The household's voices as the conversation hears them: looked at while a
/// reply is drafted (which may be thrown away and drafted again), and only
/// learned from once the turn is theirs for certain, so a sentence never
/// counts twice.
public final class VoiceSense: @unchecked Sendable {
    private let lock = NSLock()
    private var household: Household

    public init(_ household: Household) { self.household = household }

    public var current: Household { lock.withLock { household } }

    /// Who this sounds like, changing nothing.
    public func peek(_ print: [Float], seconds: Double) -> Household.Heard {
        var copy = lock.withLock { household }
        return copy.hear(print, seconds: seconds)
    }

    /// Who this was, learning from it.
    public func hear(_ print: [Float], seconds: Double) -> Household.Heard {
        lock.withLock { household.hear(print, seconds: seconds) }
    }

    public func name(_ id: String, _ name: String) { lock.withLock { household.name(id, name) } }
}
