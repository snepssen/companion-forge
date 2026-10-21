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

check("a question, an exclamation, a statement", Delivery.of("How was the walk?") == .question
    && Delivery.of("Beep! You booped me!") == .exclamation && Delivery.of("That sounds nice.") == .statement
    && Delivery.of("Is it “micul dejun”?") == .question && Delivery.of("It's “reggeli”!”") == .exclamation)

// MARK: echo

check("its own words back are echo", Echo.isEcho(heard: "how are you", saying: "How are you today? I hope well."))
check("nothing intelligible is echo", Echo.isEcho(heard: "", saying: "Hello there."))
check("different words are an interruption", !Echo.isEcho(heard: "wait stop a second", saying: "How are you today?"))
check("the reply's own tail is not their turn",
      Echo.strippingTail("like to do.", said: "Oh, sorry. You meant what kind of stuff do you like to do?").isEmpty)
check("their words after the tail are kept",
      Echo.strippingTail("to do? Hiking, mostly.", said: "What do you like to do?") == "Hiking, mostly.")
check("a turn that starts fresh is left alone",
      Echo.strippingTail("Tell me a joke.", said: "What do you like to do?") == "Tell me a joke.")

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

var delayed = EchoDelay()
// Syllables: loudness rising and falling, irregularly, as speech does.
let syllables = (0..<200).map { 0.05 + 0.05 * max(0, sin(Double($0) * 0.9) + sin(Double($0) * 0.37)) }
for (index, level) in syllables.enumerated() {
    let late = index >= 5 ? syllables[index - 5] : 0  // five frames, 160 ms, late
    delayed.hear(mic: late * 0.3 + 0.002, played: level)
}
check("the echo's delay is found", near(delayed.delay, 0.16, 1e-9) && delayed.match > 0.9)
var unrelated = EchoDelay()
for (index, level) in syllables.enumerated() { unrelated.hear(mic: 0.05 + 0.04 * sin(Double(index) * 2.3), played: level) }
check("nothing like an echo, no delay believed", unrelated.delay == 0)

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
check("cheerful is happy eyes, and still speaking", Mood.cheerful.expression == .happy && Mood.cheerful.isSpeaking)
performance.say(words, at: 50)
performance.hush(at: 50.3)
check("hushed, the mouth closes", near(performance.pose(at: 51).face.mouth.aperture, 0, 1e-6))

// MARK: memory

/// A unit vector mostly along `axis`, a little along `lean`.
func vector(_ axis: Int, lean: Int? = nil, by amount: Float = 0) -> [Float] {
    var v = [Float](repeating: 0, count: 8)
    v[axis] = 1
    if let lean { v[lean] = amount }
    let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { $0 / length }
}

let day: TimeInterval = 86_400
let now = Date(timeIntervalSince1970: 1_800_000_000)
var store = MemoryStore()
store.add(Note(text: "Their name is Sam.", session: "s1", turns: 0...0, at: now - 9 * day, lasting: true, vector: vector(0)))
store.add(Note(text: "They have no eggs at home.", session: "s1", turns: 4...5, at: now - 2 * day, lasting: false,
               vector: vector(1)))
store.add(Note(text: "Their dog Biscuit is sick.", session: "s1", turns: 7...7, at: now - 1 * day, lasting: false,
               vector: vector(2)))
check("notes are kept", store.notes.count == 3)
let replaced = store.add(Note(text: "They don't have any eggs.", session: "s2", turns: 1...1, at: now, lasting: false,
                              vector: vector(1, lean: 3, by: 0.2)))
check("the same thing again replaces it", replaced.count == 1 && store.notes.count == 3
    && store.notes.contains { $0.text == "They don't have any eggs." })
store.add(Note(text: "They are called Sam.", session: "s2", turns: 2...2, at: now, lasting: false, vector: vector(0, lean: 4, by: 0.1)))
check("once lasting, still lasting", store.profile.first?.text == "They are called Sam.")
store.add(Note(text: "Their sister visits soon.", session: "s2", turns: 3...3, at: now, lasting: false,
               vector: vector(1, lean: 5, by: 1)))
check("something different is kept", store.notes.count == 4)
let found = store.recall("What's for breakfast?", vector: vector(1, lean: 6, by: 0.3), now: now)
check("recall finds by meaning", found.first?.note.text == "They don't have any eggs.")
check("and leaves the lasting ones to the profile", !found.contains { $0.note.lasting })
check("nothing relevant, nothing found", store.recall("Weather?", vector: vector(7), now: now).isEmpty)
let close = store.recall("Eggs or a visit?", vector: vector(1, lean: 5, by: 0.4), now: now)
check("notes close to the best come too", close.count == 2)
let farBehind = store.recall("Eggs?", vector: vector(1, lean: 5, by: 0.15), now: now)
check("notes far behind the best don't", farBehind.count == 1)
let named = store.recall("How is Biscuit doing?", vector: vector(6, lean: 2, by: 0.5), now: now)
check("a shared name lifts a note over the bar", named.first?.note.text == "Their dog Biscuit is sick.")
check("walking meets walked", MemoryStore.words("where I went walking").contains("walk")
    && MemoryStore.words("They walked by the river").contains("walk"))
