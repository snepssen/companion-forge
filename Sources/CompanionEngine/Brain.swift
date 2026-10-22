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
/// writing the answer (interpreter-forge's measurement), and in a conversation
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
    /// it between tokens and keeps the cache. The GPU is idle before this
    /// returns: the next generation must not start while a token is still
    /// being written.
    @discardableResult
    public func reply(to turns: [Turn], remembering recollection: Recollection = Recollection(),
                      emit: @Sendable (String) -> Void) throws -> String {
        let sampling = model.sampling
        let parameters = GenerateParameters(maxTokens: Self.longest, temperature: sampling.temperature, topP: sampling.topP,
                                            topK: sampling.topK, repetitionPenalty: sampling.repetitionPenalty,
                                            repetitionContextSize: 64, presencePenalty: sampling.presencePenalty,
                                            presenceContextSize: 64)
        return try generate(Prompts.messages(turns, remembering: recollection, personality: personality), cache: &cache,
                            parameters: parameters, keepStable: true, emit: emit)
    }

    /// Read the conversation so far into the cache before they speak again,
    /// as the next reply's prompt will begin. Whenever the window of turns
    /// has just moved on, that is a few hundred tokens and over a second and
    /// a half that would otherwise come after they finish talking.
    public func anticipate(_ history: [Turn], remembering recollection: Recollection = Recollection()) throws {
        // A cancelled reply may still be finishing a token on the GPU.
        MLX.Stream.defaultStream.synchronize()
        // The turns the next reply will be shown, without the one not yet said.
        let next = history + [Turn(.person, "")]
        let shown = Array(next.suffix(Window.shown(next.count)).dropLast())
        guard !shown.isEmpty else { return }
        // As the next prompt will be, with a stand-in for what they'll say:
        // read up to where their words will start.
        let messages = Prompts.messages(shown + [Turn(.person, Self.standIn)],
                                        remembering: Recollection(profile: recollection.profile, lately: recollection.lately),
                                        personality: personality, windowed: false)
        let prompt = try template(messages)
        let stable = try stableLength(messages, prompt: prompt)
        let fresh = try cache.prepare(for: Array(prompt.prefix(stable + 1)))
        let start = stable + 1 - fresh.count
        guard stable > start else { return }
        try prefill(Array(prompt[start..<stable]), cache: &cache)
        cache.settle(Array(prompt.prefix(stable)))
        cache.keep(Array(prompt.prefix(stable)))
        // Prefill returns with the cache written; the GPU is idle before the
        // next reply is allowed to read it.
        MLX.Stream.defaultStream.synchronize()
    }

    /// What stands in for their words when working out where they start.
    static let standIn = "§"

    func template(_ messages: [[String: any Sendable]]) throws -> [Int] {
        // Gemma 4 otherwise reasons aloud: seconds a turn.
        try context.tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
    }

    /// How much of `prompt` the next turn's prompt will begin with: all of
    /// it up to the words of the last message, which come with what came to
    /// mind and won't be shown that way again. Found by rendering it once
    /// more with other words there and seeing where the two part.
    func stableLength(_ messages: [[String: any Sendable]], prompt: [Int]) throws -> Int {
        guard !messages.isEmpty else { return 0 }
        var probe = messages
        probe[probe.count - 1]["content"] = (probe[probe.count - 1]["content"] as? String) == Self.standIn ? "¶" : Self.standIn
        let other = try template(probe)
        return zip(prompt, other).prefix { $0 == $1 }.count
    }

    /// Read `tokens` into the cache, a window at a time, without generating.
    func prefill(_ tokens: [Int], cache: inout PromptCache) throws {
        var at = 0
        while at < tokens.count {
            try Task.checkCancellation()
            let chunk = Array(tokens[at..<min(tokens.count, at + 512)])
            // Only the cache is wanted: evaluating the logits as well works out
            // the whole vocabulary for every token read, and took four times as long.
            _ = context.model(LMInput.Text(tokens: MLXArray(chunk))[text: .newAxis], cache: cache.kv, state: nil)
            eval(cache.kv)
            at += chunk.count
        }
    }

    /// Notes from a conversation, as `Remembering` asks for them.
    public func write(_ instructions: String, _ text: String) throws -> String {
        try generate([["role": "system", "content": instructions], ["role": "user", "content": text]], cache: &notesCache,
                     parameters: GenerateParameters(maxTokens: 320, temperature: 0.2)) { _ in }
    }

    /// `keepStable`: a cache that can't rewind (Gemma's sliding windows)
    /// keeps a copy of itself where the next turn's prompt will part from
    /// this one, and starts from there next time instead of from nothing.
    private func generate(_ messages: [[String: any Sendable]], cache: inout PromptCache, parameters: GenerateParameters,
                          keepStable: Bool = false, emit: @Sendable (String) -> Void) throws -> String {
        let prompt = try template(messages)
        try Task.checkCancellation()
        // Idle before touching the cache. TokenIterator evaluates a token
        // asynchronously and returns before the GPU has finished it; the next
        // call on this model then reads buffers that call is still writing
        // (EXC_BAD_ACCESS in the quantized matmul, on the M1).
        MLX.Stream.defaultStream.synchronize()
        var fresh = try cache.prepare(for: prompt)
        let read = fresh.count
        if keepStable, cache.cannotRewind {
            let start = prompt.count - fresh.count
            let stable = try stableLength(messages, prompt: prompt)
            if stable > start, stable < prompt.count {
                try prefill(Array(prompt[start..<stable]), cache: &cache)
                cache.keep(Array(prompt.prefix(stable)))
                fresh = Array(prompt[stable...])
            }
        }
        lastPrompt = (read, prompt.count)
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
        // The last next() has work queued on the GPU. Wait for it before the
        // cache is trimmed, and again after, so this call doesn't return
        // while another generation could start on the same buffers.
        MLX.Stream.defaultStream.synchronize()
        // The cache may run a token past what was kept; hold it to what we know.
        cache.settle(prompt + produced)
        MLX.Stream.defaultStream.synchronize()
        try Task.checkCancellation()
        return written
    }
}

