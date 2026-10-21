import CompanionCore
import Foundation

/// The memory: notes written from the conversation logs, found again by
/// meaning before each reply. Kept in `memory.json` beside the logs.
public actor Memory {
    public private(set) var store: MemoryStore
    private let file: URL
    private let conversations: URL
    private let embedder: Embedder

    public init(file: URL = Resources.memory, conversations: URL = Resources.conversations, embedder: Embedder) {
        self.file = file
        self.conversations = conversations
        self.embedder = embedder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        store = (try? decoder.decode(MemoryStore.self, from: Data(contentsOf: file))) ?? MemoryStore()
        // Notes written before the companion learned to keep itself out of them.
        let loaded = store
        for note in store.notes where !Remembering.isAboutThem(note.text) { store.forget(note.id) }
        for note in store.notes where !note.lasting && Remembering.looksLasting(note.text) {
            store.forget(note.id)
            var lasting = note
            lasting.lasting = true
            store.add(lasting)
        }
        store.dateCheckIns()
        if store != loaded { try? Self.write(store, to: file) }
    }

    public var notes: [Note] { store.notes.sorted { $0.at > $1.at } }
    public var profile: [Note] { store.profile }

    /// What comes to mind for what they just said.
    public func recollect(for text: String, now: Date = Date()) async -> Recollection {
        let profile = store.profile
        guard store.notes.contains(where: { !$0.lasting }) else { return Recollection(profile: profile) }
        let vector = await embedder.embed([text], query: true)[0]
        let found = store.recall(text, vector: vector, now: now).map(\.note)
        var excerpt: [Turn] = []
        if Remembering.asksAboutThePast(text), let best = found.first {
            excerpt = turns(behind: best)
        }
        return Recollection(profile: profile, notes: found, excerpt: excerpt)
    }

    /// The best few notes for `text` and their scores, relevant or not: for measuring.
    public func scores(for text: String) async -> [(note: Note, score: Double)] {
        let vector = await embedder.embed([text], query: true)[0]
        return store.recall(text, vector: vector, limit: 4, atLeast: -1)
    }

    /// The turns a note was written from, a turn either side, at most eight.
    func turns(behind note: Note) -> [Turn] {
        guard let all = try? ConversationLog.read(conversations.appending(path: "\(note.session).jsonl")) else { return [] }
        let low = max(0, note.turns.lowerBound - 1)
        let high = min(all.count - 1, note.turns.upperBound + 1, low + 7)
        return low <= high ? Array(all[low...high]) : []
    }

    /// Write notes from every conversation not yet written up, oldest first;
    /// returns how many were added. Cancelling stops between notes and keeps
    /// what is done: the rest is written next time.
    @discardableResult
    public func writeUp(with brain: Brain) async throws -> Int {
        let logs = ((try? FileManager.default.contentsOfDirectory(at: conversations, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var added = 0
        for log in logs {
            let session = log.deletingPathExtension().lastPathComponent
            let turns = (try? ConversationLog.read(log)) ?? []
            var next = store.next(in: session)
            while turns.count - next >= Remembering.fewest {
                try Task.checkCancellation()
                let end = min(turns.count, next + Remembering.chunk)
                let shown = (next..<end).map { (index: $0, turn: turns[$0]) }
                let answer = try await brain.write(Remembering.instructions,
                                                   Remembering.transcript(shown, known: store.profile.map(\.text)))
                let written = Remembering.parse(answer, turns: next...(end - 1))
                // The diary entry for this stretch, which the calendar points back to.
                var diary: JournalEntry?
                let transcript = Remembering.transcript(shown, known: [])
                if let text = Journal.entry(from: try await brain.write(Journal.instructions, transcript)) {
                    let entry = JournalEntry(at: turns[end - 1].at, session: session, turns: next...(end - 1), text: text,
                                             vector: await embedder.embed([text])[0])
                    store.write(entry)
                    diary = entry
                }
                let vectors = await embedder.embed(written.map(\.text))
                for (note, vector) in zip(written, vectors) {
                    let at = turns[note.turns.upperBound].at
                    let made = Note(text: note.text, session: session, turns: note.turns, at: at,
                                    lasting: note.lasting, vector: vector, due: CheckIn.due(note.text, said: at))
                    store.add(made)
                    if !CheckIn.happened(note.text), let when = When.read(note.text, said: at) {
                        store.plan(Happening(text: note.text, when: when, note: made.id, journal: diary?.id))
                    }
                }
                // What the diary dated and the notes missed.
                if let diary {
                    for sentence in Journal.sentences(diary.text) where !CheckIn.happened(sentence) {
                        if let when = When.read(sentence, said: diary.at) {
                            store.plan(Happening(text: sentence, when: when, journal: diary.id))
                        }
                    }
                }
                store.tidyCalendar()
                added += written.count
                store.wrote(session, through: end)
                next = end
                try save()
            }
        }
        return added
    }

    /// Note something at once, because they asked, in their own words.
    @discardableResult
    public func remember(_ what: String, session: String, turn: Int, at date: Date = Date()) async throws -> Note {
        let text = MemoryCommand.note(for: what)
        let vector = await embedder.embed([text])[0]
        let note = Note(text: text, session: session, turns: turn...turn, at: date, lasting: false, vector: vector)
        store.add(note)
        try save()
        return note
    }

    /// The note closest to what they asked to be forgotten, lasting ones
    /// included, if any is close enough to be the one they meant.
    public func closest(to what: String) async -> Note? {
        let vector = await embedder.embed([what], query: true)[0]
        return store.recall(what, vector: vector, limit: 1, lasting: true).first?.note
    }

    /// Something to catch up on now, if anything has fallen due.
    public func checkIn(now: Date = Date()) -> Note? { CheckIn.pick(store.notes, now: now) }

    /// Something on their calendar today or tomorrow to remind them of.
    public func ahead(now: Date = Date()) -> (day: Date, happening: Happening)? {
        Agenda.ahead(store.calendar, now: now)
    }

    /// It reminded them of `id`.
    public func reminded(_ id: String, at date: Date = Date()) {
        store.reminded(id, at: date)
        try? save()
    }

    /// The answer to asking what's coming up or what they did.
    public func agenda(_ ask: Agenda.Ask) -> String {
        Agenda.answer(ask, happenings: store.calendar, journal: store.journal)
    }

    /// It asked them about note `id`: not again.
    public func checkedIn(_ id: String, at date: Date = Date()) {
        store.checked(id, at: date)
        try? save()
    }

    public func forget(_ id: String) throws {
        store.forget(id)
        try save()
    }

    /// Every note, and every conversation they were written from.
    public func forgetEverything() throws {
        store.forgetAll()
        try save()
        for log in (try? FileManager.default.contentsOfDirectory(at: conversations, includingPropertiesForKeys: nil)) ?? []
        where log.pathExtension == "jsonl" {
            try FileManager.default.removeItem(at: log)
        }
    }

    private func save() throws { try Self.write(store, to: file) }

    private static func write(_ store: MemoryStore, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(store).write(to: file, options: .atomic)
    }
}