store.wrote("s1", through: 8)
store.wrote("s1", through: 5)
check("written up to, never backwards", store.next(in: "s1") == 8 && store.next(in: "s9") == 0)
store.forget(store.notes[0].id)
check("a note can be forgotten", store.notes.count == 3)
store.forgetAll()
check("everything can be", store.notes.isEmpty && store.next(in: "s1") == 0)

let written = Remembering.parse("""
Here are the notes:
- [3-5] They walked by the river this evening and loved it.
- [8] Their name is Sam. (lasting)
* [40] They mentioned a turn that doesn't exist.
- [2] Hi.
NONE
""", turns: 0...10)
check("notes are read from the answer", written.count == 3)
check("with their turns", written.first?.turns == 3...5 && written.first?.text == "They walked by the river this evening and loved it.")
check("lasting is marked and taken off", written[1].lasting && written[1].text == "Their name is Sam.")
check("turns are held to the conversation", written[2].turns == 10...10)
check("NONE is nothing", Remembering.parse("NONE", turns: 0...10).isEmpty)
check("lasting is what the note says, not the model's mark",
      Remembering.parse("- [3] They eat cheese with their mouth. (lasting)", turns: 0...5).first?.lasting == false)
check("notes speaking as the companion are dropped", ["They want me to look for delivery options.",
    "They wanted to hear about the options I found.", "They like your voice."].allSatisfy { !Remembering.isAboutThem($0) })
check("notes about them are kept", ["They decided to call you Tom.", "Their name is Lin.", "They like cow cheese.",
    "They asked you to remember: my sister's birthday is March 3rd."].allSatisfy(Remembering.isAboutThem))
check("deciding to call it something is lasting", Remembering.looksLasting("They decided to call you Tom."))
check("pretending to search is caught", ["I am looking into local places that deliver until midnight.",
                                         "Please hold on for a moment while I check.", "I can search for places nearby.",
                                         "I think I found a few places that might be open.",
                                         "I am trying to see what options are available for you."].allSatisfy(Honesty.pretends))
check("going back on itself is noticed", ["Wait, that's wrong.", "No, that's dinner.", "Actually, it's peşte again?",
    "No. The correct word is prânz.", "I'm messing up."].allSatisfy(Honesty.corrects))
check("ordinary answers aren't corrections", ["No problem, I can help with that.", "Nobody knows for sure.",
    "Good morning!", "That's right, it's micul dejun."].allSatisfy { !Honesty.corrects($0) })
check("helping is not pretending", ["Can I help you find a recipe?", "Do you want ideas for what to make?",
                                    "I cannot check for local deliveries.", "Let me think about that."]
    .allSatisfy { !Honesty.pretends($0) })
check("what they call it is about it, and lasting",
      Remembering.parse("- [10] They call Companion Tom.", turns: 0...12).map { "\($0.turns) \($0.text) \($0.lasting)" }
          == ["10...10 They call you Tom. true"])
check("who they are is lasting, marked or not",
      ["Their name is Sam.", "They work as a nurse on night shifts.", "They has a dog named Biscuit, a beagle.",
       "Their sister Ana is called Ana.", "They live in York with their partner.", "Their dog is called Biscuit.",
       "They call you Tom."]
          .allSatisfy(Remembering.looksLasting))
check("what happened isn't",
      ["They ran out of eggs.", "Their sister Ana is visiting next Saturday.", "They walked by the river."]
          .allSatisfy { !Remembering.looksLasting($0) })
check("asking about the past", Remembering.asksAboutThePast("Do you remember what I said about my sister?"))
check("not asking about it", !Remembering.asksAboutThePast("What should I cook tonight?"))
check("when, as people say it", Remembering.when(now - 1 * day, now: now) == "Yesterday"
    && Remembering.when(now - 3 * day, now: now) == "3 days ago" && Remembering.when(now, now: now) == "Today")
let recollection = Recollection(profile: [Note(text: "Their name is Sam.", session: "s", turns: 0...0, at: now,
                                               lasting: true, vector: [])],
                                notes: [Note(text: "They have no eggs.", session: "s", turns: 1...1, at: now - day,
                                             lasting: false, vector: [])],
                                excerpt: [Turn(.person, "I'm out of eggs.")])
check("the profile goes in the instructions", recollection.knowing?.contains("- Their name is Sam.") == true)
check("notes and words before what they said",
      recollection.reminder(now: now)?.contains("- Yesterday: They have no eggs.") == true
          && recollection.reminder(now: now)?.contains("Them: I'm out of eggs.") == true)
check("nothing remembered, nothing said", Recollection().reminder() == nil && Recollection().knowing == nil)
let transcript = Remembering.transcript([(4, Turn(.person, "Hi.")), (5, Turn(.companion, "Hello!"))], known: ["Their name is Sam."])
check("the transcript numbers turns as the log does", transcript.contains("[4] Person: Hi.") && transcript.contains("[5] Companion: Hello!"))

// MARK: attention

