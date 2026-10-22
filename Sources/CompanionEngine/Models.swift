import CompanionCore
import Foundation
import ModelStore

/// A language model the companion can talk with, pinned to a revision.
///
/// Generalists, small enough for a phone, measured in interpreter-forge
/// (scripts/compare-models.py, the complete-thought judge): Gemma 4 E4B is the
/// best of them and wants a Mac or a 12 GB iPhone; Qwen3 4B and Gemma 4 E2B
/// fit an 8 GB phone beside speech recognition and the voice.
public struct ChatModel: StoredModel, Identifiable, Hashable, Sendable {
    /// How it picks its words: each family's own recommendation, tempered
    /// for talk. Qwen3 at Gemma's settings looped, correcting itself
    /// sentence after sentence ("peşte… no… cină… no…").
    public struct Sampling: Hashable, Sendable {
        public var temperature: Float
        public var topP: Float
        public var topK: Int
        public var presencePenalty: Float?
        public var repetitionPenalty: Float?
    }

    public var sampling: Sampling {
        id.hasPrefix("qwen")
            ? Sampling(temperature: 0.7, topP: 0.8, topK: 20, presencePenalty: 1.0, repetitionPenalty: 1.05)
            // Google recommends 1.0; at 0.7 Gemma's talk came out stiff and samey.
            : Sampling(temperature: 0.9, topP: 0.95, topK: 64, presencePenalty: nil, repetitionPenalty: 1.05)
    }

    public let id: String  // folder name, and what is remembered as the choice
    public let name: String
    public let tagline: String
    public let repo: String
    public let revision: String
    /// Peak memory while generating, measured on a Mac.
    public let memoryGB: Double
    public let files: [ModelFile]
    /// Bytes to fetch: the sum of the pinned file sizes.
    public var download: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Whether this device has the memory for it alongside recognition and the voice.
    public var fits: Bool {
        #if os(macOS)
        Double(ProcessInfo.processInfo.physicalMemory) / 1e9 >= memoryGB * 2.3
        #else
        Double(ProcessInfo.processInfo.physicalMemory) / 1e9 >= memoryGB * 2.3
        #endif
    }
}

public enum ModelCatalog {
    // interpreter-forge's pins, sizes and measurements, so a model downloaded
    // for either app is the same files.
    public static let all: [ChatModel] = [
        // Twice the size of the others, and knows more: for a Mac with the
        // memory (16 GB and up), not a phone. Qwen3.5 9B knew as much but
        // took 7-8 s to its first words on an M1: its hybrid attention keeps
        // a state that can't be rewound, so the whole prompt was read every
        // turn. Qwen3 8B is plain attention and reuses its cache.
        ChatModel(
            id: "qwen3-8b-4bit", name: "Qwen3 8B", tagline: "Knows the most · Mac with 16 GB",
            repo: "mlx-community/Qwen3-8B-4bit", revision: "545dc4251c05440727734bcd94334791f6ab0192",
            memoryGB: 5.6,
            files: [.init(name: "added_tokens.json", size: 707), .init(name: "config.json", size: 939),
                    .init(name: "merges.txt", size: 1_671_853), .init(name: "model.safetensors", size: 4_607_835_174),
                    .init(name: "model.safetensors.index.json", size: 64065), .init(name: "special_tokens_map.json", size: 613),
                    .init(name: "tokenizer.json", size: 11_422_654), .init(name: "tokenizer_config.json", size: 9706),
                    .init(name: "vocab.json", size: 2_776_833)]),
        ChatModel(
            id: "gemma-4-e4b-it-4bit", name: "Gemma 4 E4B", tagline: "Best conversation · Mac or 12 GB iPhone",
            repo: "mlx-community/gemma-4-e4b-it-4bit", revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
            memoryGB: 4.7,
            files: [.init(name: "chat_template.jinja", size: 17336), .init(name: "config.json", size: 6628),
                    .init(name: "generation_config.json", size: 208), .init(name: "model.safetensors.index.json", size: 240_961),
                    .init(name: "processor_config.json", size: 1316), .init(name: "tokenizer.json", size: 32_169_626),
                    .init(name: "tokenizer_config.json", size: 2740), .init(name: "model.safetensors", size: 5_146_800_534)]),
        ChatModel(
            id: "qwen3-4b-instruct-2507-4bit", name: "Qwen3 4B", tagline: "Fits an 8 GB phone",
            repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
            memoryGB: 2.8,
            files: [.init(name: "added_tokens.json", size: 707), .init(name: "chat_template.jinja", size: 4040),
                    .init(name: "config.json", size: 938), .init(name: "generation_config.json", size: 238),
                    .init(name: "merges.txt", size: 1_671_853), .init(name: "model.safetensors.index.json", size: 63964),
                    .init(name: "special_tokens_map.json", size: 613), .init(name: "tokenizer.json", size: 11_422_654),
                    .init(name: "tokenizer_config.json", size: 5440), .init(name: "vocab.json", size: 2_776_833),
                    .init(name: "model.safetensors", size: 2_263_022_417)]),
        ChatModel(
            id: "gemma-4-e2b-it-4bit", name: "Gemma 4 E2B", tagline: "Fastest, roughest",
            repo: "mlx-community/gemma-4-e2b-it-4bit", revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
            memoryGB: 3.0,
            files: [.init(name: "chat_template.jinja", size: 17336), .init(name: "config.json", size: 6395),
                    .init(name: "generation_config.json", size: 208), .init(name: "model.safetensors.index.json", size: 218_323),
                    .init(name: "processor_config.json", size: 1316), .init(name: "tokenizer.json", size: 32_169_626),
                    .init(name: "tokenizer_config.json", size: 2740), .init(name: "model.safetensors", size: 3_550_670_554)]),
    ]

    public static var offered: [ChatModel] { all.filter(\.fits) }
    /// Gemma 4 E4B where it fits, as before; the bigger Qwen3 8B is offered,
    /// not pressed on anyone.
    public static var recommended: ChatModel {
        offered.first { $0.id == "gemma-4-e4b-it-4bit" } ?? offered.first { $0.id != "qwen3-8b-4bit" } ?? all[all.count - 1]
    }
    public static func model(_ id: String?) -> ChatModel? { all.first { $0.id == id } }
}

/// The embedding model notes are found by: bge-small-en-v1.5, 33 million
/// parameters. Apple's built-in sentence embedding was tried first and ranked
/// "They work night shifts as a nurse" above "They have no eggs at home" for
/// "What should I make for breakfast?".
public struct EmbedderModel: StoredModel {
    public let id = "bge-small-en-v1.5"
    public let repo = "BAAI/bge-small-en-v1.5"
    public let revision = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
    public let files: [ModelFile] = [
        .init(name: "1_Pooling/config.json", size: 190), .init(name: "config.json", size: 743),
        .init(name: "model.safetensors", size: 133_466_304), .init(name: "special_tokens_map.json", size: 125),
        .init(name: "tokenizer.json", size: 711_396), .init(name: "tokenizer_config.json", size: 366),
        .init(name: "vocab.txt", size: 231_508),
    ]
    public init() {}
}

struct Problem: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