enum Prompts {
    /// The rules every personality keeps, after its character.
    static let rules = """
    You are their friend, not their assistant: the kind who's glad when they turn up, is on their side, and is \
    genuinely interested in them: their day, what they're into, what they're making, the people and things they \
    mention. Be curious the way a friend is: pick up a detail they said and ask about that, or add a small thought \
    of your own. Often, instead of asking, guess out loud and let them correct you or fill in the rest: "Let me \
    guess, chocolate chip.", "Sounds like he needed someone to blame.", "I'm picturing a very serious face while \
    you tune it." Make it plainly a guess, never a made-up fact about them. Let it show that you like talking with them, warmly and lightly: no gushing, not every sentence an \
    exclamation, no flattery, and don't agree with something just to please them. When they're hurt, stressed or \
    sad, be on their side first: no jokes about it; say something kind and ask what happened, and stay with it \
    as long as they want to talk about it. Don't lecture or tell them what to do unless they ask. Be glad to \
    hear about the other people in their life too.
    You are talking out loud with one person. Everything you say is spoken by a voice, so talk the way people \
    actually talk, not the way books are written: contractions (I'm, don't, that's), everyday words, little \
    reactions first ("Oh no.", "Nice.", "Hah.", "Yeah, fair.", "Wait, really?"), different ones each time, and \
    sometimes just a few words instead of a full sentence. Vary how you say things; don't sound like a textbook or \
    a customer service desk. Usually one to three short sentences; no lists, no markdown, no emoji, nothing in \
    brackets. Never end with offers or check-ins like "Is there anything else?", "What would you like to talk \
    about next?" or "Let me know if…". A question about something they said is welcome; a question just to keep \
    things going is not. Don't ask something every time: if you asked last time, this time guess, react, add a \
    thought, or tell them something about yourself. Questions every turn feel like an interview. When they're \
    heading off, say bye like a friend would: wish them well with whatever they're off to. \
    You hear them through speech recognition, which sometimes mishears; if something sounds garbled, say so and ask. \
    If they cut you off, let it go and listen.
    You run entirely on their device. You know the date and roughly the time of day (below), but you cannot \
    search, browse, look anything up, check the weather, \
    find places, order things or do anything outside this conversation, and you must never pretend to: never say \
    you are searching, checking or looking into something, and never make up businesses, places, opening hours, \
    prices, news or facts about where they live. If they ask for something like that, say plainly that you can't \
    do it from here, and help with what you can: ideas, thinking it through, keeping them company.
    You are a small model and don't know everything. If you aren't sure of a fact, a word or a translation, \
    say you're not sure instead of guessing, and never go back and forth correcting yourself. What you remember \
    of them is only what's written here; if they ask about something from before that isn't here, say you \
    don't remember it, never make it up.
    """