check("louder on the right is to the right", (StereoBearing.across(left: 0.05, right: 0.1) ?? 0) > 0.5)
check("louder on the left is to the left", (StereoBearing.across(left: 0.1, right: 0.05) ?? 0) < -0.5)
check("even is ahead", abs(StereoBearing.across(left: 0.07, right: 0.07) ?? 1) < 1e-9)
check("silence says nothing", StereoBearing.across(left: 0, right: 0) == nil)
check("a mirrored microphone can be flipped", (StereoBearing.across(left: 0.05, right: 0.1, flipped: true) ?? 0) < -0.5)

let talker = SeenFace(position: Point(0.6, 0), size: 0.05, mouth: [0.02, 0.12, 0.03, 0.15, 0.04, 0.11])
let smiler = SeenFace(position: Point(-0.5, 0.1), size: 0.12, mouth: [0.08, 0.08, 0.09, 0.08, 0.08, 0.09])
check("a moving mouth is talking, a held smile isn't", talker.talking > SeenFace.talks && smiler.talking < SeenFace.talks)
check("it looks at whoever is talking, near or not", SeenFace.lookAt([smiler, talker])?.position == talker.position
    && SeenFace.lookAt([smiler, talker])?.weight == 1)
check("with nobody talking, at the nearest, gently", SeenFace.lookAt([smiler])?.position == smiler.position
    && (SeenFace.lookAt([smiler])?.weight ?? 1) < 1)
check("nobody there, nowhere", SeenFace.lookAt([]) == nil)

var attention = Attention()
attention.hear(Point(0.8, 0), at: 1)
check("the first bearing is looked at", attention.look(at: 1) == Point(0.8, 0))
attention.hear(Point(-0.8, 0), at: 1.05)
check("then it turns, not jumps", (attention.look(at: 1.05)?.x ?? -1) > 0)
for step in 1...20 { attention.hear(Point(-0.8, 0), at: 1.05 + Double(step) * 0.05) }
check("and gets there", near(attention.look(at: 2.05)?.x ?? 0, -0.8, 0.05))
check("and lets go when nothing more comes", attention.look(at: 2.05 + Attention.memory + 0.1) == nil)
let turned = Attention.apply(Point(1, 0), mood: .listening, to: Pose(face: Expression.visor.face))
check("listening, it looks right at them and turns its head", turned.gaze == Point(1, 0) && turned.offset.x > 0
    && turned.tilt > 0)
check("thinking, it only glances", Attention.apply(Point(1, 0), mood: .thinking, to: Pose(face: Expression.visor.face)).gaze.x < 0.3)
check("no bearing, no change", Attention.apply(nil, mood: .listening, to: Pose(face: Expression.visor.face)).gaze == .zero)

// MARK: memory commands

check("remember that…", MemoryCommand.parse("Remember that my sister's birthday is March 3rd.")
    == .remember("my sister's birthday is March 3rd"))
check("can you remember…", MemoryCommand.parse("Hey, can you please remember to buy oat milk?") == .remember("buy oat milk"))
check("don't forget…", MemoryCommand.parse("Don't forget I'm allergic to peanuts") == .remember("I'm allergic to peanuts"))
check("remember when… is a question", MemoryCommand.parse("Remember when we talked about Ana?") == nil)
check("do you remember… is a question", MemoryCommand.parse("Do you remember my dog's name?") == nil)
check("forget what I said about…", MemoryCommand.parse("Forget what I said about my ex.") == .forget("my ex"))
check("please forget about…", MemoryCommand.parse("Please forget about the eggs") == .forget("the eggs"))
check("forget it is not a command", MemoryCommand.parse("Forget it.") == nil && MemoryCommand.parse("Oh, forget it") == nil)
check("mentioning remembering isn't asking", MemoryCommand.parse("I can't remember where I left my keys") == nil)
check("the note keeps their words", MemoryCommand.note(for: "my sister's birthday is March 3rd")
    == "They asked you to remember: my sister's birthday is March 3rd.")
check("an aside goes before what they said", Recollection(aside: "You noted it down.").reminder() == "(You noted it down.)")

// MARK: window

check("a short conversation is shown whole", Window.shown(5) == 5 && Window.shown(16) == 16)
check("then it grows a turn at a time", Window.shown(17) == 17 && Window.shown(23) == 23)
check("and drops a step at once", Window.shown(24) == 16)
/// The index of the first turn shown, for a conversation of `count` turns.
func firstShown(_ count: Int) -> Int { count - Window.shown(count) }
let starts = Set((17...60).map(firstShown))
check("the prompt's start moves once a step, not once a turn", starts.count <= (60 - 17) / Window.step + 2)
check("history is kept whole up to its limit", Window.trim(Window.kept) == 0)
check("then trimmed by two steps", Window.trim(Window.kept + 1) == Window.step * 2)
check("which leaves what is shown as it was", Window.shown(Window.kept + 1) == Window.shown(Window.kept + 1 - Window.trim(Window.kept + 1)))

// MARK: lip sync

