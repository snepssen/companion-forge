import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Sentences to vectors, for finding notes by meaning: bge-small-en-v1.5 on
/// MLX, unit length, compared by dot product.
public actor Embedder {
    public static let model = EmbedderModel()
    /// bge's own instruction for a short query searched against passages.
    static let queryPrefix = "Represent this sentence for searching relevant passages: "
    static let longest = 256

    private let context: EmbedderModelContext

    /// Load it, downloading it first (134 MB) if it isn't here.
    public static func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Embedder {
        let directory = try await ModelStore.download(model, progress: progress)
        let context = try await EmbedderModelFactory.shared.load(from: directory, using: #huggingFaceTokenizerLoader())
        return Embedder(context)
    }

    private init(_ context: consuming EmbedderModelContext) { self.context = context }

    /// One vector per text. `query` marks something to search with rather
    /// than something to be found.
    public func embed(_ texts: [String], query: Bool = false) -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let tokens = texts.map { text in
            Array(context.tokenizer.encode(text: (query ? Self.queryPrefix : "") + text, addSpecialTokens: true)
                .prefix(Self.longest))
        }
        let length = tokens.map(\.count).max() ?? 1
        // Padded with zeros, BERT's [PAD]; the mask says which are real.
        let padded = stacked(tokens.map { MLXArray($0 + Array(repeating: 0, count: length - $0.count)) })
        let mask = stacked(tokens.map { MLXArray(Array(repeating: Int32(1), count: $0.count)
                + Array(repeating: Int32(0), count: length - $0.count)) })
        let output = context.model(padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded),
                                   attentionMask: mask)
        let pooled = context.pooling(output, mask: mask, normalize: true)
        pooled.eval()
        return (0..<texts.count).map { pooled[$0].asArray(Float.self) }
    }
}
