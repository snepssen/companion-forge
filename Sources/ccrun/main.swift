// Recorded speech through the live loop in real time, for measuring without a
// microphone: the turn taker, recognition, the model and the voice as the app
// runs them, with the reply's own voice leaking back into the "microphone" at
// a chosen level, as it would past the echo canceller.
//
//   ccrun                       a short conversation, with an interruption
//   ccrun --echo 0.3            the same with far more echo leaking through
//   ccrun --delay 0.15          with the echo coming back that much late, as off a room
//   ccrun --shake               with the phone shaken between turns
//   ccrun --commands            asked out loud to remember something, then to forget it
//   ccrun --from-right          spoken to from the right of a stereo microphone, then the left
//   ccrun --model qwen3-4b-instruct-2507-4bit
//   ccrun --faces <folder>      the face in each mood and some visemes, as PNGs
//         [--style smooth] [--colour magenta] [--hearing 0.05]   (also for --window)
//   ccrun --window <file.png>   the app's window, loaded as the app loads it
//   ccrun --memory              earlier conversations written up, then recalled
//   ccrun --journal             a conversation written up into notes, diary and calendar, then asked about
//   ccrun --speakers <folder>   how well each voiceprint model tells voices apart (<voice>__<n>.wav)
//   ccrun --weeks               three weeks of conversations into diary and week summaries, then asked about
//   ccrun --icon <file.png>     the app icon, 1024 px
//   ccrun --spatial-check       the spatial voice's audio graph, run silently
//   ccrun --lipsync "text"      the mouth from the voice's phoneme timings, beside the spelling estimate
//   ccrun --say "text" [--hint ro]  out loud, each part in its language
//   ccrun --intonation "words" [--quiet]  as statement, question and exclamation: pitch measured, then heard
//   ccrun --beats <audio file>  the kicks the face would dance to, and when it would
//   ccrun --wav "a | b" --out <folder>  each line to a WAV, through the polyglot voice
//   ccrun --recall              how the embedder ranks notes, for the thresholds
//   ccrun --long [--anticipate] a long conversation: prompt re-reading and first-word times
//   ccrun --ask "a | b" [--chat] each said to it on its own (--chat: as one conversation), and its answer
//
// Built with build.sh's xcodebuild (MLX needs its Metal library beside it):
//   .build/xcode/Build/Products/Release/ccrun
import CompanionCore
import CryptoKit
import CompanionEngine
import CompanionUI
import Foundation
import SampleBuffer
import SileroVAD
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

enum Run { static let started = Duplex.now }
func stamp() -> String { String(format: "[%6.2f]", Duplex.now - Run.started) }
func say(_ line: String) {
    print("\(stamp()) \(line)")
    fflush(stdout)
}

/// What iOS would hold against the app: its physical footprint, now and at
/// its peak, in GB. On Apple silicon it includes what MLX has on the GPU.
func footprint() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1e9, Double(info.ledger_phys_footprint_peak) / 1e9)
}

func resample(_ samples: [Float], from rate: Double, to target: Double = 16_000) -> [Float] {
    guard rate != target, !samples.isEmpty else { return samples }
    let count = Int(Double(samples.count) * target / rate)
    return (0..<count).map { index in
        let position = Double(index) * rate / target
        let low = Int(position)
        let high = min(low + 1, samples.count - 1)
        let fraction = Float(position - Double(low))
        return samples[low] * (1 - fraction) + samples[high] * fraction
    }
}

// MARK: faces

/// --style, --colour and --hearing, for the renders.
@MainActor
func look() -> (style: VisorStyle, colour: VisorColour, hearing: Double) {
    (VisorStyle(rawValue: option("--style") ?? "") ?? .panel, VisorColour(rawValue: option("--colour") ?? "") ?? .cyan,
     Double(option("--hearing") ?? "0") ?? 0)
}

@MainActor
func faces(into folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func write(_ name: String, _ pose: Pose) throws {
        let look = look()
        guard let image = FaceView.image(pose, size: CGSize(width: 640, height: 400), colour: look.colour.color,
                                         style: look.style, hearing: look.hearing),
              let destination = CGImageDestinationCreateWithURL(folder.appending(path: "\(name).png") as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "ccrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't render \(name)"]) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        print("  \(folder.appending(path: "\(name).png").path)")
    }
    for mood in [Mood.idle, .listening, .thinking, .speaking, .cheerful, .surprised, .waking, .sleepy] {
        var performance = FacePerformance(origin: 0)
        performance.set(mood, at: 0)
        try write("mood-\(mood.rawValue)", performance.pose(at: 2))
    }
    var looking = FacePerformance(origin: 0)
    for (index, at) in [3.0, 9.0, 17.0].enumerated() {
        try write("gaze-idle-\(index + 1)", looking.pose(at: at))
    }
    looking.set(.thinking, at: 0)
    try write("gaze-thinking", looking.pose(at: 2))
    try write("shaken", Felt(offset: Point(-0.06, 0.03), tilt: -9, shaken: 1).apply(to: FacePerformance(origin: 0).pose(at: 2)))
    for viseme in [Viseme.ah, .oo, .ee] {
        let face = Mood.speaking.expression.face
        try write("viseme-\(viseme.rawValue)",
                  Pose(face: Face(face.eye, viseme.mouth, sharpness: face.sharpness), offset: .zero, tilt: 0, muzzle: .zero))
    }
}

/// The app's window as the app loads it, rendered once it is ready.
@MainActor
func window(into file: URL) async throws {
    UserDefaults.standard.set(look().style.rawValue, forKey: "visorStyle")
    UserDefaults.standard.set(look().colour.rawValue, forKey: "visorColour")
    let companion = Companion()
    companion.listensWhenReady = false  // nobody here to listen to
    await companion.prepare()
    print("phase: \(companion.phase)")
    let view = ContentView(companion: companion).frame(width: 760, height: 620)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "ccrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't render the window"]) }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("  \(file.path)")
}

/// The app icon: the visor in its idle smirk, on black, 1024 px square.
@MainActor
func icon(into file: URL) throws {
    var performance = FacePerformance(origin: 0)
    performance.set(.idle, at: 0)
    var pose = performance.pose(at: 2)
    pose.offset = .zero
    pose.tilt = 0
    pose.muzzle = .zero
    guard let image = FaceView.image(pose, size: CGSize(width: 512, height: 512)),
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "ccrun", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't render the icon"]) }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("  \(file.path)")
}

if let file = option("--icon") {
    try await MainActor.run { try icon(into: URL(fileURLWithPath: file)) }
    exit(0)
}

if let file = option("--window") {
    try await window(into: URL(fileURLWithPath: file))
    exit(0)
}

/// How the embedder ranks a few notes for a few things someone might say,
/// and how alike it finds a repeat and a change: for setting the thresholds.
func recall() async throws {
    let embedder = try await Embedder.load { print(String(format: "  downloading the embedder… %.0f%%", $0 * 100)) }
    let notes = ["They have no eggs at home.", "They walked by the river this evening and loved it.",
                 "Their dog is called Biscuit.", "They work as a nurse on night shifts.",
                 "They are learning to play the guitar.", "Their sister Ana is visiting next week."]
    let queries = ["What should I make for breakfast?", "I took the dog out earlier", "work was exhausting tonight",
                   "I practiced some chords today", "do you remember where I went walking?", "My dog Biscuit is sick.",
                   "Guess who's coming to stay with me?", "What's the weather like?"]
    let noteVectors = await embedder.embed(notes)
    for query in queries {
        let vector = await embedder.embed([query], query: true)[0]
        print(query)
        for (note, noteVector) in zip(notes, noteVectors) {
            print(String(format: "   %.2f  %@", MemoryStore.cosine(vector, noteVector), note))
        }
    }
    let pairs = [("They have no eggs at home.", "They don't have any eggs in the house."),
                 ("Their dog is called Biscuit.", "Their dog Biscuit is three years old."),
                 ("They live in York.", "They moved to Leeds."),
                 ("They work as a nurse on night shifts.", "They are learning to play the guitar.")]
    for (a, b) in pairs {
        let v = await embedder.embed([a, b])
        print(String(format: "%.2f  %@ / %@", MemoryStore.cosine(v[0], v[1]), a, b))
    }
}