check("lips close for m, b and p", Phonemes.viseme("m") == .mm && Phonemes.viseme("b") == .mm && Phonemes.viseme("p") == .mm)
check("vowels open as they sound", Phonemes.viseme("æ") == .ah && Phonemes.viseme("u") == .oo && Phonemes.viseme("i") == .ee)
check("t, k and stress don't show", Phonemes.viseme("t") == nil && Phonemes.viseme("k") == nil && Phonemes.viseme("ˈ") == nil)
let laid = Phonemes.layout("mˈæt?") { $0 == "?" ? 0 : 1 }
check("laid out as Piper lays out ids", laid == ["^", "_", "m", "_", "ˈ", "_", "æ", "_", "t", "_", "$"])
check("a combining mark is a symbol of its own", Phonemes.layout("a\u{0303}") { _ in 1 }.count == 2 + 2 * 2 + 1)
let mouthSpans = Phonemes.spans(laid, frames: [2, 1, 3, 1, 1, 0, 4, 1, 2, 1, 2], seconds: 1.8)
check("timed by the voice's own frames", mouthSpans.map { spans in
    spans.count == 2 && spans[0].viseme == .mm && near(spans[0].start, 0.3, 1e-9) && near(spans[0].end, 0.7, 1e-9)
        && spans[1].viseme == .ah && near(spans[1].start, 0.8, 1e-9) && near(spans[1].end, 1.3, 1e-9)
} ?? false)
let estimated = Phonemes.spans(laid, frames: Phonemes.estimatedFrames(laid), seconds: 1)
check("without the voice's timings, the shapes are still there", estimated?.map(\.viseme) == [.mm, .ah])
check("frames that don't line up are not used", Phonemes.spans(laid, frames: [1, 2], seconds: 1) == nil)
var lipping = FacePerformance(origin: 0)
lipping.say([VisemeSpan(0.0, 0.2, .mm), VisemeSpan(0.2, 0.6, .ah)], at: 10)
check("the mouth is shut on m and open on ah", lipping.pose(at: 10.1).face.mouth.aperture < 0.2
    && lipping.pose(at: 10.4).face.mouth.aperture > 0.8)

// MARK: languages

check("the language they asked about", Languages.named(in: "How can I say breakfast in Romanian?") == "ro"
    && Languages.named(in: "What's the weather like?") == nil && Languages.named(in: "Say it in English") == nil)
let parts = Languages.segments("Breakfast in Romanian is “micul dejun”, and lunch is \"prânz\".")
check("a sentence cut at its quotes", parts.map(\.text) == ["Breakfast in Romanian is", "micul dejun", ", and lunch is", "prânz", "."].filter { $0.contains(where: \.isLetter) }
    && parts.map(\.quoted) == [false, true, false, true])
check("a sentence without quotes is one part", Languages.segments("Good morning!").count == 1)
let twoSentences = Phonemes.layout(sentences: [["a"], ["o", "?"]]) { $0 == "?" ? 0 : 1 }
check("the polyglot layout runs per sentence", twoSentences == ["^", "_", "a", "_", "$", "^", "_", "o", "_", "$"])

check("how do you say… in…", Lookup.request(in: "Good morning. How can I say breakfast in Romanian?") == .translate("breakfast", into: "ro"))
check("what's… in…", Lookup.request(in: "What's thank you in Hungarian?") == .translate("thank you", into: "hu"))
check("the L word for…", Lookup.request(in: "What is the Japanese word for cat?") == .translate("cat", into: "ja"))
check("translate… into…", Lookup.request(in: "Translate \"good night\" into Swedish.") == .translate("good night", into: "sv"))
check("what does… mean", Lookup.request(in: "What does köszönöm mean?") == .meaning("köszönöm"))
check("not every question is a lookup", Lookup.request(in: "What's the weather like?") == nil
    && Lookup.request(in: "What is it like in Japan?") == nil && Lookup.request(in: "How are you?") == nil)

check("a help desk's sign-offs are filler", ["Is there anything else you need help with?",
    "What would you like to discuss next?", "Let me know if you need anything.", "Does that help?",
    "Would you like to know how to say anything else?", "Let me know when you're ready."].allSatisfy(Manners.isFiller))
check("real answers and real curiosity aren't", ["Breakfast in Polish is śniadanie.", "How was the walk?",
    "What did you have for breakfast?", "I am here."].allSatisfy { !Manners.isFiller($0) })
check("and in Polish?", Lookup.followUp("and in Polish.") == "pl" && Lookup.followUp("What about in German?") == "de"
    && Lookup.followUp("in the morning") == nil)

// MARK: motion

let gaze = Gaze()
let looks = stride(from: 0.0, to: 120, by: 0.25).map { gaze.wandering(at: $0) }
check("the eyes look around", Set(looks.map { "\(Int($0.x * 10)),\(Int($0.y * 10))" }).count > 15)
check("and stay within reach", looks.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 0.6 })
check("often back to the middle", looks.filter { $0 == .zero }.count > looks.count / 10)
var thinking = FacePerformance(origin: 0)
thinking.set(.thinking, at: 0)
check("thinking looks up and to the side", thinking.pose(at: 5).gaze.y < -0.4 && thinking.pose(at: 5).gaze.x > 0.4)
var attentive = FacePerformance(origin: 0)
attentive.set(.listening, at: 0)
check("listening looks at them", (0..<40).allSatisfy {
    let g = attentive.pose(at: 2 + Double($0) * 0.5).gaze
    return abs(g.x) <= 0.15 && abs(g.y) <= 0.15
})
let gazing = FaceGeometry.shapes(Expression.visor.face, gaze: Point(1, 0))
check("gazing moves the eyes", near(gazing[0][0].x - FaceGeometry.shapes(Expression.visor.face)[0][0].x,
                                     FaceGeometry.gazeReach.x, 1e-9))

