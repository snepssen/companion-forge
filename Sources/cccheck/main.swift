// The model-free parts held to their cases: `swift run cccheck`. Fast, and
// runs without a microphone or a downloaded model.
import CompanionCore
import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL  \(name)")
    }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.02) -> Bool { abs(a - b) <= tolerance }

// MARK: endings

check("a trailing conjunction is open, full stop or not", Ending.of("I went to the shop and.") == .open)
check("a filler is open", Ending.of("It was, um.") == .open)
check("no punctuation is open", Ending.of("So I was thinking") == .open)
check("a comma is open", Ending.of("Well,") == .open)
check("a question", Ending.of("What do you think?") == .question)
check("a statement", Ending.of("That's all I wanted.") == .statement)
check("nothing is open", Ending.of("  ") == .open)

// MARK: pause model

var fresh = PauseModel()
check("starts at 0.9 s after a statement", near(fresh.wait(after: .statement), 0.9))
check("a question is answered sooner", fresh.wait(after: .question) < fresh.wait(after: .statement))
check("an open ending waits longer", fresh.wait(after: .open) > fresh.wait(after: .statement))
check("drafts before the wait is over", fresh.draft() < fresh.wait(after: .question))

var quick = PauseModel()
for pause in [0.25, 0.3, 0.35, 0.3, 0.28, 0.32, 0.4, 0.3, 0.26, 0.33] { quick.resumed(after: pause) }
check("a quick talker gets a shorter wait", quick.wait(after: .statement) < 0.7)
check("never below the floor", quick.wait(after: .question) >= PauseModel.floor)

var slow = PauseModel()
for pause in [0.8, 1.1, 0.9, 1.3, 1.0, 1.2, 0.95, 1.4, 1.1, 1.0] { slow.resumed(after: pause) }
check("a slow talker gets a longer wait", slow.wait(after: .statement) > 1.3)
check("never above the ceiling", slow.wait(after: .open) <= PauseModel.ceiling)

var flutter = PauseModel()
flutter.resumed(after: 0.05)
flutter.resumed(after: 9)
check("flutter and long silences are not pauses", flutter.pauses.isEmpty)

var cut = quick
let before = cut.wait(after: .statement)
cut.cutIn()
check("cutting in pushes the wait out", cut.wait(after: .statement) > before + 0.2)
for _ in 0..<30 { cut.replied() }
check("and clean replies let it fade", near(cut.wait(after: .statement), before, 0.02))

// MARK: turn taking

/// Feed `seconds` of 32 ms frames; returns every action that wasn't `.none`.
func run(_ taker: inout TurnTaker, from t: inout Double, _ seconds: Double, speech: Bool,
         probability: Float = 0.9) -> [TurnTaker.Action] {
    var actions: [TurnTaker.Action] = []
    let end = t + seconds
    while t < end {
        t += 0.032
        let action = taker.tick(at: t, speech: speech, probability: probability)
        if action != .none { actions.append(action) }
    }
    return actions
}

var taker = TurnTaker()
var t = 0.0
var actions = run(&taker, from: &t, 1.0, speech: true)
check("speech starts a turn", actions.count == 1 && { if case .turnStarted = actions[0] { true } else { false } }())
actions = run(&taker, from: &t, 0.25, speech: false)
check("a short pause does nothing", actions.isEmpty)
actions = run(&taker, from: &t, 1.0, speech: true)
check("carrying on does nothing", actions.isEmpty)
check("and the pause was learned", taker.model.pauses.count == 1)
actions = run(&taker, from: &t, 0.5, speech: false)
check("a longer pause drafts", actions == [.draft])
actions = run(&taker, from: &t, 1.5, speech: false)
check("no commit before the transcript", actions.isEmpty)
taker.transcribed(.statement)
actions = run(&taker, from: &t, 0.1, speech: false)
check("commits once transcribed and the wait is over", actions == [.commit])
check("and replies", { if case .replying = taker.phase { true } else { false } }())

var resumed = TurnTaker()
t = 0
_ = run(&resumed, from: &t, 1.0, speech: true)
_ = run(&resumed, from: &t, 0.5, speech: false)
resumed.transcribed(.open)
actions = run(&resumed, from: &t, 0.2, speech: true)
check("carrying on after a draft abandons it", actions == [.abandon])

var noise = TurnTaker()
t = 0
_ = run(&noise, from: &t, 0.4, speech: true)
_ = run(&noise, from: &t, 0.6, speech: false)
noise.discard()
check("a draft with no words is nobody's turn", noise.phase == .waiting)

var echoed = taker
let replyStart: Double = { if case let .replying(since) = taker.phase { return since }; return 0 }()
t = replyStart
actions = run(&echoed, from: &t, 1.0, speech: true, probability: 0.55)
check("unsure speech over the reply is not an overlap", actions.isEmpty)
actions = run(&echoed, from: &t, 0.5, speech: true)
check("sure speech over the reply is", actions.count == 1)
echoed.overlapWasEcho()
_ = run(&echoed, from: &t, 0.1, speech: false)
echoed.replyFinished()
check("a finished reply waits", echoed.phase == .waiting)

var interrupted = taker
t = replyStart
actions = run(&interrupted, from: &t, 0.5, speech: true)
if case let .overlap(since) = actions.first { interrupted.interrupted(since: since) }
check("an early interruption counts as a cut-in", interrupted.model.cutIns == 1)
check("and the turn is theirs", interrupted.phase == .hearing)