/// Two earlier conversations written up by the model, then new things said
/// to it: what comes to mind, and the reply with it. In a folder of its own,
/// so the app's memory is untouched.
/// A conversation from two days ago written up as the app does at idle:
/// the notes, the diary entry and the calendar it leaves, then asked what's
/// coming up, what they did, and told something ordinary while tomorrow's
/// birthday is due a mention.
/// Conversations over three weeks written up into diary entries and the
/// diary into week summaries, then asked how they've been lately and about
/// something from back then.
func weeksRun() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ccrun-weeks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let conversations = folder.appending(path: "Conversations")
    let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
    guard let directory = ModelStore.location(of: model) else { print("\(model.name) isn't downloaded"); return }
    let brain = try await Brain(model: model, at: directory)
    let memory = Memory(file: folder.appending(path: "memory.json"), conversations: conversations,
                        embedder: try await Embedder.load())
    let earlier: [(daysAgo: Double, turns: [String])] = [
        (12, ["First day at the new studio today! Everyone's really nice.", "I'm designing a poster for a jazz festival."]),
        (10, ["Went to see a gig with Sam last night, this tiny band called Moth Radio. So good.", "My ears are still ringing."]),
        (8, ["Rough day. The client hated the poster and my boss sided with them.", "I stayed late redoing it. I'm exhausted."]),
        (2, ["Feeling better. The new poster got approved!", "Sam's taking me climbing on Saturday to celebrate."]),
    ]
    for conversation in earlier {
        let started = Date() - conversation.daysAgo * 86_400
        let log = try ConversationLog(directory: conversations, started: started)
        for (index, text) in conversation.turns.enumerated() {
            try log.append(Turn(.person, text, at: started + Double(index) * 60))
            try log.append(Turn(.companion, "Mm.", at: started + Double(index) * 60 + 20))
        }
    }
    try await memory.writeUp(with: brain)
    let store = await memory.store
    print("diary:"); for entry in store.journal { print("  \(entry.at.formatted(date: .abbreviated, time: .omitted)): \(entry.text)") }
    print("weeks:"); for week in store.weeks { print("  from \(week.week.formatted(date: .abbreviated, time: .omitted)): \(week.text)") }
    print("lately: \(await memory.standing().lately ?? "-")")
    var conversation: [Turn] = []
    for line in ["Hey.", "How have I been lately, do you think?", "Remember that band I saw with Sam? What were they called?"] {
        conversation.append(Turn(.person, line))
        var recollection = await memory.recollect(for: line)
        if let ask = Agenda.ask(in: line) { recollection.aside = await memory.agenda(ask) }
        let reply = try await brain.reply(to: conversation, remembering: recollection) { _ in }
        conversation.append(Turn(.companion, reply))
        print("you: \(line)\n  it: \(reply)")
    }
}

func journalRun() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ccrun-journal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let conversations = folder.appending(path: "Conversations")
    let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
    guard let directory = ModelStore.location(of: model) else { print("\(model.name) isn't downloaded"); return }
    let brain = try await Brain(model: model, at: directory)
    let memory = Memory(file: folder.appending(path: "memory.json"), conversations: conversations,
                        embedder: try await Embedder.load())
    let day: TimeInterval = 86_400
    let said = Date() - 2 * day
    let format = DateFormatter()
    format.dateFormat = "d MMMM"
    let birthday = format.string(from: Date() + day)
    format.dateFormat = "EEEE"
    let dentist = format.string(from: Date() + 4 * day)
    let interview = format.string(from: Date() - day)
    let turns: [(Turn.Speaker, String)] = [
        (.person, "Ugh, I have a job interview on \(interview) and I'm already nervous."),
        (.companion, "That's a big one. What's the job?"),
        (.person, "Junior designer at a little studio in town."),
        (.companion, "Ooh, that sounds right up your street."),
        (.person, "Also I need to sort out a present, my mum's birthday is on \(birthday)."),
        (.companion, "Any ideas yet?"),
        (.person, "Maybe a plant. She kills them all though. And I've got the dentist on \(dentist), which I'm dreading."),
        (.companion, "Hah. Plants and dentists, a brave week."),
    ]
    let log = try ConversationLog(directory: conversations, started: said)
    for (index, (speaker, text)) in turns.enumerated() { try log.append(Turn(speaker, text, at: said + Double(index) * 20)) }
    let began = Duplex.now
    try await memory.writeUp(with: brain)
    print(String(format: "written up in %.1f s", Duplex.now - began))
    let store = await memory.store
    print("notes:"); for note in store.notes { print("  \(note.text)\(note.due.map { " (ask after \($0.formatted()))" } ?? "")") }
    print("diary:"); for entry in store.journal { print("  \(entry.at.formatted()): \(entry.text)") }
    print("calendar:")
    for happening in store.calendar {
        print("  \(happening.when.day.formatted(date: .abbreviated, time: .omitted)) \(happening.when.part.rawValue)"
              + "\(happening.when.yearly ? " yearly" : ""): \(happening.text)\(happening.journal == nil ? "" : " [diary]")")
    }
    var conversation: [Turn] = []
    for line in ["Hey!", "What's on this week?", "What did I talk to you about on \(format.string(from: said))?",
                 "I'm making tea, it's freezing in here."] {
        conversation.append(Turn(.person, line))
        var recollection = await memory.recollect(for: line)
        if let ask = Agenda.ask(in: line) { recollection.aside = await memory.agenda(ask) }
        else if conversation.count >= 3, let (day, happening) = await memory.ahead() {
            (recollection.coming, recollection.comingDay) = (happening, day)
            print("  (reminding: \(happening.text))")
        } else if conversation.count >= 3, let note = await memory.checkIn() {
            recollection.checkIn = note
            print("  (catching up: \(note.text))")
        }
        let reply = try await brain.reply(to: conversation, remembering: recollection) { _ in }
        conversation.append(Turn(.companion, reply))
        print("you: \(line)\n  it: \(reply)")
    }
}

func memoryRun() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ccrun-memory-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let conversations = folder.appending(path: "Conversations")
    let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
    guard let directory = ModelStore.location(of: model) else { print("\(model.name) isn't downloaded"); return }
    let brain = try await Brain(model: model, at: directory)
    let embedder = try await Embedder.load()
    let memory = Memory(file: folder.appending(path: "memory.json"), conversations: conversations, embedder: embedder)

    let day: TimeInterval = 86_400
    let earlier: [(daysAgo: Double, turns: [(Turn.Speaker, String)])] = [
        (6, [(.person, "Hi! I'm Sam, by the way."), (.companion, "Nice to meet you, Sam!"),
             (.person, "I work night shifts as a nurse, so I'm usually up at odd hours."),
             (.companion, "That sounds tiring. How do you wind down?"),
             (.person, "Mostly walks with my dog Biscuit. He's a beagle and he's obsessed with the river."),
             (.companion, "Biscuit sounds like great company."),
             (.person, "Oh, and my sister Ana is visiting next Saturday. I'm a bit nervous, we haven't talked in a year."),
             (.companion, "That's a big visit. I hope it goes well."),
             (.person, "Anyway, what's the capital of Australia?"), (.companion, "Canberra.")]),
        (1, [(.person, "No, we have a new roommate."), (.companion, "Oh really? A roommate?"),
             (.person, "Yes, it's you."),
             (.companion, "Wait, me? You mean you have a new roommate, and I am that roommate?"),
             (.person, "Yes."), (.companion, "That's kind of weird. What's your name?"), (.person, "Lin"),
             (.companion, "Lin. Okay. It's nice to meet you."), (.person, "Nice to meet you too. What's your name?"),
             (.companion, "I don't really have a name. You can just call me Companion."),
             (.person, "Okay, your name will be Tom."), (.companion, "Tom sounds good. I like that.")]),
        (2, [(.person, "I've started learning the guitar. My fingers hurt so much."),
             (.companion, "That's normal at first. What are you practising?"),
             (.person, "Just G, C and D for now. I want to play a song for Ana when she comes."),
             (.companion, "That's a lovely idea."),
             (.person, "Also I ran out of eggs, I keep forgetting to buy them."), (.companion, "Add them to a list!")]),
    ]
    for conversation in earlier {
        let started = Date() - conversation.daysAgo * day
        let log = try ConversationLog(directory: conversations, started: started)
        for (index, (speaker, text)) in conversation.turns.enumerated() {
            try log.append(Turn(speaker, text, at: started + Double(index) * 20))
        }
    }

    let began = Duplex.now
    let added = try await memory.writeUp(with: brain)
    print(String(format: "wrote %d notes in %.1f s:", added, Duplex.now - began))
    for note in await memory.notes {
        print("  \(note.lasting ? "(lasting) " : "")[\(note.turns.lowerBound)-\(note.turns.upperBound)] \(note.text)")
    }
    let again = try await memory.writeUp(with: brain)
    print("written up again: \(again) new notes")

    let asked = ["What should I make for breakfast?", "Ugh, work was exhausting tonight.",
                 "Do you remember what I told you about my sister?", "What's the weather like where you are?",
                 "I practised those chords again today."]
    for text in asked {
        print("")
        print("you: \(text)")
        let started = Duplex.now
        let recollection = await memory.recollect(for: text)
        print(String(format: "  recalled in %.0f ms:", (Duplex.now - started) * 1000))
        for (note, score) in await memory.scores(for: text) { print(String(format: "      %.3f %@", score, note.text)) }
        for note in recollection.notes { print("    \(note.text)") }
        if !recollection.excerpt.isEmpty {
            print("    and word for word:")
            for turn in recollection.excerpt { print("      \(turn.speaker == .person ? "them" : "it"): \(turn.text)") }
        }
        if !CommandLine.arguments.contains("--no-replies") {
            let reply = try await brain.reply(to: [Turn(.person, text)], remembering: recollection) { _ in }
            print("  companion: \(reply)")
        }
    }
}