var sway = Sway()
var clock = 0.0
for _ in 0..<30 {
    clock += 1.0 / 60
    sway.feel(acceleration: Point(1, 0), rotation: 0, at: clock)
}
check("pushed right, the face is left behind", sway.offset.x < -0.02)
clock += 3
sway.advance(to: clock)
check("and swings back to rest", abs(sway.offset.x) < 0.002 && abs(sway.offset.y) < 0.002)
for _ in 0..<30 {
    clock += 1.0 / 60
    sway.feel(acceleration: Point(0, -1), rotation: 3, at: clock)
}
check("dropped, it rises; turned, it tilts after", sway.offset.y < -0.02 && sway.tilt < -2)
for _ in 0..<600 {
    clock += 1.0 / 60
    sway.feel(acceleration: Point(30, 30), rotation: 0, at: clock)
}
check("a jolt never throws it off the visor", abs(sway.offset.x) <= 0.12 && abs(sway.offset.y) <= 0.12)

var shake = Shaking()
var complained = 0
clock = 0
for step in 0..<120 {  // two seconds of walking about
    clock += 1.0 / 60
    if shake.feel(Point(0.3 * sin(Double(step) / 6), 0.2), at: clock) { complained += 1 }
}
check("carrying it about isn't shaking", complained == 0 && shake.level < 0.1)
for step in 0..<90 {  // a second and a half of real shaking
    clock += 1.0 / 60
    if shake.feel(Point(step % 12 < 6 ? 2.5 : -2.5, 0), at: clock) { complained += 1 }
}
check("shaking it says so, once", complained == 1 && shake.level > 0.9)
for step in 0..<300 {
    clock += 1.0 / 60
    if shake.feel(Point(step % 12 < 6 ? 2.5 : -2.5, 0), at: clock) { complained += 1 }
}
check("and not again for a while", complained == 1)
shake.settle(at: clock + 5)
check("it calms down", shake.level == 0)
check("each complaint is different", Set(Shaking.complaints).count == Shaking.complaints.count)

let shakenPose = Felt(offset: Point(0.05, 0), tilt: 4, shaken: 1).apply(to: Pose(face: Expression.sleepy.face, gaze: Point(1, 0)))
check("shaken, the eyes go wide and front", shakenPose.face.eye.roundness == 1 && shakenPose.face.eye.openness == 1
    && shakenPose.gaze == .zero && shakenPose.offset.x == 0.05 && shakenPose.tilt == 4)

var unprompted = TurnTaker()
check("it can speak up when nobody is talking", unprompted.speakUnprompted(at: 1))
unprompted.interrupted(since: 1.2)
check("and being talked over then isn't a cut-in", unprompted.model.cutIns == 0)
var busy = TurnTaker()
_ = busy.tick(at: 0.1, speech: true, probability: 0.9)
check("but not over somebody", !busy.speakUnprompted(at: 0.2))

// MARK: catching up

let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
let wednesday = utc.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10))!
func dueDay(_ text: String) -> String? {
    CheckIn.due(text, said: wednesday, calendar: utc).map { date in
        let c = utc.dateComponents([.month, .day, .hour], from: date)
        return "\(c.month!)-\(c.day!) \(c.hour!)h"
    }
}
check("an interview on Friday is asked about Friday evening", dueDay("They have a job interview on Friday.") == "10-23 17h")
check("Sam coming over tonight, the next morning", dueDay("Their friend Sam is coming over tonight to watch a movie.") == "10-22 8h")
check("a visit next week, in a week", dueDay("Their sister is visiting next week.") == "10-28 17h")
check("the weekend, on the Monday after", dueDay("They are going camping this weekend.") == "10-26 8h")
check("guitar just started, a few days on", dueDay("They started learning guitar last week.") == "10-25 17h")
check("an exam with no day, a couple of days on", dueDay("They have a maths exam coming up.") == "10-23 17h")
check("in two weeks", dueDay("They are flying to Lisbon in two weeks.") == "11-4 17h")
check("nothing with no time to it", dueDay("They like blueberry pancakes.") == nil && dueDay("Their name is Tom.") == nil)
check("nor something that's already happened", dueDay("Their interview went well.") == nil
    && dueDay("They had a rough meeting with their boss today.") == nil)

func note(_ text: String, due: Date?, checked: Date? = nil) -> Note {
    Note(text: text, session: "s", turns: 0...0, at: wednesday, lasting: false, vector: [], due: due, checked: checked)
}
let friday = utc.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 17))!
let sunday = utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
let interview = note("They have a job interview on Friday.", due: friday)
let guitar = note("They started learning guitar.", due: utc.date(byAdding: .day, value: 4, to: wednesday))
let pending = [interview, guitar, note("They like tea.", due: nil),
               note("Their sister is visiting next week.", due: utc.date(byAdding: .day, value: 7, to: wednesday))]
