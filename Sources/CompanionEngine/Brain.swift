import CompanionCore
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The language model and the conversation it is having: an actor, because
/// MLX is driven from one place at a time.
///
/// The attention cache is kept between turns and each reply reads only what
/// changed since the last one. On an M1 reading the prompt costs as much as
/// writing the answer (translate-core's measurement), and in a conversation
/// almost all of the prompt is the same each time: the instructions and every
/// turn before this one.
public actor Brain {
    public let model: ChatModel
    private let context: ModelContext
    private var cache: PromptCache
    /// Writing notes has its own: the conversation's stays as it was.
    private var notesCache: PromptCache
    private let stops: Set<Int>
    /// The most a reply runs to: about a minute of speech, and a stop for a
    /// model that has started a list.
    static let longest = 240

    public init(model: ChatModel, at directory: URL) async throws {
        // Variable shapes otherwise grow MLX's cache without bound; a phone has less to spare.
        #if os(iOS)
        MLX.Memory.cacheLimit = 256 << 20
        #else
        MLX.Memory.cacheLimit = 1 << 30
        #endif
        let context = try await loadModel(from: directory, using: #huggingFaceTokenizerLoader())
        // The end-of-turn marker isn't the declared end token for every model.
        stops = Set(([context.tokenizer.eosTokenId] + ["<end_of_turn>", "<turn|>", "<|im_end|>", "<|endoftext|>"]
                .map { context.tokenizer.convertTokenToId($0) }).compactMap { $0 })
            .union(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
        cache = try PromptCache(context.model)
        notesCache = try PromptCache(context.model)
        self.model = model
        self.context = context
    }

    /// Read the instructions once, so the first real turn doesn't pay for it.
    public func warmUp() throws {
        _ = try reply(to: [Turn(.person, "Hi.")]) { _ in }
    }

    /// A reply to the conversation so far, with what the memory brought up,
    /// its text handed to `emit` as it is written. Cancelling the task stops
    /// it between tokens and keeps the cache.
    @discardableResult
    public func reply(to turns: [Turn], remembering recollection: Recollection = Recollection(),
                      emit: @Sendable (String) -> Void) throws -> String {
        try generate(Prompts.messages(turns, remembering: recollection), cache: &cache,
                     parameters: GenerateParameters(maxTokens: Self.longest, temperature: 0.7, topP: 0.9), emit: emit)
    }

    /// Notes from a conversation, as `Remembering` asks for them.
    public func write(_ instructions: String, _ text: String) throws -> String {
        try generate([["role": "system", "content": instructions], ["role": "user", "content": text]], cache: &notesCache,
                     parameters: GenerateParameters(maxTokens: 320, temperature: 0.2)) { _ in }
    }

    private func generate(_ messages: [[String: any Sendable]], cache: inout PromptCache, parameters: GenerateParameters,
                          emit: @Sendable (String) -> Void) throws -> String {
        let prompt = try context.tokenizer.applyChatTemplate(
            messages: messages, tools: nil,
            additionalContext: ["enable_thinking": false])  // Gemma 4 otherwise reasons aloud: seconds a turn
        try Task.checkCancellation()
        let fresh = try cache.prepare(for: prompt)
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(fresh)), model: context.model, cache: cache.kv,
                                         parameters: parameters)
        var produced: [Int] = []
        var written = ""
        while let token = iterator.next() {
            if Task.isCancelled || stops.contains(token) { break }
            produced.append(token)
            let text = context.tokenizer.decode(tokenIds: produced, skipSpecialTokens: true)
            // Half a multi-byte character decodes as a replacement mark; wait for the rest.
            if text.count > written.count && !text.hasSuffix("\u{FFFD}") {
                emit(String(text.dropFirst(written.count)))
                written = text
            }
        }
        // The cache may run a token past what was kept; hold it to what we know.
        cache.settle(prompt + produced)
        try Task.checkCancellation()
        return written
    }
}

enum Prompts {
    static let system = """
    You are a companion: a friendly protogen with a glowing visor for a face, talking out loud with one person. \
    Everything you say is spoken by a voice, so talk the way people talk: usually one to three short sentences, \
    plain words, no lists, no markdown, no emoji, nothing in brackets. Ask something back when it fits, not every time. \
    You hear them through speech recognition, which sometimes mishears; if something sounds garbled, say so and ask. \
    If they cut you off, let it go and listen. You run entirely on their device, with no internet.
    """

    /// How many turns go into the prompt. Memory will bring older ones back as summaries.
    static let recent = 16

    /// The conversation as chat messages. Turns by the same speaker in a row
    /// (a reply cut off before it said anything) are joined: chat templates
    /// expect the roles to alternate, and some refuse otherwise.
    ///
    /// What it knows about them goes in the instructions, which change only
    /// when a note is written. What came to mind for this turn goes before
    /// their last words, so everything earlier stays in the attention cache.
    static func messages(_ turns: [Turn], remembering recollection: Recollection = Recollection()) -> [[String: any Sendable]] {
        let instructions = [system, recollection.knowing].compactMap { $0 }.joined(separator: "\n\n")
        var messages: [[String: any Sendable]] = [["role": "system", "content": instructions]]
        var previous: Turn.Speaker?
        for turn in turns.suffix(recent) {
            let role = turn.speaker == .person ? "user" : "assistant"
            let text = turn.interrupted ? turn.text + "—" : turn.text
            if messages.count == 1 && turn.speaker == .companion { continue }  // the first must be theirs
            if turn.speaker == previous, let last = messages.last?["content"] as? String {
                messages[messages.count - 1]["content"] = last + " " + text
            } else {
                messages.append(["role": role, "content": text])
            }
            previous = turn.speaker
        }
        if let reminder = recollection.reminder(), let last = messages.last?["content"] as? String,
           messages.last?["role"] as? String == "user" {
            messages[messages.count - 1]["content"] = reminder + "\n\n" + last
        }
        return messages
    }
}

/// An attention cache and the tokens it holds, reused across calls that share
/// a prefix. translate-core's.
struct PromptCache {
    private(set) var kv: [KVCache]
    private let freshCache: () throws -> [KVCache]
    private(set) var tokens: [Int] = []

    init(_ model: any MLXLMCommon.LanguageModel) throws {
        try self.init { try model.newCache(parameters: nil) }
    }

    init(makeCache: @escaping () throws -> [KVCache]) throws {
        freshCache = makeCache
        kv = try makeCache()
    }

    mutating func reset() throws {
        kv = try freshCache()
        tokens = []
    }

    /// Trim back to what `prompt` shares with what is held; returns the part to read.
    mutating func prepare(for prompt: [Int]) throws -> [Int] {
        guard !prompt.isEmpty else { throw Problem("The model produced an empty prompt.") }
        var keep = zip(tokens, prompt).prefix { $0 == $1 }.count
        let offset = kv.first?.offset ?? 0
        keep = min(keep, prompt.count - 1, offset)  // always read at least one token
        let trim = offset - keep
        if trim > 0 && (!canTrimPromptCache(kv) || trimPromptCache(kv, numTokens: trim) != trim) {
            // Sliding attention can no longer rewind once its ring wraps. A
            // failed trim must rebuild, not feed a suffix behind stale tokens.
            try reset()
            keep = 0
        }
        return Array(prompt[keep...])
    }

    /// After a call: the cache holds `held`, and nothing past it.
    mutating func settle(_ held: [Int]) {
        let extra = (kv.first?.offset ?? 0) - held.count
        if extra > 0 { _ = trimPromptCache(kv, numTokens: extra) }
        tokens = Array(held.prefix(kv.first?.offset ?? 0))
    }
}