/// A long conversation in text: how much of each prompt the model has to read
/// again, and how soon its first words come, as the conversation outgrows
/// the window of turns it is shown.
func longRun() async throws {
    let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
    guard let directory = ModelStore.location(of: model) else { print("\(model.name) isn't downloaded"); return }
    let brain = try await Brain(model: model, at: directory)
    try await brain.warmUp()
    let lines = ["Hi there.", "I had a long day at work.", "I'm a nurse, nights mostly.", "It was busy, three admissions.",
                 "One of them was a kid with a broken arm.", "He was really brave about it.", "Anyway, I'm home now.",
                 "My dog is asleep on the sofa.", "His name is Biscuit.", "He's a beagle.", "What should I eat?",
                 "I don't have eggs.", "Pasta sounds good.", "What sauce?", "I have tomatoes and garlic.",
                 "Okay, I'll do that.", "Do you like music?", "I'm learning guitar.", "Just three chords so far.",
                 "My fingers hurt.", "Any tips?", "Thanks, goodnight."]
    var turns: [Turn] = []
    for (index, line) in lines.enumerated() {
        turns.append(Turn(.person, line))
        let started = Duplex.now
        let first = Clock()
        let reply = try await brain.reply(to: turns) { _ in first.mark() }
        let (read, length) = await brain.lastPrompt
        print(String(format: "%2d  read %4d of %4d tokens, first words %.2f s", index + 1, read, length,
                     (first.at ?? Duplex.now) - started))
        turns.append(Turn(.companion, reply))
        // As the loop does once a reply has been said.
        if CommandLine.arguments.contains("--anticipate") { try await brain.anticipate(turns) }
    }
}

/// When something first happened, from any thread.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    var at: Double? { lock.withLock { first } }
    func mark() { lock.withLock { if first == nil { first = Duplex.now } } }
}

/// The spatial voice's audio graph, built and run: a sentence played
/// silently through it, and the echo-cancelled engine put together with it.
func spatialCheck() async throws {
    guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else { print("no voice"); return }
    let voice = try Voice(model: voiceURL, espeakData: espeak)
    let samples = try voice.speak("Can you hear where I am?")
    let order = option("--spatial-check") == "plain-first" ? [false, true] : [true, false]
    for spatial in order {
        print("  \(spatial ? "spatial" : "plain"): starting"); fflush(stdout)
        let blurt = try Blurt(samples, rate: voice.sampleRate, spatial: spatial, volume: 0)
        print("  started"); fflush(stdout)
        try await Task.sleep(for: .seconds(blurt.end - Duplex.now + 0.1))
        blurt.stop()
        print(String(format: "played %.2f s %@, silently", blurt.end - blurt.start, spatial ? "placed in front" : "as before"))
        fflush(stdout)
    }
    // Touching the microphone's side of the engine waits for permission to
    // use it, and from a terminal nobody may be there to give it.
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        print("the echo-cancelled engine wasn't tried: this terminal hasn't been allowed the microphone")
        return
    }
    _ = try Duplex(sampleRate: voice.sampleRate, echoCancellation: true, spatial: true)
    print("the echo-cancelled engine takes the spatial stage")
}

/// The mouth for a sentence, from the voice's own phoneme timings, beside
/// what the spelling estimate made of it.
func lipsync(_ text: String) throws {
    guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else { print("no voice"); return }
    let voice = try Voice(model: voiceURL, espeakData: espeak)
    let (samples, mouth) = try voice.speakTimed(text)
    let seconds = Double(samples.count) / voice.sampleRate
    print(String(format: "\"%@\", %.2f s", text, seconds))
    func show(_ spans: [VisemeSpan]) -> String {
        spans.map { String(format: "%@ %.2f-%.2f", $0.viseme.rawValue, $0.start, $0.end) }.joined(separator: ", ")
    }
    if let mouth {
        print("  from the voice:  \(show(mouth))")
    } else {
        print("  the voice gave no timings")
    }
    print("  from spelling:   \(show(Visemes.timeline(SpokenWord.estimate(text, duration: seconds))))")
    // How open the mouth is, every 50 ms, as the face draws it.
    for (label, spans) in [("voice", mouth ?? []), ("spelling", Visemes.timeline(SpokenWord.estimate(text, duration: seconds)))] {
        var face = FacePerformance(origin: 0)
        face.set(.speaking, at: 0)
        face.say(spans, at: 1)
        let openness = stride(from: 1.0, to: 1 + seconds, by: 0.05).map { face.pose(at: $0).face.mouth.aperture }
        print("  mouth open (\(label)): " + openness.map { String(format: "%.1f", $0) }.joined(separator: " "))
    }
}

/// The microphone through the app's own audio engine, with and without the
/// echo canceller, while the Mac says something out loud: what format comes
/// in, and how loud.
func micCheck() async throws {
    let devices = AudioDevicesInfo.defaults()
    print("input: \(devices.input), output: \(devices.output)")
    // --mic-check plain | cancel | cancel-builtin: one per process, so one
    // engine's teardown can't spoil the next.
    let mode = option("--mic-check") ?? "plain"
    let builtIn = AudioDevicesInfo.all().first { $0.builtIn && $0.outputs > 0 && $0.name.contains("Speakers") }
    // "restart" switches the canceller on, off and on again in one process,
    // as the app does when the setting is changed.
    let sequence = mode == "restart" ? [true, false, true] : [mode != "plain"]
    for cancelling in sequence {
        let output = mode == "cancel-builtin" ? builtIn?.id : nil
        let audio = try Duplex(sampleRate: 22_050, echoCancellation: cancelling, spatial: false, output: output)
        print("\(cancelling ? "with" : "without") the echo canceller\(output != nil ? ", playing to \(builtIn!.name)" : ""): "
              + audio.inputDescription)
        fflush(stdout)
        do {
            try audio.start()
        } catch {
            print("  couldn't start: \(error.localizedDescription)")
            continue
        }
        /// Loudest level per channel, and of what the loop is given, over `seconds`.
        func measure(_ seconds: Double) async throws -> (channels: [Double], given: Float) {
            var channels: [Double] = []
            var given: Float = 0
            let started = Duplex.now
            while Duplex.now - started < seconds {
                try await Task.sleep(for: .milliseconds(50))
                let now = audio.channelLevels
                channels = channels.isEmpty ? now : zip(channels, now).map(max)
                given = max(given, audio.buffer.level)
            }
            return (channels, given)
        }
        func show(_ label: String, _ result: (channels: [Double], given: Float)) {
            print("  \(label): channels " + result.channels.map { String(format: "%.4f", $0) }.joined(separator: " ")
                  + String(format: ", given to the loop %.4f", result.given))
        }
        // Its own voice, through the engine: the canceller should take it out.
        if let voiceURL = Resources.voice, let espeak = Resources.espeakData {
            let voice = try Voice(model: voiceURL, espeakData: espeak)
            let samples = try voice.speak("This is my own voice, which I should not hear.")
            audio.play(resample(samples, from: voice.sampleRate, to: 22_050))
            show("its own voice", try await measure(3))
        }
        try await Task.sleep(for: .milliseconds(500))
        // Someone else talking: should come through.
        let speaker = Process()
        speaker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speaker.arguments = ["Testing, one, two, three. Can you hear me?"]
        try speaker.run()
        show("another voice", try await measure(3.5))
        speaker.waitUntilExit()
        audio.stop()
        fflush(stdout)
        try await Task.sleep(for: .milliseconds(500))
    }
}