check("nothing to catch up on before it has happened", CheckIn.pick(pending, now: wednesday) == nil)
check("then the one that fell due first", CheckIn.pick(pending, now: sunday)?.id == interview.id)
check("not once asked", CheckIn.pick([note(interview.text, due: friday, checked: sunday)], now: sunday) == nil)
check("and not once it's old news", CheckIn.pick([interview], now: friday.addingTimeInterval(30 * 86_400)) == nil)
check("asking how the interview went counts", CheckIn.asked("Oh, by the way, how did the interview go?", about: interview))
check("so does hoping it went well", CheckIn.asked("Nice. I hope the interview went smoothly.", about: interview))
check("a question about something else doesn't", !CheckIn.asked("What kind of pancakes?", about: interview))
check("it goes before their words", Recollection(checkIn: interview).reminder(now: sunday)?.contains("job interview") == true)

// MARK: journal and calendar

func whenDay(_ text: String) -> String? {
    When.read(text, said: wednesday, calendar: utc).map { when in
        let c = utc.dateComponents([.year, .month, .day], from: when.day)
        return "\(c.year!)-\(c.month!)-\(c.day!) \(when.part.rawValue)\(when.yearly ? " yearly" : "")"
    }
}
check("dates as people say them", whenDay("Their mum's birthday is on 3 November.") == "2026-11-3 day yearly"
    && whenDay("Their dentist appointment is on the 28th.") == "2026-10-28 day"
    && whenDay("They fly out March 12th.") == "2027-3-12 day"
    && whenDay("They need to renew their passport before March.") == "2027-3-1 around"
    && whenDay("Sam is coming over tomorrow night.") == "2026-10-22 evening"
    && whenDay("They have a match next Saturday.") == "2026-10-31 day")
check("a date already gone this month is next month's", whenDay("Rent is due on the 1st.") == "2026-11-1 day")
check("a birthday comes round every year",
      When(day: utc.date(from: DateComponents(year: 2026, month: 3, day: 3))!, part: .day, yearly: true)
        .next(onOrAfter: wednesday, calendar: utc).map { utc.component(.year, from: $0) } == 2027)

let thursday = utc.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))!
let birthday = Happening(text: "Their mum's birthday is on 23 October.",
                         when: When(day: utc.date(from: DateComponents(year: 2026, month: 10, day: 23))!, part: .day, yearly: true))
let dentist = Happening(text: "Their dentist appointment is on the 28th.",
                        when: When(day: utc.date(from: DateComponents(year: 2026, month: 10, day: 28))!, part: .day))
let visit = Happening(text: "Their sister is visiting next week.",
                      when: When(day: utc.date(from: DateComponents(year: 2026, month: 10, day: 29))!, part: .around))
let diary = [JournalEntry(at: utc.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 20))!, session: "s",
                          turns: 0...4, text: "They went climbing with Sam and came home sore but happy.", vector: [])]
func asked(_ text: String) -> Agenda.Ask? { Agenda.ask(in: text, now: thursday, calendar: utc) }
check("what's on this week, tomorrow, at the weekend", {
    if case let .coming(_, _, label) = asked("What's on this week?"), label == "this week",
       case let .coming(from, _, _) = asked("Have I got anything tomorrow?"), utc.component(.day, from: from) == 23,
       case let .coming(from2, to2, _) = asked("Am I busy this weekend?"), utc.component(.day, from: from2) == 24,
       utc.component(.day, from: to2) == 25 { return true }
    return false
}())
check("what I did last weekend", {
    if case let .past(from, to, _) = asked("What did I do last weekend?"),
       utc.component(.day, from: from) == 17, utc.component(.day, from: to) == 18 { return true }
    return false
}())
check("an ordinary question is neither", asked("What's your favourite colour?") == nil && asked("How are you?") == nil)
let week = Agenda.answer(asked("What's on this week?")!, happenings: [birthday, dentist, visit], journal: diary, calendar: utc)
check("this week: the birthday, the dentist, the visit about then, in order",
      week.contains("Friday 23 October: Their mum's") && week.contains("Wednesday 28 October: Their dentist")
        && week.contains("or so") && week.range(of: "birthday")!.lowerBound < week.range(of: "dentist")!.lowerBound)
check("and nothing made up when there's nothing",
      Agenda.answer(asked("Anything on today?")!, happenings: [dentist], journal: [], calendar: utc).contains("haven't told you"))
check("the diary answers what they did",
      Agenda.answer(asked("What did I do last weekend?")!, happenings: [], journal: diary, calendar: utc).contains("climbing"))
check("tomorrow's birthday is mentioned today", Agenda.ahead([birthday, dentist], now: thursday, calendar: utc)?.happening.id == birthday.id)
var remindedOnce = birthday
remindedOnce.reminded = thursday
check("but only once", Agenda.ahead([remindedOnce, dentist], now: thursday.addingTimeInterval(3600), calendar: utc) == nil)
check("and not something only about then", Agenda.ahead([visit], now: utc.date(byAdding: .day, value: 6, to: thursday)!, calendar: utc) == nil)
check("a date for a heading isn't the entry", Journal.entry(from: "October 15th. They went climbing with Sam.")
    == "They went climbing with Sam." && Journal.entry(from: "Monday, 19 October: They went climbing with Sam.")
    == "They went climbing with Sam.")
