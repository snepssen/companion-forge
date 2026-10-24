# companion-forge

A companion you talk with out loud, with a protogen visor for a face. It
listens, waits until you have finished rather than until a timer runs out,
answers in a voice, and learns how you pause. It is one person's companion:
it knows their voice, keeps a diary of their days, and catches up on what they
told it. Everything runs locally, and what it remembers is encrypted on the
device.

It has run on an M1 Mac, an iPhone 17 and an iPad with M4.

    mic ─▶ echo canceller ─▶ VAD ─▶ turn taker ─▶ ASR ─▶ language model ─▶ voice ─▶ speakers
                                        ▲                                     │
                                        └──── learned pauses, echo level ◀────┘

| stage | model |
|---|---|
| VAD | Silero VAD v5 (ONNX) |
| ASR | Parakeet Ultra through FluidAudio, on the Neural Engine |
| language model | Gemma 4 E4B, 4-bit MLX (Qwen3 4B or Gemma 4 E2B for 8 GB phones) |
| voice | the polyglot snepssen from voice-polyglot (the one `build.sh` bundles), on voice-core's Piper, English included |
| face | protoke's visor, ported to Swift and drawn as an LED panel |
| memory | bge-small-en-v1.5 on MLX, over notes the language model writes |
| whose voice | CAM++ voiceprints through FluidAudio |
| dictionary | English Wiktionary (kaikki.org's extract), cut down to SQLite |

## Turns, not timers

interpreter-forge cut speech on pauses, punctuation and a fixed 5 s ceiling. A
conversation can do better, because every time you go quiet and then carry on,
that gap was a pause inside your turn. The turn taker (`TurnTaking.swift`)
keeps the last 200 of those and waits for a silence longer than nearly all of
them: the 90th percentile, shortened after a question, lengthened when the
words so far trail off on "and" or "um", and pushed out further each time a
reply cut you off. It starts at 0.9 s and moves from there. What it has
learned is shown in Settings.

The reply is drafted while you are still pausing, as soon as the pause is long
enough to be worth a guess: transcribed, written and turned into speech, but
held. If you carry on, it is thrown away; if the pause runs to the learned
wait, what is ready plays at once. Most of the model's time is spent inside
the silence you were leaving anyway.

## Speaking out loud

The microphone and the voice share one `AVAudioEngine`. On an iPhone or iPad
Apple's voice processing is on, which cancels the voice's echo. It can only
subtract what it plays itself, so nothing is played any other way. On a Mac
it is not used: on the M1 (2026-10-20) its microphone side delivered nothing
at all, whatever devices it was pointed at, so the microphone is taken as it
is and the checks below keep the voice out, with the first words of a turn
also checked against the end of the last reply. Some echo always gets
through, so talking over a reply has to pass two checks. It has to sound like
confident speech for 0.35 s. Then it is compared two ways. By its words: the
reply's own voice coming back says the words being said. And by its level:
the companion knows what it played, learns how loud that comes back in this
room (`EchoLevel`), and a person talking over it is louder than twice that.
Either check can call it echo. Only something that passes both stops the
reply, and then only the part actually said is kept in the conversation.

## The face

protoke's face is continuous dials: eyes and a mouth that are one shape each,
at different settings, so any expression is part way to any other and a
viseme is just a mouth. The dials, the outline geometry and the LED grid are
ported number for number (`Face/`). The face eases between moods (idle,
listening, thinking, speaking, surprised) and blinks and breathes on its own.
A sentence Apple's on-device sentiment score finds glad is said with
protoke's happy eyes; its sad side isn't used, because it scores plain
questions as sad as sympathy.
The mouth follows what the voice says, phoneme by phoneme: espeak's IPA maps
to protoke's mouth shapes, so "my mom" is mouthed m-ah-ee, m-ah-m
(`ccrun --lipsync`). The polyglot voice does not report how long it spent on
each symbol, so those shapes are shared out over the clip: vowels longest, a
pause at punctuation.

## The window

There is nothing to press to talk. It listens as soon as its models are
loaded, for as long as the app is open (on a phone or tablet, while it is on
screen); quitting is how you stop it, and closing the Mac window quits. The
face fills the window, with the last thing each of you said underneath,
dimming once the conversation goes quiet. While it listens, the panel's
unlit cells brighten with your voice; while it loads, it is half asleep. Double-click or double-tap the face to leave only the
face, for a tablet on a stand. Settings has the visor's colour and style (LED
panel or protoke's smooth outlines), the model, echo cancellation, what it
remembers and what it has learned about your pauses. The speech bubble shows
the whole conversation.

## Where the voice comes from

With the spatial voice on (Settings, on by default), the voice is placed half
a metre in front of you and a little below, where a phone or tablet held at
the chest is. On AirPods that track the head (iOS 18, macOS 15 and later) it
stays there when you turn your head, so it sounds like the face talking
rather than a voice inside your ears. On speakers it sounds as before. It is
an `AVAudioEnvironmentNode` between the voice and the mixer of the same
echo-cancelled engine; if that combination won't start on a device, it falls
back to the plain voice and says so. `ccrun --spatial-check` plays through
it silently. It has not yet been heard on AirPods.

## Turning to whoever is talking

The face looks at whoever is speaking: straight at them while it listens,
mostly at them while it answers, only a glance while it thinks; its head
turns a little after its eyes. It knows where they are two ways:

- **The front camera**, if you turn on "Look at whoever is talking" in
  Settings (off by default). Vision finds the faces and their lips about ten
  times a second; the one whose mouth keeps opening and shutting is talking,
  and with nobody talking it looks at the nearest face. Each picture is
  looked at and let go. On a Mac it uses the built-in camera, never a virtual
  one. This works with the echo canceller on, so it works out loud.
- **Stereo microphones**, on an iPhone or iPad with the echo canceller off
  (headphones): the level difference between the front microphones' two
  sides says left or right. The canceller gives one channel, so out loud
  this is the camera's job. A Mac's microphone is one channel.

`ccrun --from-right` speaks from one side of a stereo microphone and then
the other: the face turned to 0.84 across, then to -0.84. Neither the camera
nor the phone's stereo microphones have been tried on a device yet; if the
face turns the wrong way, the picture or the microphone is mirrored, and
`Watcher.mirrored` or `StereoBearing`'s `flipped` puts it right.

## Moving it

The face hangs behind the glass on a spring (`Sway`): move the phone and the
face lags behind and swings back, turn it and the face tilts after it. On a
Mac, which has no motion sensors, dragging the window does the same. Shake it
hard for a second and its eyes go wide and it says so ("Woah there! This
ain't a rodeo. Slow down, please.", and four others in turn), at most once
every 25 seconds, and never over somebody talking. Carrying it about doesn't
count: walking measures about 0.05 on the shake meter, a shake 2 and up, and
it speaks at 1.2. With nothing else going on, its eyes look around: a quick
dart somewhere, a hold of one to five seconds, often back to the middle. It
looks at you while it listens and up to one side while it thinks.

## Memory

Three layers, each pointing at the one below:

- **Conversations**, in full, one JSON line per turn, in
  `~/Library/Application Support/Companion/Conversations/`. Nothing is
  decided here about what matters.
- **Notes**: short sentences about the person, written by the language model
  once a conversation has been quiet for 45 seconds or Talk is stopped. Each
  note names the conversation and turns it came from. Small talk, greetings
  and general questions are left out ("what's the capital of Australia" makes
  no note). A note that says the same thing as an older one replaces it.
- **What it knows about you**: notes about who you are (your name, your work,
  the people and pets in your life) go into every reply. A 4B model asked to
  mark these seldom does, so `Remembering.looksLasting` recognises them too.

Before each reply, what you just said is compared with the notes by meaning,
using bge-small-en-v1.5 on MLX (134 MB, downloaded on first launch; Apple's
built-in sentence embedding ranked too poorly to use). A note must score 0.45
and be within 0.12 of the best match to be brought up, which keeps "work was
exhausting" to the note about night shifts. What comes to mind goes in just
before your words, so the rest of the conversation stays in the model's
cache. When you ask about the past ("do you remember…", "last time…"), the
original turns behind the best note are read back word for word.

You can also ask out loud. "Remember that my sister's birthday is on the
third of March" is noted at once, in your own words; "Forget what I said
about my sister's birthday" finds the closest note and deletes it; it says
which it did (`ccrun --commands`). Both happen only once your turn is
over, so a half-heard sentence changes nothing, and "remember when…" is a
question, not a command.

Writing notes gives way to talking: it stops the moment you speak and picks
up where it left off next time it is quiet. Settings shows everything it
remembers, with a button to forget any of it, or all of it and the logs.

Measured with `ccrun --memory` on Gemma 4 E4B: two earlier conversations,
16 turns, became 7 notes in 9.6 s, three of them recognised as lasting.
Recalling takes 7 to 25 ms. "Do you remember what I told you about my
sister?" brought up the note and the turns behind it, and the reply was "You
mentioned your sister Ana is visiting." "What's the weather like?" brought up
nothing.

## A diary and a calendar

Under the notes are two layers the person never sees (`Journal.swift`). Once
a conversation is written up, the companion writes a few lines about it, a
diary of their days; once a week is over, its entries are summed up in a few
more. Anything said with a date to it goes on a calendar, each entry pointing
at the note and the diary entry it came from. Neither is a real calendar or
anything they set up: it's what a friend who listens would know. `When.swift`
reads the dates as people say them ("tonight", "on Friday", "this weekend",
"the 3rd", "12 March", "in two weeks"), counted from the day they were said;
birthdays and anniversaries come round every year.

So "what have I got this week?" or "what did I do on Tuesday?" is answered
from the calendar and the diary, and something on today (asked before it's
evening) or tomorrow is brought up in passing ("isn't it your mum's birthday
tomorrow?"), at most once every five days (`ccrun --journal`, `--weeks`).

## Catching up, and saying hello

A note about something with a time to it (an interview on Friday, Sam coming
over tonight, guitar lessons just started) becomes worth asking about once
it has happened or had a few days to go somewhere: an evening thing the next
morning, a weekend on the Monday, something under way after a few days
(`CheckIn.swift`). Mid-conversation, from the fourth turn and at a calm
moment, it asks how it went; what they say is written up like anything else,
so the memory moves on with them. Something they told it after the fact
("the interview went well") is not asked about again. Whether a note has a
time to it is read from its words: a 4B model asked to mark that seldom did.

Opening the app after two hours or more, it says hello (`Greeting.swift`): a
few words that fit the time of day and how long it's been, with anything to
catch up on or coming up in the same breath. The first time ever, it says
it's glad to meet them and asks their name. Back within two hours, it says
nothing; they never really left (`ccrun --greet`, `--check-in`).

## Sealed

What it remembers, the conversation logs and the notes, diary and calendar,
is sealed with AES-GCM (`Sealer.swift`) under a key made on first use and kept
in the Keychain on this device only: never synced, never in a backup that
could be restored elsewhere (`Vault.swift`). On an iPhone or iPad the folder
is also unreadable while the device is locked; a Mac relies on the sealing,
and on FileVault. Files written before sealing still open and are sealed the
next time they are written. If the Keychain won't give the key it says so
and runs unsealed; it never makes a new key over an old one, which would lock
away everything sealed with it (`ccrun --seal-check`).

## Its person, and guests

It learns what its person sounds like (`Voices.swift`, `Voiceprint.swift`):
the first voice it hears for long enough, kept as the average of CAM++
voiceprints (through FluidAudio) of what they have said, steadier the more it
hears. Anyone else is a guest, met kindly, told nothing it knows about its
person, and kept out of its memory: each sees only their own side of the
conversation. Told everything, it once told a guest about its person's nerves
over a visit mentioned minutes before. Measured with `ccrun --speakers` on
thirteen system voices, eight clips each: against an averaged print at 0.80,
every clip over 1.5 s went to the right voice and none to a wrong one; short
turns ("yeah", "hm") decide nothing.

Out of a conversation, only its person starts one: left on all night, it had
answered a TV and the street (`ccrun --overnight`). In one, a guest joins in
if they are about as near as its person. "Know my voice" in Settings is on by
default; the model is fetched the first time, and without it everyone is its
person, as before.

## When it's serious

If what they say sounds like they might be thinking about suicide or hurting
themselves, `Crisis.swift` hears it, and the reply follows what crisis lines
train their volunteers to do rather than what makes a product feel covered:
stay, listen, take it seriously, ask directly (asking doesn't put the idea
there), and don't judge, argue, minimise, joke or tell them what to do. Clear
words get all of that; words that might only mean a bad day ("I can't cope
anymore") get a gentle "are you okay? Like, really?". In the first reply it
mentions, once, the national line where they are (24 countries' lines,
checked 2026-10-21 against Wikipedia's list and findahelpline.com, with the
emergency number), as something for them and not a way of ending the
conversation, and keeps talking for as long as they want. If two replies go
by and the model still hasn't said it, the companion says it itself. Numbers
are read digit by digit ("1 1 3"). Where it can't be sure of a line, it points
to findahelpline.com. The next day it asks how they are doing, not how it went.

## Who it is

Three personalities, chosen in Settings (`Personality.swift`): **playful**
(jokes, wordplay, plays along; the default), **gentle** (warm and calm, a soft
smile now and then) and **deadpan** (dry wit, delivered straight). Playful
and deadpan drop the act when they are having a hard time. Small models follow examples far
better than descriptions, so each comes with a few lines in its voice: told
only the rules, it was correct and flat (`ccrun --personality`).

## Other languages

Asked "how do you say breakfast in Romanian?", "what does köszönöm mean?" or
"and in Polish?", it looks the word up before the model answers, in an
offline dictionary built from English Wiktionary (`Dictionary.swift`,
`scripts/build-dictionary.sh`, about 130 MB): translations between English
and fifteen languages, and what English words mean. None of the three
models knew "micul dejun"; told nothing is there, it says it doesn't know
rather than guess.

A sentence can mix languages (`Languages.swift`): a quoted word in the
language they named, or one Apple's detector is sure of, and a whole
sentence in another language, each spoken in its own language by the
polyglot voice and joined, so "micul dejun" is said as Romanian inside an
English sentence. English is that same voice. A price in an English part is
read as it is said ("$4.99" as "4 dollars 99"); the sentence kept in the
conversation stays as it was written. The eight languages the voice was
trained on sound like it, and the rest go through plain espeak-ng, accent
and all.

## The bundle ID

The Mac app and the iPhone and iPad app are `com.snepssen.companion`
(`build.sh`'s Info.plist, `iOS/project.yml`). The Mac app used to be
`local.companion-core.companion`. The Keychain item that holds the memory
key was already stored under the service `com.snepssen.companion`, with no
access group (`Vault.swift`). That service is unchanged. A new name, or an
access group added now, would leave the key behind and everything sealed
with it unreadable.

What it remembers is not named with the bundle ID. Conversations, notes,
the diary and downloaded models stay in
`~/Library/Application Support/Companion` either way. The Mac app is not
sandboxed, so there is no `~/Library/Containers/<bundle id>` to move, and
nothing is logged under the bundle ID. A URL cache may sit in
`~/Library/Caches/<bundle id>`; it is not moved, because a model is only
kept once its files are in Application Support and the right size.

Two Mac locations are named with the bundle ID. The first launch copies
them across before preferences or the saved window are read
(`BundleMigration`):

- `~/Library/Preferences/local.companion-core.companion.plist`, which is
  Settings: the model, the visor, echo cancellation, personality, and the rest
- `~/Library/Saved Application State/local.companion-core.companion.savedState`,
  the window

The copy is checked byte for byte, including every file in the saved window,
and only then is the old one removed. If the new location already exists and
is not the same, both are left as they are. Once a move has finished, the
next launch finds the old paths gone. A copy that does not check out is
thrown away and the original kept, so a launch that stops halfway tries
again next time.

## Shared models

A macOS or Linux Release build looks for language models and the embedder
only in the shared folder. It does not download, move, or delete them. If a
model is missing, the message names the path it expected. Debug builds, and
the iPhone and iPad app in every configuration, are unchanged:
`~/Library/Application Support/Companion/Models/<id>/`, then this checkout's
`models/<id>/`, including a symlink left by `scripts/fetch-models.sh`, and
they can still download. The iOS app group is not declared here.

| | |
|---|---|
| macOS (the app is not sandboxed) | `~/Library/Application Support/snepssen/models/<id>/` |
| Linux | `$XDG_DATA_HOME/snepssen/models/<id>/`, or `~/.local/share/snepssen/models/<id>/` when that variable is unset |

The `<id>` directories this app expects:

- `qwen3-8b-4bit`
- `gemma-4-e4b-it-4bit`
- `qwen3-4b-instruct-2507-4bit`
- `gemma-4-e2b-it-4bit`
- `bge-small-en-v1.5`

The polyglot voice and espeak-ng data stay inside the app. Silero VAD stays a bundled file. Speech recognition is Parakeet Ultra through FluidAudio (`AsrModels.download`), and voiceprints are CAM++ through FluidAudio (`DiarizerModels.downloadIfNeeded`). Both use FluidAudio's own cache, not this folder.

## Build

    scripts/fetch-models.sh        # Silero VAD, and links to shared models when they're next door
    ./build.sh                     # checks, then Companion.app and ccrun

The package resolves from this checkout, plus voice-core by URL. Nothing else
has to sit beside it. The voice `build.sh` and `iOS/build-ios.sh` bundle is
the polyglot snepssen, English included (`scripts/polyglot-voice.sh`):
voice-polyglot's newest export where it is beside this checkout, else its
latest GitHub Release, checked against the release's SHA256SUMS and fetched
again when a newer one is out. No separate English voice is fetched. The
first build also fetches English Wiktionary's extract (523 MB) and cuts the
dictionary from it. The language model is not bundled. A Debug build downloads
it from Settings into `~/Library/Application Support/Companion/Models`, or
finds it in this checkout's `models/`. Where interpreter-forge's `models/`
sits beside this checkout — or `WORKSHOP_ROOT` names the folder that holds
both — `scripts/fetch-models.sh` symlinks each model that Debug store doesn't
already have, so the gigabytes stay where they are. A Debug launch finds those
links. A model already in that store is left as it is. A macOS Release
build (`./build.sh`) does not download, move, or delete models: it reads only
the shared folder in [Shared models](#shared-models). The iOS build keeps the
Debug lookup. `swift run cccheck` holds the model-free parts to their cases
in seconds.

The iPhone and iPad app is the same engine and views (`iOS/`, generated
with xcodegen as interpreter-forge's is):

    iOS/build-ios.sh               # build, install on a connected iPhone or iPad
    iOS/build-ios.sh --no-install

To put it on every iPhone and iPad you have paired at once (or only those
named, by part of a name or model, or a UDID):

    iOS/install-devices.sh                 # build once, install and launch on each
    iOS/install-devices.sh --both          # interpreter-forge's app too, from beside this checkout
    iOS/install-devices.sh --list          # which devices, without building

It builds with `build-ios.sh --no-install` and then installs that app on
each device with `devicectl`, ending with what went on where and what
failed. Signed with a free (personal) team, an install stops opening seven
days after it was built, so run it again within the week; it prints the
date. Installing over the old app keeps what it remembers and its models.

It offers the language models that fit beside recognition, the embedder and
the voice: Qwen3 4B or Gemma 4 E2B on an 8 GB iPhone (with the increased
memory entitlement), Gemma 4 E4B from 12 GB. It listens while it is on screen;
leaving the app stops it and writes the conversation up, and coming back
starts it again, and the screen stays on while it is in front. MLX needs a
real GPU, so there is no Simulator build. It has run on an iPhone 17 and an
iPad with M4.

`ccrun` plays recorded speech through the live loop in real time, with the
reply's echo leaking back into the "microphone" at a chosen level:

    .build/xcode/Build/Products/Release/ccrun              # a conversation with an interruption
    .build/xcode/Build/Products/Release/ccrun --echo 0.3   # with far more echo
    .build/xcode/Build/Products/Release/ccrun --shake      # with the phone shaken between turns
    .build/xcode/Build/Products/Release/ccrun --faces /tmp/faces
    .build/xcode/Build/Products/Release/ccrun --memory     # notes written, then recalled
    .build/xcode/Build/Products/Release/ccrun --icon Resources/icon-1024.png   # the icon, from the face

Measured on this Mac with Gemma 4 E4B, 2026-10-20 (more under Measured):
the reply starts **0.9 to 1.8 s** after you stop talking. With the echo leaking back at 0.05
(roughly what voice processing leaves), echo measured 1.0× its learned level
and an interruption 11× to 18×, so none was stopped falsely and the
interruption was caught on its first check. At 0.3 (barely cancelled), 17
echo fragments were let go and the interruption was caught on its third check.

## Measured

On an M1 with 16 GB, 2026-10-20, with `ccrun`. Footprint is what iOS holds
against an app, and on Apple silicon it includes what MLX keeps on the GPU.
It is measured with recognition, the embedder, the voice and memory all
loaded.

| model | footprint | at peak | from the end of your speech to the reply's first sound |
|---|---|---|---|
| Qwen3 4B (8 GB iPhones) | 3.0 GB | 3.0 GB | 0.89–1.72 s |
| Gemma 4 E2B | 3.2 GB | 4.2 GB | 0.81–1.05 s |
| Gemma 4 E4B (Mac, 12 GB iPhones) | 4.8 GB | 5.8 GB | 1.07–1.76 s |

Most of that time is the learned wait itself: a reply is drafted halfway
into your pause, transcribed in 0.14 s, its first words written 0.3 s
later and its first sentence voiced by about 0.8 s, so it is ready when the
wait ends. The rest is a long first sentence.

The model is shown the last 16 to 23 turns; the window moves 8 turns at a
time rather than one, and after each reply the model reads the next prompt
in while you talk. Sliding a turn at a time made every reply past the
sixteenth turn re-read about 230 tokens, and its first words came 1.86 s
after you finished instead of 0.31 s (`ccrun --long`). With both changes,
every turn of a 22-turn conversation started in 0.31 to 0.37 s.

## From interpreter-forge

`SileroVAD`, `SampleBuffer`, the model store and `PromptCache` come from
[speech-core](https://github.com/snepssen/speech-core), which interpreter-forge
uses too. `Voice` is still interpreter-forge's, copied with small changes.

## Next

- Measuring memory and lag on the iPhone and iPad as on the Mac: it runs on
  an iPhone 17 and an iPad with M4, but the numbers above are the Mac's.
- Desktop beyond the Mac, and Android: llama.cpp and sherpa-onnx, as
  interpreter-forge's Android port runs Silero, Parakeet and Piper already.

## Licence

GPL-3.0-or-later. The text is `LICENSE`.

The built app links voice-core, which includes espeak-ng (GPL-3.0-or-later,
commit `724808c5a83f9ef95fdd0db886ba7ba537ff224a`) and the espeak-ng data
that goes with it. That is the phonemizer the polyglot voice was trained
through, and `build.sh` copies the data into the app. Velvet's own code is
MIT where it can be. Anything involving Piper is GPL, and this app speaks
through Piper, so it is GPL-3.0-or-later.

`THIRD_PARTY_NOTICES.md` lists what else the app ships or links. The build
copies that file and `LICENSE` into `Companion.app/Contents/Resources`.