/// The camera watcher for ten seconds: where it would look, and how sure.
func watchCheck() async throws {
    guard await Watcher.permission() else { print("no camera permission"); return }
    let attention = AttentionSense()
    let watcher = Watcher(attention: attention)
    watcher.report = { faces in
        let line = faces.map { String(format: "(%.2f, %.2f) size %.3f mouth moving %.3f", $0.position.x, $0.position.y, $0.size, $0.talking) }
        print("  sees \(faces.count) face(s): " + line.joined(separator: "; "))
        fflush(stdout)
    }
    try watcher.start()
    print("watching for ten seconds; talk, and move from side to side")
    fflush(stdout)
    for _ in 0..<10 {
        try await Task.sleep(for: .seconds(1))
        if let look = attention.look() { print(String(format: "looking at (%.2f, %.2f)", look.x, look.y)) } else { print("looking nowhere") }
        fflush(stdout)
    }
    watcher.stop()
}

if CommandLine.arguments.contains("--watch") {
    try await watchCheck()
    exit(0)
}

if CommandLine.arguments.contains("--mic-check") || option("--mic-check") != nil {
    try await micCheck()
    exit(0)
}

/// A sentence as the voice will say it: its parts and their languages,
/// then out loud through the speakers. --hint names the language asked about.
func sayAloud(_ text: String, hint: String?) async throws {
    guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else { print("no voice"); return }
    let voice = try Voice(model: voiceURL, espeakData: espeak)
    print("voice: \(voiceURL.lastPathComponent)\(voice.isPolyglot ? " (polyglot)" : "")")
    for (part, language) in voice.parts(text, hint: hint) { print("  [\(language)] \(part)") }
    let (samples, mouth) = try voice.speakTimed(text, hint: hint)
    print(String(format: "  %.2f s, %d mouth shapes", Double(samples.count) / voice.sampleRate, mouth?.count ?? 0))
    let blurt = try Blurt(samples, rate: voice.sampleRate, spatial: false)
    try await Task.sleep(for: .seconds(blurt.end - Duplex.now + 0.2))
    blurt.stop()
}

/// Pitch per 10 ms frame, by autocorrelation, voiced frames only (Hz; 0 unvoiced).
func pitchTrack(_ samples: [Float], rate: Double) -> [Double] {
    let frame = Int(rate * 0.04), hop = Int(rate * 0.01)
    let (low, high) = (Int(rate / 400), Int(rate / 70))
    var out: [Double] = []
    var start = 0
    while start + frame + high < samples.count {
        let window = Array(samples[start..<(start + frame + high)])
        let energy = window[0..<frame].reduce(0) { $0 + Double($1 * $1) }
        var best = (lag: 0, value: 0.0)
        if energy / Double(frame) > 1e-4 {
            for lag in low...high {
                var sum = 0.0
                for i in 0..<frame { sum += Double(window[i] * window[i + lag]) }
                let normalised = sum / energy
                if normalised > best.value { best = (lag, normalised) }
            }
        }
        out.append(best.value > 0.55 ? rate / Double(best.lag) : 0)
        start += hop
    }
    return out
}

/// The same words as a statement, a question and an exclamation: how the
/// pitch range and the sentence's ending differ, then out loud.
func intonation(_ words: String) async throws {
    guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else { print("no voice"); return }
    let voice = try Voice(model: voiceURL, espeakData: espeak)
    let base = words.trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
    for text in [base + ".", base + "?", base + "!"] {
        let (samples, _) = try voice.speakTimed(text)
        let voiced = pitchTrack(samples, rate: voice.sampleRate).filter { $0 > 0 }
        guard voiced.count > 10 else { print("\(text): too little voiced speech"); continue }
        let sorted = voiced.sorted()
        let range = 12 * log2(sorted[Int(Double(sorted.count) * 0.95)] / sorted[Int(Double(sorted.count) * 0.05)])
        let split = Int(Double(voiced.count) * 0.7)
        func median(_ values: ArraySlice<Double>) -> Double { values.sorted()[values.count / 2] }
        let ending = 12 * log2(median(voiced[split...]) / median(voiced[..<split]))
        print(String(format: "%-40@ range %4.1f semitones, ending %+5.1f semitones, %.2f s", text as NSString, range, ending,
                     Double(samples.count) / voice.sampleRate))
        fflush(stdout)
        if !CommandLine.arguments.contains("--quiet") {
            let blurt = try Blurt(samples, rate: voice.sampleRate, spatial: false)
            try await Task.sleep(for: .seconds(blurt.end - Duplex.now + 0.4))
            blurt.stop()
        }
    }
}

/// 16-bit mono WAV.
func wav(_ samples: [Float], rate: Double) -> Data {
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes); data.append(contentsOf: Array("WAVEfmt ".utf8))
    put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate) * 2); put(UInt16(2)); put(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); put(bytes)
    for s in samples { put(Int16(max(-1, min(1, s)) * 32_767)) }
    return data
}

// ccrun --wav "a | b" --out <folder>: each line to a WAV, through the polyglot voice.
if let lines = option("--wav"), let out = option("--out") {
    guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else { print("no voice"); exit(1) }
    let voice = try Voice(model: voiceURL, espeakData: espeak)
    let folder = URL(filePath: out)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (n, line) in lines.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }).enumerated() {
        try wav(voice.speak(line), rate: voice.sampleRate).write(to: folder.appending(path: String(format: "%02d.wav", n + 1)))
    }
    exit(0)
}