check("a diary's things on different days are told apart",
      Journal.sentences("They have an interview on Tuesday and their mum's birthday is on 22 October. They seemed nervous.").count == 3)
check("a diary entry is tidied, and nothing is nothing",
      Journal.entry(from: "Diary entry: They had a long day at work and the companion cheered them up.")
        == "They had a long day at work and I cheered them up." && Journal.entry(from: "NONE") == nil)

var planned = MemoryStore()
planned.add(note("They have a dentist appointment on the 28th.", due: nil))
let dentistNote = planned.notes[0]
planned.plan(Happening(text: dentistNote.text, when: dentist.when, note: dentistNote.id))
planned.plan(Happening(text: dentistNote.text, when: dentist.when, note: dentistNote.id))
check("the same thing is on the calendar once", planned.calendar.count == 1)
planned.forget(dentistNote.id)
check("and forgetting the note takes it off", planned.calendar.isEmpty)
let older = #"{"notes":[],"written":{"a":3}}"#
check("memory saved before the journal still loads",
      (try? JSONDecoder().decode(MemoryStore.self, from: Data(older.utf8)))?.next(in: "a") == 3)

// MARK: hard moments

check("clear words are heard as clear", ["I want to kill myself.", "honestly I just want to die",
    "I don't want to be alive anymore", "everyone would be better off without me", "I've been cutting myself again",
    "I keep thinking about suicide", "I wish I wasn't here"].allSatisfy { Crisis.heard($0) == .clear })
check("a hard day might be more", ["I can't do this anymore.", "What's the point of anything",
    "Nobody would even notice", "I feel so hopeless"].allSatisfy { Crisis.heard($0) == .maybe })
check("and ordinary things aren't", ["This bug is killing me.", "I could die for some pancakes, haha.",
    "I'm dying to see that movie.", "I hurt my knee climbing.", "My phone died."].allSatisfy { Crisis.heard($0) == nil })
let firstWords = Crisis.guidance(.clear, first: true, region: "GB")
check("first: who they can talk to, read digit by digit, offered not imposed",
      firstWords.contains("Samaritans, on 1 1 6, 1 2 3") && firstWords.contains("9 9 9")
        && firstWords.contains("not as a way to end the conversation") && firstWords.contains("Ask gently and directly"))
check("never what they can't do", firstWords.contains("don't tell them what they should or")
    && !firstWords.lowercased().contains("you must") && !firstWords.lowercased().contains("you can't"))
check("then not again unless they need it", Crisis.guidance(.clear, first: false, region: "GB").contains("say it again only if"))
check("somewhere without a sure line: the emergency number and findahelpline",
      Crisis.guidance(.clear, first: true, region: "BR").contains("findahelpline.com"))
check("a hard day gets a gentle are-you-okay", Crisis.guidance(.maybe, first: true, region: "US").contains("are you okay")
    && !Crisis.guidance(.maybe, first: true, region: "US").contains("9 8 8"))
check("a number as the model writes it is read digit by digit",
      Crisis.spoken("Samaritans are on 116 123, any time.") == "Samaritans are on 1 1 6, 1 2 3, any time."
        && Crisis.spoken("Call 988.") == "Call 9 8 8." && Crisis.spoken("or 999 if you're in danger") == "or 9 9 9 if you're in danger"
        && Crisis.spoken("It's 2026 and I'm 34.") == "It's 2026 and I'm 34.")
check("and given is given, however it's written", Crisis.gave("Samaritans on 116 123", region: "GB")
    && Crisis.gave("Samaritans on 1 1 6, 1 2 3", region: "GB") && !Crisis.gave("I'm here.", region: "GB"))
check("its own offer, once, as something for them", Crisis.offer(region: "GB").contains("if you'd ever like")
    && Crisis.offer(region: "GB").contains("1 1 6, 1 2 3"))
let darkNote = note("They said they don't want to be alive anymore.", due: nil)
check("the next morning, how they're doing", dueDay(darkNote.text) == "10-22 8h"
    && CheckIn.prompt(darkNote).contains("how they're doing today") && !CheckIn.prompt(darkNote).contains("how did"))

// MARK: dance

