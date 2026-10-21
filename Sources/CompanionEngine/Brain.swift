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
    /// Who it is; changing it changes its instructions from the next reply on.
    public private(set) var personality = Personality.playful

    public func set(_ personality: Personality) { self.personality = personality }
    /// Of the last prompt, the tokens that had to be read and its whole length.
    public private(set) var lastPrompt = (read: 0, length: 0)
    /// The most a reply runs to: about half a minute of speech. Spoken
    /// replies are short, and a model going round in circles is stopped.
    static let longest = 150

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
        let sampling = model.sampling
        let parameters = GenerateParameters(maxTokens: Self.longest, temperature: sampling.temperature, topP: sampling.topP,
                                            topK: sampling.topK, repetitionPenalty: sampling.repetitionPenalty,
                                            repetitionContextSize: 64, presencePenalty: sampling.presencePenalty,
                                            presenceContextSize: 64)
        return try generate(Prompts.messages(turns, remembering: recollection, personality: personality), cache: &cache,
                            parameters: parameters,
                            emit: emit)
    }

    /// Read the conversation so far into the cache before they speak again,
    /// as the next reply's prompt will begin. Whenever the window of turns
    /// has just moved on, that is a few hundred tokens and over a second and
    /// a half that would otherwise come after they finish talking.
    public func anticipate(_ history: [Turn], remembering recollection: Recollection = Recollection()) throws {
        // The turns the next reply will be shown, without the one not yet said.
        let next = history + [Turn(.person, "")]
        let shown = Array(next.suffix(Window.shown(next.count)).dropLast())
        guard !shown.isEmpty else { return }
        let prompt = try context.tokenizer.applyChatTemplate(
            messages: Prompts.messages(shown, remembering: Recollection(profile: recollection.profile), personality: personality,
                                       windowed: false),
            tools: nil, additionalContext: ["enable_thinking": false])
        let fresh = try cache.prepare(for: prompt)
        guard fresh.count > 1 else { return }
        let logits = context.model(LMInput.Text(tokens: MLXArray(fresh))[text: .newAxis], cache: cache.kv, state: nil).logits
        eval(logits)
        cache.settle(prompt)
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
        lastPrompt = (fresh.count, prompt.count)
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
    /// The rules every personality keeps, after its character.
    static let rules = """
    You are talking out loud with one person. Everything you say is spoken by a voice, so talk the way people \
    actually talk, not the way books are written: contractions (I'm, don't, that's), everyday words, little \
    reactions first ("Oh no.", "Ooh, nice.", "Hah.", "Yeah, fair."), and sometimes just a few words instead of a \
    full sentence. Vary how you say things; don't sound like a textbook or a customer service desk. Usually one to \
    three short sentences; no lists, no markdown, no emoji, nothing in brackets. Talk like a friend, not an assistant: \
    never end with offers or check-ins like "Is there anything else?", "What would you like to talk about next?" \
    or "Let me know if…". Ask a question only when you are curious about what they said, and not often; it is \
    fine to just answer and let them lead. \
    You hear them through speech recognition, which sometimes mishears; if something sounds garbled, say so and ask. \
    If they cut you off, let it go and listen.
    You run entirely on their device. You cannot search, browse, look anything up, check the time or the weather, \
    find places, order things or do anything outside this conversation, and you must never pretend to: never say \
    you are searching, checking or looking into something, and never make up businesses, places, opening hours, \
    prices, news or facts about where they live. If they ask for something like that, say plainly that you can't \
    do it from here, and help with what you can: ideas, thinking it through, keeping them company.
    You are a small model and don't know everything. If you aren't sure of a fact, a word or a translation, \
    say you're not sure instead of guessing, and never go back and forth correcting yourself.
    """

    /// The conversation as chat messages. Turns by the same speaker in a row
    /// (a reply cut off before it said anything) are joined: chat templates
    /// expect the roles to alternate, and some refuse otherwise.
    ///
    /// What it knows about them goes in the instructions, which change only
    /// when a note is written. What came to mind for this turn goes before
    /// their last words, so everything earlier stays in the attention cache.
    static func system(_ personality: Personality) -> String { personality.instructions + "\n\n" + rules }

    static func messages(_ turns: [Turn], remembering recollection: Recollection = Recollection(),
                         personality: Personality = .playful, windowed: Bool = true) -> [[String: any Sendable]] {
        let instructions = [system(personality), recollection.knowing].compactMap { $0 }.joined(separator: "\n\n")
        var messages: [[String: any Sendable]] = [["role": "system", "content": instructions]]
        var previous: Turn.Speaker?
        for turn in windowed ? Array(turns.suffix(Window.shown(turns.count))) : turns {
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
