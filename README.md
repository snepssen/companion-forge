# companion-core

A companion you talk with out loud, with a protogen visor for a face. It
listens, waits until you have finished rather than until a timer runs out,
answers in a voice, and learns how you pause. Everything runs locally.

    mic ─▶ echo canceller ─▶ VAD ─▶ turn taker ─▶ ASR ─▶ language model ─▶ voice ─▶ speakers
                                        ▲                                     │
                                        └──── learned pauses, echo level ◀────┘

| stage | model |
|---|---|
| VAD | Silero VAD v5 (ONNX) |
| ASR | Parakeet Ultra through FluidAudio, on the Neural Engine |
| language model | Gemma 4 E4B, 4-bit MLX (Qwen3 4B or Gemma 4 E2B for 8 GB phones) |
| voice | voice-forge's English snepssen, on voice-core's Piper |
| face | protoke's visor, ported to Swift and drawn as an LED panel |
| memory | bge-small-en-v1.5 on MLX, over notes the language model writes |

## Turns, not timers

translate-core cut speech on pauses, punctuation and a fixed 5 s ceiling. A
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

The microphone and the voice share one `AVAudioEngine` with Apple's voice
processing on, which cancels the voice's echo. It can only subtract what it
plays itself, so nothing is played any other way. Some echo always gets
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
The mouth follows the words the voice is saying, timed by their spelling
across each clip.

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

Writing notes gives way to talking: it stops the moment you speak and picks
up where it left off next time it is quiet. Settings shows everything it
remembers, with a button to forget any of it, or all of it and the logs.

Measured with `ccrun --memory` on Gemma 4 E4B: two earlier conversations,
16 turns, became 7 notes in 9.6 s, three of them recognised as lasting.
Recalling takes 7 to 25 ms. "Do you remember what I told you about my
sister?" brought up the note and the turns behind it, and the reply was "You
mentioned your sister Ana is visiting." "What's the weather like?" brought up
nothing.

## Build

    scripts/fetch-models.sh        # Silero VAD, once
    ./build.sh                     # checks, then Companion.app and ccrun

voice-forge must be beside this checkout for the voice. The language model is
downloaded from the app's settings; one already in translate-core's `models/`
is used as it is. `swift run cccheck` holds the model-free parts to their
cases in seconds.

The iPhone and iPad app is the same engine and views (`iOS/`, generated
with xcodegen as translate-core's is):

    iOS/build-ios.sh               # build, install on a connected iPhone or iPad
    iOS/build-ios.sh --no-install

It offers the language models that fit beside recognition, the embedder and
the voice: Qwen3 4B or Gemma 4 E2B on an 8 GB iPhone (with the increased
memory entitlement), Gemma 4 E4B from 12 GB. It listens while it is on screen;
leaving the app stops it and writes the conversation up, and coming back
starts it again. MLX needs a
real GPU, so there is no Simulator build. It compiles and links for devices
(2026-10-20) but has not been signed or run on one yet.

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

## From translate-core

`SileroVAD`, `Voice`, `SampleBuffer`, the model store and `PromptCache` are
translate-core's, copied with small changes. Like voice-core, they belong in
one shared package once both apps settle on them.

## Next

- Running the iPhone and iPad app on a device: signing, then measuring
  memory and lag on an 8 GB iPhone.
- Desktop beyond the Mac, and Android: llama.cpp and sherpa-onnx, as
  translate-core's Android port runs Silero, Parakeet and Piper already.