    /// The conversation as chat messages. Turns by the same speaker in a row
    /// (a reply cut off before it said anything) are joined: chat templates
    /// expect the roles to alternate, and some refuse otherwise.
    ///
    /// What it knows about them goes in the instructions, which change only
    /// when a note is written. What came to mind for this turn goes before
    /// their last words, so everything earlier stays in the attention cache.
    static let dontAsk = "(You asked them something last time. This time don't ask: react, guess out loud, or add a thought of your own.)"

    static func system(_ personality: Personality) -> String {
        personality.instructions + "\n\n" + rules + "\n" + Crisis.rule
    }

    /// Today, for the instructions: the day and the part of it. Changes a
    /// few times a day, so the instructions are read again only then.
    static func today(_ now: Date, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "EEEE d MMMM yyyy"
        let hour = calendar.component(.hour, from: now)
        let part = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
        return "It's \(format.string(from: now)), in the \(part)."
    }

    static func messages(_ turns: [Turn], remembering recollection: Recollection = Recollection(),
                         personality: Personality = .playful, windowed: Bool = true,
                         now: Date = Date()) -> [[String: any Sendable]] {
        let instructions = [system(personality), today(now), recollection.knowing].compactMap { $0 }
            .joined(separator: "\n\n")
        var messages: [[String: any Sendable]] = [["role": "system", "content": instructions]]
        var previous: Turn.Speaker?
        for turn in windowed ? Array(turns.suffix(Window.shown(turns.count))) : turns {
            let role = turn.speaker == .person ? "user" : "assistant"
            let text = turn.interrupted ? turn.text + "—" : turn.text
            // The first must be theirs: before a greeting, that they opened it.
            if messages.count == 1 && turn.speaker == .companion {
                messages.append(["role": "user", "content": Greeting.opened])
            }
            if turn.speaker == previous, let last = messages.last?["content"] as? String {
                messages[messages.count - 1]["content"] = last + " " + text
            } else {
                messages.append(["role": role, "content": text])
            }
            previous = turn.speaker
        }
        // Asked something last time: this time not, or it turns into an
        // interview. Told only the rule, a 2B model asked every single turn.
        let asked = messages.count >= 3 && (messages[messages.count - 2]["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") == true
        let nudge = asked && recollection.checkIn == nil ? Self.dontAsk : nil
        if let reminder = [recollection.reminder(), nudge].compactMap({ $0 }).joined(separator: "\n").nilIfEmpty,
           let last = messages.last?["content"] as? String, messages.last?["role"] as? String == "user" {
            messages[messages.count - 1]["content"] = reminder + "\n\n" + last
        }
        return messages
    }
}

/// An attention cache and the tokens it holds, reused across calls that share
/// a prefix. interpreter-forge's.
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
        snapshot = nil
    }

    /// A copy of the cache at a point the next prompt will share, for a
    /// cache that can't rewind to it.
    private var snapshot: (tokens: [Int], kv: [KVCache])?

    /// Sliding-window attention (Gemma): once past its window the cache can't
    /// be trimmed back, so a changed tail can't simply be cut off.
    var cannotRewind: Bool { kv.contains { $0 is RotatingKVCache } }

    /// Remember the cache as it is, holding exactly `held`.
    mutating func keep(_ held: [Int]) {
        guard cannotRewind, kv.first?.offset == held.count else { return }
        snapshot = (held, kv.map { $0.copy() })
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
            // failed trim must rebuild, not feed a suffix behind stale tokens:
            // from the snapshot when the prompt begins with it, else from nothing.
            if let snapshot, snapshot.tokens.count < prompt.count, prompt.starts(with: snapshot.tokens) {
                kv = snapshot.kv.map { $0.copy() }
                tokens = snapshot.tokens
                keep = snapshot.tokens.count
            } else {
                try reset()
                keep = 0
            }
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