/// A music file through the kick detector as the microphone would hear it
/// (mono, 16 kHz): the tempo it settles on, and when it dances.
func beats(_ path: String) throws {
    let file = try AVAudioFile(forReading: URL(filePath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { print("can't convert"); return }
    var dance = Dance()
    var detector = KickDetector()
    var heard = 0.0
    var kicks: [Double] = []
    var lastReport = -1.0
    var done = false
    while !done {
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1_600)!
        var error: NSError?
        converter.convert(to: out, error: &error) { count, status in
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
            if (try? file.read(into: input, frameCount: count)) == nil || input.frameLength == 0 {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return input
        }
        if out.frameLength == 0 { done = true; continue }
        let block = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        let got = detector.hear(block, at: heard)
        kicks += got.kicks
        dance.hear(got)
        heard += Double(block.count) / 16_000
        if heard - lastReport >= (CommandLine.arguments.contains("--often") ? 2 : 10) {
            lastReport = heard
            let recent = kicks.filter { $0 > heard - 10 }.count
            let state = dance.at(heard).map { String(format: "dancing (%.0f%%)", $0.amount * 100) } ?? "still"
            let tempo = (dance.beat(at: heard).map { String(format: "%.0f BPM", 60 / $0) } ?? "no steady beat")
                + String(format: " (fit %.2f)", dance.confidence)
            print(String(format: "%5.0f s: %2d kicks in the last 10 s, %@, %@", heard, recent, tempo as NSString, state as NSString))
        }
    }
    print(String(format: "%d kicks in %.0f s", kicks.count, heard))
}

if let path = option("--beats") {
    try beats(path)
    exit(0)
}

if let words = option("--intonation") {
    try await intonation(words)
    exit(0)
}

if let text = option("--say") {
    try await sayAloud(text, hint: option("--hint"))
    exit(0)
}

if let text = option("--lipsync") {
    try lipsync(text)
    exit(0)
}

if CommandLine.arguments.contains("--spatial-check") || option("--spatial-check") != nil {
    try await spatialCheck()
    exit(0)
}

/// Things said to it, each on its own, and what it answers: for checking
/// how it handles what it can't do.
func ask(_ lines: [String]) async throws {
    let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
    guard let directory = ModelStore.location(of: model) else { print("\(model.name) isn't downloaded"); return }
    let brain = try await Brain(model: model, at: directory)
    if let personality = option("--personality").flatMap(Personality.init(rawValue:)) { await brain.set(personality) }
    let dictionary = CommandLine.arguments.contains("--no-dictionary") ? nil : Resources.dictionary.flatMap(Dictionary.init(file:))
    // --chat: one conversation, each line following the last; otherwise each on its own.
    let chat = CommandLine.arguments.contains("--chat")
    var crisis: (level: Crisis.Level, told: Bool)?
    var crisisReplies = 0
    var checkIn = option("--check-in").map {
        Note(text: $0, session: "earlier", turns: 0...0, at: Date().addingTimeInterval(-3 * 86_400), lasting: false, vector: [])
    }
    var turns: [Turn] = []
    // --greet <hours away>: it says hello first, with the check-in if there is one, then the lines follow.
    if let away = option("--greet").flatMap(Double.init), let cue = Greeting.cue(last: Date() - away * 3600, checkIn: checkIn) {
        let hello = try await brain.reply(to: [Turn(.person, cue)]) { _ in }
        if let note = checkIn, CheckIn.asked(hello, about: note) { checkIn = nil }
        turns.append(Turn(.companion, hello))
        print("  it (hello): \(hello)")
    }
    for line in lines {
        let found = dictionary?.aside(for: line)
        if let found { print("  dictionary: \(found)") }
        turns = (chat ? turns : []) + [Turn(.person, line)]
        var recollection = Recollection(aside: found)
        // As the app does: clear words hold the careful reply; a hard day gets one gentle check.
        let heard = Crisis.heard(line)
        if heard == .clear { crisis = (.clear, crisis?.told ?? false) }
        if let level = crisis?.level ?? heard {
            recollection.aside = [recollection.aside, Crisis.guidance(level, first: !(crisis?.told ?? false),
                                                                      region: option("--region") ?? Locale.current.region?.identifier)]
                .compactMap { $0 }.joined(separator: " ")
            print("     (\(level == .clear ? "crisis" : "maybe")\(crisis?.told == false ? ", first" : ""))")
        }
        // --check-in "<note>": told three days ago, offered from their second line on until asked.
        if let note = checkIn, CheckIn.asked(line, about: note) { checkIn = nil }
        if let checkIn, turns.count >= 3 { recollection.checkIn = checkIn }
        let reply = try await brain.reply(to: turns, remembering: recollection) { _ in }
        var said = reply
        let region = option("--region") ?? Locale.current.region?.identifier
        if crisis != nil {
            crisisReplies += 1
            if Crisis.gave(reply, region: region) { crisis?.told = true }
            else if crisisReplies >= 2, crisis?.told == false {
                said += " " + Crisis.offer(region: region)
                crisis?.told = true
            }
        }
        turns.append(Turn(.companion, said))
        print("you: \(line)\n  it: \(said)")
        if let offered = recollection.checkIn {
            let asked = CheckIn.asked(reply, about: offered)
            print("     (offered the check-in\(asked ? "; asked" : ""))")
            if asked { checkIn = nil }
        }
    }
}

if let text = option("--ask") {
    try await ask(text.components(separatedBy: " | "))
    exit(0)
}

if CommandLine.arguments.contains("--long") {
    try await longRun()
    exit(0)
}

// ccrun --seal-check: a copy of the real memory and logs sealed with a
// throwaway key, as the app will on its first run with sealing: nothing lost,
// nothing left in the clear, and it all opens again.
if CommandLine.arguments.contains("--seal-check") {
    let copy = FileManager.default.temporaryDirectory.appending(path: "ccrun-seal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: copy) }
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Resources.support.appending(path: "Conversations"), to: copy.appending(path: "Conversations"))
    try FileManager.default.copyItem(at: Resources.memory, to: copy.appending(path: "memory.json"))
    let logs = { try FileManager.default.contentsOfDirectory(at: copy.appending(path: "Conversations"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    let before = try logs().map { try ConversationLog.read($0).count }
    let embedder = try await Embedder.load()
    let plain = Memory(file: copy.appending(path: "memory.json"), conversations: copy.appending(path: "Conversations"), embedder: embedder)
    let (notes, diary, calendar) = await (plain.store.notes.count, plain.store.journal.count, plain.store.calendar.count)
    let sealer = Sealer(key: SymmetricKey(size: .bits256))
    let sealed = Memory(file: copy.appending(path: "memory.json"), conversations: copy.appending(path: "Conversations"),
                        embedder: embedder, sealer: sealer)
    let after = try logs().map { try ConversationLog.read($0, sealer: sealer).count }
    let raw = try Data(contentsOf: copy.appending(path: "memory.json"))
    let clear = try logs().contains { try String(contentsOf: $0, encoding: .utf8).contains("\"text\"") }
        || String(decoding: raw, as: UTF8.self).contains("\"text\"")
    let again = Memory(file: copy.appending(path: "memory.json"), conversations: copy.appending(path: "Conversations"),
                       embedder: embedder, sealer: sealer)
    let unkeyed = Memory(file: copy.appending(path: "memory.json"), conversations: copy.appending(path: "Conversations"),
                         embedder: embedder)
    print("notes \(notes), diary \(diary), calendar \(calendar); logs \(before) turns")
    print("sealed: notes \(await sealed.store.notes.count), reopened \(await again.store.notes.count), locked \(await again.locked)")
    print("logs after: \(after) turns; anything left in the clear: \(clear)")
    print("without the key: locked \(await unkeyed.locked), notes \(await unkeyed.store.notes.count)")
    exit(0)
}

// ccrun --speakers <folder>: WAVs named <voice>__<n>.wav (16 kHz mono), each
// voice saying several things; how well each voiceprint model tells them apart.
if let folder = option("--speakers") {
    let files = try FileManager.default.contentsOfDirectory(at: URL(filePath: folder), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let clips: [(voice: String, samples: [Float])] = try files.map { url in
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return (String(url.lastPathComponent.split(separator: "_")[0]), samples)
    }
    for model in Voiceprinter.Model.allCases {
        let printer = try await Voiceprinter(model)
        let started = Duplex.now
        var prints: [[Float]] = []
        for clip in clips { prints.append(try await printer.print(clip.samples)) }
        let each = (Duplex.now - started) / Double(clips.count) * 1000
        func cos(_ a: [Float], _ b: [Float]) -> Double { Double(zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }) }
        var same: [(Double, Double)] = [], other: [(Double, Double)] = []  // (score, shorter clip's seconds)
        for i in clips.indices {
            for j in clips.indices where j > i {
                let pair = (cos(prints[i], prints[j]), Double(min(clips[i].samples.count, clips[j].samples.count)) / 16_000)
                if clips[i].voice == clips[j].voice { same.append(pair) } else { other.append(pair) }
            }
        }
        // The threshold where as many same-voice pairs fall below as other-voice pairs above.
        let scores = (same + other).map(\.0).sorted()
        var best = (threshold: 0.0, error: 1.0)
        for t in scores {
            let missed = Double(same.filter { $0.0 < t }.count) / Double(same.count)
            let confused = Double(other.filter { $0.0 >= t }.count) / Double(other.count)
            if max(missed, confused) < best.error { best = (t, max(missed, confused)) }
        }
        func stats(_ pairs: [(Double, Double)]) -> String {
            guard !pairs.isEmpty else { return "-" }
            let v = pairs.map(\.0).sorted()
            return String(format: "mean %.2f, %.2f-%.2f", v.reduce(0, +) / Double(v.count), v.first!, v.last!)
        }
        print("\(model.rawValue): \(String(format: "%.0f", each)) ms a clip")
        print("  same voice:  \(stats(same))   (both over 1.5 s: \(stats(same.filter { $0.1 > 1.5 })))")
        print("  other voice: \(stats(other))   (both over 1.5 s: \(stats(other.filter { $0.1 > 1.5 })))")
        print(String(format: "  best threshold %.2f: %.1f%% wrong either way", best.threshold, best.error * 100))
        let longSame = same.filter { $0.1 > 1.5 }, longOther = other.filter { $0.1 > 1.5 }
        var bestLong = (threshold: 0.0, error: 1.0)
        for t in (longSame + longOther).map(\.0).sorted() {
            let e = max(Double(longSame.filter { $0.0 < t }.count) / Double(max(1, longSame.count)),
                        Double(longOther.filter { $0.0 >= t }.count) / Double(max(1, longOther.count)))
            if e < bestLong.error { bestLong = (t, e) }
        }
        print(String(format: "  over 1.5 s only: threshold %.2f, %.1f%% wrong", bestLong.threshold, bestLong.error * 100))
        var pairs: [String: [Double]] = [:]
        for i in clips.indices { for j in clips.indices where j > i && clips[i].voice != clips[j].voice
            && min(clips[i].samples.count, clips[j].samples.count) > 24_000 {
            pairs[[clips[i].voice, clips[j].voice].sorted().joined(separator: "/"), default: []].append(cos(prints[i], prints[j]))
        } }
        let close = pairs.map { ($0.key, $0.value.reduce(0, +) / Double($0.value.count)) }.sorted { $0.1 > $1.1 }.prefix(4)
        print("  most alike: " + close.map { String(format: "%@ %.2f", $0.0, $0.1) }.joined(separator: ", "))
        // As the app will: a voice is the average of its other clips; each clip
        // is matched against every voice, and a voice left out entirely should
        // come out as nobody it knows.
        func centroid(_ vectors: [[Float]]) -> [Float] {
            var sum = [Float](repeating: 0, count: vectors[0].count)
            for v in vectors { for k in sum.indices { sum[k] += v[k] } }
            let length = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return sum.map { $0 / length }
        }
        let voices = Array(Set(clips.map(\.voice))).sorted()
        for threshold in printer.model == .campplus ? [0.60, 0.65, 0.70, 0.75, 0.80] : [0.55, 0.60, 0.65, 0.70] {
            var right = 0, wrong = 0, unsure = 0, newRight = 0, newWrong = 0
            var longRight = 0, longTotal = 0
            for i in clips.indices {
                var known: [(String, [Float])] = []
                for voice in voices {
                    let others = clips.indices.filter { clips[$0].voice == voice && $0 != i }.map { prints[$0] }
                    known.append((voice, centroid(others)))
                }
                let ranked = known.map { ($0.0, cos(prints[i], $0.1)) }.sorted { $0.1 > $1.1 }
                if ranked[0].1 < threshold { unsure += 1 } else if ranked[0].0 == clips[i].voice { right += 1 } else { wrong += 1 }
                if clips[i].samples.count > 24_000 {
                    longTotal += 1
                    if ranked[0].1 >= threshold && ranked[0].0 == clips[i].voice { longRight += 1 }
                }
                // As someone new: without their own voice among those known.
                let stranger = ranked.filter { $0.0 != clips[i].voice }
                if clips[i].samples.count > 24_000 {
                    if stranger[0].1 < threshold { newRight += 1 } else { newWrong += 1 }
                }
            }
            print(String(format: "  threshold %.2f: right %d, wrong %d, not sure %d of %d (long clips right %d of %d); a stranger (long clips) taken for someone they know %d of %d",
                         threshold, right, wrong, unsure, clips.count, longRight, longTotal, newWrong, newRight + newWrong))
        }
    }
    exit(0)
}

// ccrun --night: what the recogniser makes of night-time noise, beside real
// speech, and how sure it is of each.
if CommandLine.arguments.contains("--night") {
    let recognizer = try await Recognizer.load()
    let rate = 16_000.0
    func noise(_ seconds: Double, _ make: (Int) -> Float) -> [Float] { (0..<Int(seconds * rate)).map(make) }
    var seed: UInt32 = 7
    func white() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
    var low: Float = 0
    var sounds: [(String, [Float])] = [
        ("hiss", noise(2) { _ in white() * 0.05 }),
        ("loud hiss", noise(2) { _ in white() * 0.3 }),
        ("rumble (fridge, traffic)", noise(3) { _ in low = low * 0.995 + white() * 0.05; return low }),
        ("hum 50 Hz", noise(2) { i in Float(sin(2 * Double.pi * 50 * Double(i) / rate)) * 0.1 + white() * 0.01 }),
        ("clicks (a creak, a tap)", noise(2) { i in i % 4000 < 40 ? white() * 0.8 : white() * 0.005 }),
        ("music-ish chords", noise(3) { i in
            let t = Double(i) / rate
            return Float(sin(2 * .pi * 220 * t) + sin(2 * .pi * 277 * t) + sin(2 * .pi * 330 * t)) * 0.08 }),
    ]
    for (voice, line) in [("Samantha", "Hey, are you awake?"), ("Daniel", "I couldn't sleep, can we talk for a bit?"),
                          ("Karen", "Good morning."), ("Samantha", "Yeah."), ("Fred", "Thanks.")] {
        sounds.append(("\(voice): \(line)", try spoken(line, by: voice)))
    }
    // Speech from across a room, under a TV: quiet and mixed with noise.
    let far = try spoken("And now the weather for the weekend ahead.", by: "Daniel")
    sounds.append(("faraway TV speech", far.map { $0 * 0.08 + white() * 0.02 }))
    for (name, samples) in sounds {
        let (text, confidence) = try await recognizer.heard(samples)
        print(String(format: "%-46@ %.2f  \"%@\"", name as NSString, confidence, text as NSString))
    }
    exit(0)
}

if CommandLine.arguments.contains("--weeks") {
    try await weeksRun()
    exit(0)
}

if CommandLine.arguments.contains("--journal") {
    try await journalRun()
    exit(0)
}

if CommandLine.arguments.contains("--memory") {
    try await memoryRun()
    exit(0)
}

if CommandLine.arguments.contains("--recall") {
    try await recall()
    exit(0)
}

if let folder = option("--faces") {
    try await MainActor.run { try faces(into: URL(fileURLWithPath: folder)) }
    exit(0)
}

// MARK: the "microphone" and "speakers"

/// Plays a script of speech into the loop at the pace it was spoken, and
/// keeps the replies' schedule as the speakers would, mixing a share of them
/// back into what the loop hears.
final class Played: AudioIO, @unchecked Sendable {
    let buffer = SampleBuffer()
    let rate: Double
    let echo: Float
    /// How late the echo comes back: output and input latency and the room.
    let delay: Double
    private let lock = NSLock()
    /// Replies, at 16 kHz, with when they start and where they were cut off.
    private var clips: [(start: Double, samples: [Float], cut: Double)] = []
    private var end = 0.0
    private(set) var firstPlayed: Double?

    init(rate: Double, echo: Float, delay: Double = 0) {
        self.rate = rate
        self.echo = echo
        self.delay = delay
    }

    func play(_ samples: [Float]) -> (start: Double, end: Double) {
        lock.withLock {
            let start = max(Duplex.now, end)
            end = start + Double(samples.count) / rate
            clips.append((start, resample(samples, from: rate), .infinity))
            firstPlayed = firstPlayed ?? start
            return (start, end)
        }
    }

    func silence() {
        lock.withLock {
            let now = Duplex.now
            clips = clips.filter { $0.start <= now }.map { ($0.start, $0.samples, min($0.cut, now)) }
            end = now
        }
    }

    /// What was played, unattenuated: the loop measures the echo against it.
    func reference(from start: Double, to end: Double) -> [Float] {
        let count = max(0, Int((end - start) * 16_000))
        return (0..<count).map { played(at: start + Double($0) / 16_000) }
    }

    var backlog: Double { lock.withLock { max(0, end - Duplex.now) } }

    /// Which side the person speaks from, as a stereo microphone would hear
    /// it: their voice this much louder on that side. nil for a mono one.
    var side: Double?

    var balance: (left: Double, right: Double)? {
        side.map { (left: 0.08 * (1 - $0 * 0.5), right: 0.08 * (1 + $0 * 0.5)) }
    }

    /// Forget when the last reply started, to wait for the next one.
    func markReply() { lock.withLock { firstPlayed = nil } }

    /// What the speakers put back into the microphone at this moment.
    func leak(at time: Double) -> Float { played(at: time - delay) * echo }

    /// What the speakers were playing at `time`.
    func played(at time: Double) -> Float {
        lock.withLock {
            var value: Float = 0
            for clip in clips where clip.start <= time && time < clip.cut {
                let index = Int((time - clip.start) * 16_000)
                if index < clip.samples.count { value += clip.samples[index] }
            }
            return value
        }
    }
}

/// Feeds `audio`'s buffer in real time: speech, then silence, with the echo mixed in.
final class Mouth: @unchecked Sendable {
    let audio: Played
    private var fed = 0
    private let origin = Duplex.now

    init(_ audio: Played) { self.audio = audio }

    /// Deliver `samples` (or silence for `seconds`) at the pace of real time.
    func deliver(_ samples: [Float]) async {
        var at = 0
        while at < samples.count {
            let due = Int((Duplex.now - origin) * 16_000)
            if due > fed {
                let count = min(due - fed, samples.count - at)
                var block = Array(samples[at..<(at + count)])
                for index in block.indices { block[index] += audio.leak(at: origin + Double(fed + index) / 16_000) }
                audio.buffer.append(block)
                fed += count
                at += count
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func pause(_ seconds: Double) async { await deliver([Float](repeating: 0, count: Int(seconds * 16_000))) }

    /// Silence until the reply in progress has finished or been cut off.
    func pauseForReply(after count: Int, limit: Double = 30) async {
        let deadline = Duplex.now + limit
        while Report.ended() <= count && Duplex.now < deadline { await pause(0.05) }
    }

    /// Silence until the next reply has been playing for `seconds`.
    func pause(intoReply seconds: Double, limit: Double = 30) async {
        let deadline = Duplex.now + limit
        while (audio.firstPlayed.map { Duplex.now - $0 < seconds } ?? true) && Duplex.now < deadline { await pause(0.05) }
    }
}

// MARK: the conversation

let echo = Float(option("--echo") ?? "0.05") ?? 0.05
guard let voiceURL = Resources.voice, let espeak = Resources.espeakData, let vadURL = Resources.vad else {
    print("missing the voice or the voice detector: run scripts/polyglot-voice.sh and scripts/fetch-models.sh")
    exit(1)
}
let model = ModelCatalog.model(option("--model")) ?? ModelCatalog.recommended
guard let directory = ModelStore.location(of: model) else {
    print("\(model.name) isn't downloaded: choose it in the app's settings, or pass --model with one that is")
    exit(1)
}

say("loading the voice, recognition and \(model.name)…")
let voice = try Voice(model: voiceURL, espeakData: espeak)
let recognizer = try await Recognizer.load()
let brain = try await Brain(model: model, at: directory)
try await brain.warmUp()
let embedder = try await Embedder.load()
let memoryFolder = FileManager.default.temporaryDirectory.appending(path: "ccrun-\(UUID().uuidString)")
let memory = Memory(file: memoryFolder.appending(path: "memory.json"), conversations: memoryFolder, embedder: embedder)
say(String(format: "loaded; footprint %.2f GB", footprint().now))

let audio = Played(rate: voice.sampleRate, echo: echo, delay: Double(option("--delay") ?? "0") ?? 0)
let mouth = Mouth(audio)

/// What happened, for the summary.
final class Tally: @unchecked Sendable {
    let lock = NSLock()
    var spokeUntil = 0.0
    var latencies: [Double] = []
    var waitingForReply = false
    var replies = 0
    var interruptions = 0
    var timing = PauseModel()
}
let tally = Report.tally

let attention = AttentionSense()
// --household: its person and a guest, by two of the system's voices.
let household = CommandLine.arguments.contains("--household") || CommandLine.arguments.contains("--overnight")
let printer = household ? try await Voiceprinter(.campplus) : nil
let houseLog = household ? try ConversationLog(directory: memoryFolder) : nil
let loop = Loop(audio: audio, vad: try SileroVAD(model: vadURL), recognizer: recognizer, brain: brain, voice: voice,
                memory: memory, attention: attention, log: houseLog, voiceprinter: printer,
                voices: household ? VoiceSense(Household()) : nil,
                awake: CommandLine.arguments.contains("--overnight") ? 5 : 180, timing: PauseModel(), emit: Report.handle)

/// Away from the main actor: the loop calls it from its own.
enum Report {
    static let tally = Tally()

    /// Replies finished or cut off so far.
    static func ended() -> Int { tally.lock.withLock { tally.replies + tally.interruptions } }

    static func handle(_ event: LoopEvent) {
    switch event {
    case let .mood(mood): say("face: \(mood.rawValue)")
    case let .heard(text): say("heard: \(text)")
    case .memoryChanged: say("memory changed")
    case let .recalled(recollection):
        for note in recollection.notes { say("recalled: \(note.text)") }
        for turn in recollection.excerpt { say("  word for word: \(turn.text)") }
    case let .saying(text, _, start):
        tally.lock.withLock {
            if tally.waitingForReply {
                tally.latencies.append(start - tally.spokeUntil)
                tally.waitingForReply = false
            }
        }
        say("saying: \(text)")
    case .hushed: say("hushed")
    case .withdrew: say("still their turn")
    case let .replied(text, interrupted):
        tally.lock.withLock {
            if interrupted { tally.interruptions += 1 } else { tally.replies += 1 }
        }
        say(interrupted ? "cut off after: \(text)" : "replied")
    case let .timing(model):
        tally.lock.withLock { tally.timing = model }
        say(String(format: "timing: waits %.2f s after a statement, %d pauses learned, %d cut-ins",
                   model.wait(after: .statement), model.pauses.count, model.cutIns))
    case let .overlap(heard, saying, loudness, echo):
        let loud = loudness.map { String(format: "%.1fx its echo", $0) } ?? "echo level not learned yet"
        say("overlap: heard \"\(heard)\" (\(loud)) while saying \"\(saying)\" → \(echo ? "echo" : "interruption")")
    case let .drafted(t):
        say(String(format: "draft: heard %.2f s, recalled %.2f, first words %.2f, first sentence %.2f, its voice %.2f; read %d of %d prompt tokens",
                   t.transcribed, t.recalled, t.firstWords, t.firstSentence, t.firstVoice, t.promptRead, t.promptLength))
    case let .echoDelay(delay, match):
        say(String(format: "echo comes back %.0f ms late (match %.2f)", delay * 1000, match))
    case let .echoLevel(level):
        if let leak = level.leak { say(String(format: "echo comes back at %.3f of what was played", leak)) }
    case let .voice(who): say("voice: \(who)")
    case let .ignored(text): say("ignored: \(text)")
    case let .problem(message): say("PROBLEM: \(message)")
    }
    }
}

let running = Task { await loop.run() }

// Shaking, as the phone's motion sensors would report it.
let motion = MotionSense()
motion.onShaken = { complaint in
    Task {
        let spoke = await loop.interject(complaint)
        say(spoke ? "shaken, and said so" : "shaken, but somebody was talking")
    }
}
func shake(for seconds: Double) async {
    say("(shaking the phone)")
    let end = Duplex.now + seconds
    var step = 0
    while Duplex.now < end {
        motion.feel(acceleration: Point(step % 12 < 6 ? 2.5 : -2.5, 0.4), rotation: 2, at: Duplex.now)
        step += 1
        try? await Task.sleep(for: .milliseconds(16))
    }
}

/// The scripted person, in a system voice. The companion's own voice would
/// make a different companion voice a different test: the same line takes a
/// different time, and the pause after it lands somewhere else.
let personVoice = "Samantha"

/// One turn: phrases with pauses between them, then the time it ended.
func turn(_ phrases: [String], pausing: Double = 0.55) async throws {
    for (index, phrase) in phrases.enumerated() {
        say("you: \(phrase)")
        await mouth.deliver(try spoken(phrase, by: personVoice))
        if index + 1 < phrases.count { await mouth.pause(pausing) }
    }
    tally.lock.withLock {
        tally.spokeUntil = Duplex.now
        tally.waitingForReply = true
    }
    audio.markReply()
    if let look = attention.look() {
        let pose = Attention.apply(look, mood: .listening, to: Pose(face: Expression.curious.face))
        say(String(format: "the face turned to (%.2f, %.2f): eyes at %.2f across, head turned %.1f°", look.x, look.y,
                   pose.gaze.x, pose.tilt))
    } else if CommandLine.arguments.contains("--from-right") || CommandLine.arguments.contains("--from-left") {
        say("the face had nowhere to turn")
    }
}

/// A line in one of the system's voices, 16 kHz.
func spoken(_ text: String, by voice: String) throws -> [Float] {
    let file = FileManager.default.temporaryDirectory.appending(path: "ccrun-say-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: file) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", voice, "-o", file.path, "--data-format=LEI16@16000", text]
    try say.run()
    say.waitUntilExit()
    let audio = try AVAudioFile(forReading: file)
    let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
    try audio.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// One turn by `voice`: phrases with pauses between, as `turn` does.
func turn(_ phrases: [String], by voice: String) async throws {
    for (index, phrase) in phrases.enumerated() {
        say("\(voice.split(separator: " ")[0]): \(phrase)")
        await mouth.deliver(try spoken(phrase, by: voice))
        if index + 1 < phrases.count { await mouth.pause(0.55) }
    }
    tally.lock.withLock {
        tally.spokeUntil = Duplex.now
        tally.waitingForReply = true
    }
    audio.markReply()
}

// --overnight: its person talks, then the room is quiet but for a TV through
// the wall; then its person, briefly; then the TV again, mid-conversation.
// (Quiet for 5 s counts as out of a conversation here, not 3 minutes.)
if CommandLine.arguments.contains("--overnight") {
    var hiss: UInt32 = 3
    func tv(_ line: String) throws -> [Float] {
        try spoken(line, by: "Daniel").map { x in
            hiss = hiss &* 1_664_525 &+ 1_013_904_223
            return x * 0.1 + (Float(hiss >> 8) / Float(1 << 24) - 0.5) * 0.02
        }
    }
    func tvTurn(_ line: String) async throws {
        say("TV: \(line)")
        await mouth.deliver(try tv(line))
        await mouth.pause(3)
    }
    await mouth.pause(1)
    var before = Report.ended()
    try await turn(["Hi there.", "I'm going to bed soon, it's been a long day."], by: "Samantha")
    await mouth.pauseForReply(after: before)
    await mouth.pause(7)
    for line in ["And now the weather for the weekend ahead.", "Heavy rain is expected across the north on Saturday.",
                 "Thanks for watching, see you tomorrow."] {
        try await tvTurn(line)
    }
    before = Report.ended()
    try await turn(["Hey, you awake?"], by: "Samantha")
    await mouth.pauseForReply(after: before)
    await mouth.pause(1)
    try await tvTurn("Coming up next, the late film.")
    await mouth.pause(2)
    print("  replies: \(Report.ended())")
    running.cancel()
    try? FileManager.default.removeItem(at: memoryFolder)
    exit(0)
}

if household {
    let lin = "Samantha", sam = "Daniel"
    await mouth.pause(1)
    for phrases in [["Hi there.", "I'm Lin, by the way."],
                    ["My sister Ana is visiting on Saturday.", "We haven't talked in a year, so I'm a bit nervous."],
                    ["Anyway, I'm going to make some tea."]] {
        let before = Report.ended()
        try await turn(phrases, by: lin)
        await mouth.pauseForReply(after: before)
        await mouth.pause(1.2)
    }
    say("(writing up what Lin said)")
    try await memory.writeUp(with: brain)
    print("  notes: " + (await memory.store.notes).map(\.text).joined(separator: " | "))
    for phrases in [["Hey there.", "I'm Sam, I live here with Lin."],
                    ["Is anyone visiting this weekend?", "What do you know about Lin's sister?"],
                    ["Fair enough.", "I like climbing, by the way, and I'm terrible at cooking."]] {
        let before = Report.ended()
        try await turn(phrases, by: sam)
        await mouth.pauseForReply(after: before)
        await mouth.pause(1.2)
    }
    for phrases in [["Hi, it's me again.", "Who did I say was coming on Saturday?"]] {
        let before = Report.ended()
        try await turn(phrases, by: lin)
        await mouth.pauseForReply(after: before)
        await mouth.pause(1.2)
    }
    try await memory.writeUp(with: brain)
    let store = await memory.store
    print("  its person's voice: \(store.household.owner.map { "learned from \($0.heard) turns" } ?? "not learned")")
    for note in store.notes { print("  note: \(note.text)") }
    for entry in store.journal { print("  diary: \(entry.text)") }
    running.cancel()
    try? FileManager.default.removeItem(at: memoryFolder)
    exit(0)
}

if CommandLine.arguments.contains("--commands") {
    // Remembering and forgetting, asked for out loud.
    await mouth.pause(1)
    var before = Report.ended()
    try await turn(["Remember that my sister's birthday is on the third of March."])
    await mouth.pauseForReply(after: before)
    print("  notes now: " + (await memory.notes).map(\.text).joined(separator: " | "))
    await mouth.pause(1.5)
    before = Report.ended()
    try await turn(["Forget what I said about my sister's birthday."])
    await mouth.pauseForReply(after: before)
    print("  notes now: " + ((await memory.notes).isEmpty ? "none" : (await memory.notes).map(\.text).joined(separator: " | ")))
    await mouth.pause(1)
    running.cancel()
    try? FileManager.default.removeItem(at: memoryFolder)
    exit(0)
}

if CommandLine.arguments.contains("--from-right") { audio.side = 0.8 }
if CommandLine.arguments.contains("--from-left") { audio.side = -0.8 }
await mouth.pause(1)
try await turn(["Hi there.", "I just got back from a long walk by the river."])
await mouth.pauseForReply(after: Report.ended())
if CommandLine.arguments.contains("--from-right") {
    // Then they move to the other side.
    audio.side = -0.8
}
await mouth.pause(1.5)
if CommandLine.arguments.contains("--shake") {
    let before = Report.ended()
    async let silence: Void = mouth.pause(2)
    await shake(for: 1.5)
    await silence
    await mouth.pauseForReply(after: before)
    await mouth.pause(1)
}
try await turn(["What should I cook tonight?", "Something quick."])
// Talk over the reply a second after it starts.
await mouth.pause(intoReply: 1.0)
let beforeEggs = Report.ended()
try await turn(["Actually, wait. I don't have any eggs."])
// The reply it cut off counts as one ending; wait for the next.
await mouth.pauseForReply(after: beforeEggs + 1)
await mouth.pause(1.5)
let beforeLast = Report.ended()
try await turn(["Tell me a little about yourself."])
await mouth.pauseForReply(after: beforeLast)
await mouth.pause(2)
running.cancel()

tally.lock.withLock {
    print("")
    print("echo leaking back: \(echo)")
    print("replies finished: \(tally.replies), interrupted: \(tally.interruptions)")
    print("from the end of your speech to the reply's first sound: "
          + tally.latencies.map { String(format: "%.2f s", $0) }.joined(separator: ", "))
    print(String(format: "learned: %d pauses, waits %.2f s after a statement, %d cut-ins",
                 tally.timing.pauses.count, tally.timing.wait(after: .statement), tally.timing.cutIns))
    let (now, peak) = footprint()
    print(String(format: "footprint with %@, recognition, the embedder and the voice: %.2f GB now, %.2f GB at peak",
                 model.name, now, peak))
}
try? FileManager.default.removeItem(at: memoryFolder)
exit(0)