var late = taker
t = replyStart + 3
actions = run(&late, from: &t, 0.5, speech: true)
if case let .overlap(since) = actions.first { late.interrupted(since: since) }
check("a late interruption is not a cut-in", late.model.cutIns == 0)

// MARK: sentences

var splitter = SentenceSplitter()
var said = ["Hi there, ", "friend. How", " are you today? I", " think"].flatMap { splitter.feed($0) }
check("whole sentences go as they complete", said == ["Hi there, friend.", "How are you today?"])
check("the rest at the end", splitter.finish() == ["I think"])
splitter = SentenceSplitter()
said = splitter.feed("Oh. That is great. ") + splitter.finish()
check("a two-word sentence waits for the next", said == ["Oh. That is great."])
check("markdown and emoji are not said", Speakable.clean("**Hello** there 😀 friend") == "Hello there friend")
check("nor list markers", Speakable.clean("- first thing") == "first thing")
check("numbers are", Speakable.clean("It's 3 # 4") == "It's 3 # 4")

// MARK: echo

check("its own words back are echo", Echo.isEcho(heard: "how are you", saying: "How are you today? I hope well."))
check("nothing intelligible is echo", Echo.isEcho(heard: "", saying: "Hello there."))
check("different words are an interruption", !Echo.isEcho(heard: "wait stop a second", saying: "How are you today?"))

var level = EchoLevel()
let tone = (0..<16_000).map { Float(sin(Double($0) * 0.07)) * 0.3 }
check("nothing learned, no verdict", level.isEcho(mic: tone, played: tone) == nil)
for _ in 0..<8 { level.hear(mic: tone.map { $0 * 0.05 }, played: tone) }
check("the leak is learned", level.leak.map { near($0, 0.05, 0.001) } ?? false)
check("its own echo is echo", level.isEcho(mic: tone.map { $0 * 0.06 }, played: tone) == true)
check("a voice much louder than it is not", level.isEcho(mic: tone.map { $0 * 0.4 }, played: tone) == false)
check("nothing playing, no verdict", level.isEcho(mic: tone, played: [Float](repeating: 0, count: 100)) == nil)
level.hear(mic: tone, played: tone)
check("one loud interruption barely moves it", level.leak.map { near($0, 0.05, 0.001) } ?? false)

// MARK: face

let visor = Expression.visor.face
check("two eyes and a mouth", FaceGeometry.shapes(visor).count == 3)
check("an open mouth is one solid", FaceGeometry.mouth(Viseme.ah.mouth).count == 1
    && FaceGeometry.mouth(Viseme.ah.mouth)[0].count == 30)
check("the eyes mirror", near(FaceGeometry.eye(visor.eye)[0].x, -FaceGeometry.eye(visor.eye, mirrored: true)[0].x, 1e-9))
let grid = FaceMatrix.grid(for: [visor])
let lit = FaceMatrix.lit(FaceGeometry.shapes(visor), on: grid)
check("the panel is 36 wide", grid.columns == 36)
check("some cells, not all", lit.count > 40 && lit.count < grid.columns * grid.rows / 2)
let opened = FaceMatrix.lit(FaceGeometry.shapes(Face(visor.eye, Viseme.ah.mouth)), on: grid)
check("an open mouth lights more", opened.count > lit.count)
let morphed = FaceGeometry.morph(FaceGeometry.eye(visor.eye), FaceGeometry.eye(Expression.wide.face.eye), 0.5, count: 40)
check("a morph has the points asked for", morphed.count == 40)

let blinks = Blinks()
check("open at the start", blinks.openness(at: 0) == 1)
let blinkCount = (0..<6000).map { Double($0) * 0.01 }.filter { blinks.openness(at: $0) < 0.5 }.count
check("a blink every few seconds", blinkCount > 30 && blinkCount < 400)

var performance = FacePerformance(origin: 0)
let words = SpokenWord.estimate("Hello there, my friend", duration: 1.2)
check("estimated words fill the clip", words.count == 4 && words.last!.end <= 1.2 && words[0].start > 0)
performance.say(words, at: 10)
check("the mouth moves while saying", (0..<20).contains { performance.pose(at: 10.1 + Double($0) * 0.05).face.mouth.aperture > 0.3 })
check("and rests long after", near(performance.pose(at: 30).face.mouth.aperture, 0, 1e-6))
performance.set(.thinking, at: 40)
check("a mood eases in", performance.pose(at: 40.05).face != Expression.smug.face)
check("and arrives", near(performance.pose(at: 41).face.eye.bow, Expression.smug.face.eye.bow, 1e-9))
performance.say(words, at: 50)
performance.hush(at: 50.3)
check("hushed, the mouth closes", near(performance.pose(at: 51).face.mouth.aperture, 0, 1e-6))

// MARK: log

let folder = FileManager.default.temporaryDirectory.appending(path: "cccheck-\(UUID().uuidString)")
if let log = try? ConversationLog(directory: folder) {
    _ = try? log.append(Turn(.person, "Hello."))
    _ = try? log.append(Turn(.companion, "Hi! How are", interrupted: true))
    let back = (try? ConversationLog.read(log.file)) ?? []
    check("the log reads back", back.count == 2 && back[1].interrupted && back[0].text == "Hello.")
    try? FileManager.default.removeItem(at: folder)
} else {
    check("the log opens", false)
}

print(failures == 0 ? "cccheck: all \(checks) checks pass" : "cccheck: \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