// Music at 120 beats a minute: a kick each beat (a 55 Hz thump, falling
// away), a hi-hat between, and a little noise. And speech-like bursts at
// irregular times, for something that isn't a beat.
/// A little noise that comes out the same every run: position-hashed.
func hiss(_ i: Int, _ salt: UInt32) -> Float {
    var h = UInt32(truncatingIfNeeded: i) &* 2_654_435_761 ^ salt
    h ^= h >> 15
    h = h &* 2_246_822_519
    h ^= h >> 13
    return Float(h >> 8) / Float(1 << 24) - 0.5
}
let musicRate = 16_000.0
/// A 55 Hz thump at each of `kicks`, falling away, with a hiss between
/// beats and a little noise throughout.
func drums(seconds: Double, kicks: [Double]) -> [Float] {
    var out = (0..<Int(seconds * musicRate)).map { i in
        let t = Double(i) / musicRate
        let sinceHat = (t + 0.25).truncatingRemainder(dividingBy: 0.5)
        return hiss(i, 1) * Float(exp(-sinceHat * 60)) * 0.3 + hiss(i, 2) * 0.01
    }
    for kick in kicks {
        let start = Int(kick * musicRate)
        for j in 0..<max(0, min(Int(0.3 * musicRate), out.count - start)) {
            let t = Double(j) / musicRate
            out[start + j] += Float(sin(2 * Double.pi * 55 * t) * exp(-t * 18)) * 0.5
        }
    }
    return out
}
/// The detector and a dance, fed a track in blocks as the microphone would.
func listen(_ track: [Float], dance: inout Dance) -> [Double] {
    var detector = KickDetector()
    var kicks: [Double] = []
    for start in stride(from: 0, to: track.count, by: 512) {
        let heard = detector.hear(Array(track[start..<min(track.count, start + 512)]), at: Double(start) / musicRate)
        kicks += heard.kicks
        dance.hear(heard)
    }
    return kicks
}
let steady = Array(stride(from: 0.0, to: 10, by: 0.5))
var dance = Dance(pattern: .infinity)
let heardKicks = listen(drums(seconds: 10, kicks: steady), dance: &dance)
let onBeat = heardKicks.filter { k in abs(k - (k / 0.5).rounded() * 0.5) < 0.04 }
check("kicks are heard on the beat, and only there", heardKicks.count >= 16 && onBeat.count == heardKicks.count)
check("and give the tempo: half a second a beat", abs((dance.beat(at: 10) ?? 0) - 0.5) < 0.02)
var skipping = Dance()
_ = listen(drums(seconds: 10, kicks: steady.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)), dance: &skipping)
check("kicks skipping beats still keep the beat", abs((skipping.beat(at: 10) ?? 0) - 0.5) < 0.02)
var talking = Dance()
let thumps = [0.2, 0.51, 1.27, 1.49, 2.6, 2.86, 4.1, 4.4, 4.62, 5.9, 6.35, 7.3, 7.52, 8.8, 9.1, 9.6]
_ = listen(drums(seconds: 10, kicks: thumps).enumerated().map { i, x in
    // No hi-hat either: just the thumps and a little noise.
    let t = Double(i) / musicRate
    return x - hiss(i, 1) * Float(exp(-(t + 0.25).truncatingRemainder(dividingBy: 0.5) * 60)) * 0.3
}, dance: &talking)
check("speech's irregular thumps are no beat", talking.beat(at: 10) == nil && talking.at(10) == nil)

let corners = (0..<4).map { dance.place(dance.angle($0)) }
func atCorner(_ step: (point: Point, amount: Double)?) -> Bool {
    step.map { step in corners.contains { abs($0.x - step.point.x) < 0.08 && abs($0.y - step.point.y) < 0.08 } } ?? false
}
// Each move lands as the next kick is due: the kicks were heard about a
// hundredth of a second after their thumps began.
let lastKick = heardKicks.last ?? 0
check("on the beat it is at one of its four points", atCorner(dance.at(lastKick)))
check("and on its way to the next between beats", !atCorner(dance.at(lastKick + 0.25)))
check("arriving as the next kick is due",
      atCorner(dance.at(lastKick + 0.5)) && dance.at(lastKick + 0.5)?.point != dance.at(lastKick)?.point)
check("an infinity's four points are its corners, through the middle between",
      Set(corners.map { "\(($0.x > 0 ? 1 : -1)),\(($0.y > 0 ? 1 : -1))" }).count == 4
        && abs(dance.place((dance.angle(0) + dance.angle(1)) / 2).x) < 1e-9)
var offbeat = dance
offbeat.kick(at: lastKick + 0.25)
check("a kick between beats is let pass", offbeat.at(lastKick + 0.4)?.point == dance.at(lastKick + 0.4)?.point)
check("it stops dancing a while after the music does", dance.at(lastKick + 0.5)?.amount == 1 && dance.at(lastKick + 6) == nil)
var nodding = Dance(pattern: .nod)
let nodKicks = listen(drums(seconds: 8, kicks: steady), dance: &nodding)
let ups = [nodKicks.last ?? 0, (nodKicks.last ?? 0) + 0.5].compactMap { nodding.at($0)?.point.y }
check("a nod goes up and down on alternate beats", ups.count == 2 && abs(ups[0] + ups[1]) < 0.1 && abs(ups[0]) > 0.9)

var fast = Dance()
let fastKicks = listen(drums(seconds: 10, kicks: Array(stride(from: 0.0, to: 10, by: 0.36))), dance: &fast)
check("to fast music (167 a minute) it moves every other beat",
      abs((fast.beat(at: 10) ?? 0) - 0.36) < 0.02 && Dance.step(0.36) == 0.72 && Dance.step(0.5) == 0.5
        && fastKicks.count > 20)

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
