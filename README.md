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
The mouth follows the words the voice is saying, timed by their spelling
across each clip.

## Memory

Every conversation is written in full, one JSON line per turn, to
`~/Library/Application Support/Companion/Conversations/`. That is the bottom
of the memory. Summaries that point back into these logs come next.

## Build

    scripts/fetch-models.sh        # Silero VAD, once
    ./build.sh                     # checks, then Companion.app and ccrun

voice-forge must be beside this checkout for the voice. The language model is
downloaded from the app's settings; one already in translate-core's `models/`
is used as it is. `swift run cccheck` holds the model-free parts to their
cases in seconds.

`ccrun` plays recorded speech through the live loop in real time, with the
reply's echo leaking back into the "microphone" at a chosen level:

    .build/xcode/Build/Products/Release/ccrun              # a conversation with an interruption
    .build/xcode/Build/Products/Release/ccrun --echo 0.3   # with far more echo
    .build/xcode/Build/Products/Release/ccrun --faces /tmp/faces

Measured on this Mac with Gemma 4 E4B, 2026-10-20: the reply starts
**0.9 to 1.5 s** after you stop talking. With the echo leaking back at 0.05
(roughly what voice processing leaves), echo measured 1.0× its learned level
and an interruption 11× to 18×, so none was stopped falsely and the
interruption was caught on its first check. At 0.3 (barely cancelled), 17
echo fragments were let go and the interruption was caught on its third check.

## From translate-core

`SileroVAD`, `Voice`, `SampleBuffer`, the model store and `PromptCache` are
translate-core's, copied with small changes. Like voice-core, they belong in
one shared package once both apps settle on them.

## Next

- Memory: summaries of each conversation, with pointers into the logs,
  retrieved by meaning before each reply.
- The iPad and iPhone apps: the same engine and views, as translate-core's are.
- Desktop beyond the Mac, and Android: llama.cpp and sherpa-onnx, as
  translate-core's Android port runs Silero, Parakeet and Piper already.
