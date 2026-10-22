"""companion-forge's project page, as a catalogue.

Everything particular to this project lives here; `build.py` supplies the
chrome every page in the family shares. Adding a section is a dict in
`sections` — the jump navigation, which is derived from these, picks it up on
its own.

Prose is authored HTML. The figures are the README's, measured on an M1 Mac
with 16 GB on 2026-10-20 unless a line says otherwise, and checked against
the source in this checkout. Nothing here is a screenshot: the app has no
page images yet, and a picture of a window that was not taken would be the
wrong kind of precise.
"""

FONTS = "fonts.css"

PIPELINE = (
    "mic → echo canceller → VAD → turn taker → ASR → language model → voice → speakers\n"
    "\n"
    "VAD              Silero VAD v5, ONNX\n"
    "ASR              Parakeet Ultra through FluidAudio, on the Neural Engine\n"
    "language model   Gemma 4 E4B, 4-bit MLX\n"
    "                 Qwen3 4B or Gemma 4 E2B where the phone has 8 GB\n"
    "voice            the polyglot snepssen, on voice-core's Piper\n"
    "                 English included, the same voice\n"
    "face             protoke's visor, ported to Swift, drawn as an LED panel\n"
    "memory           bge-small-en-v1.5 on MLX, over notes the model writes\n"
    "whose voice      CAM++ voiceprints through FluidAudio\n"
    "dictionary       English Wiktionary, cut down to SQLite"
)

MODELS = """  <table>
    <thead><tr><th>Model</th><th>Footprint</th><th>At peak</th><th>From the end of your speech to the first sound</th></tr></thead>
    <tbody>
      <tr><td>Qwen3 4B, for 8 GB iPhones</td><td>3.0 GB</td><td>3.0 GB</td><td>0.89–1.72 s</td></tr>
      <tr><td>Gemma 4 E2B</td><td>3.2 GB</td><td>4.2 GB</td><td>0.81–1.05 s</td></tr>
      <tr><td>Gemma 4 E4B, Mac and 12 GB iPhones</td><td>4.8 GB</td><td>5.8 GB</td><td>1.07–1.76 s</td></tr>
    </tbody>
  </table>"""

PAGE = {
    "meta": {
        "slug": "companion-forge",
        "name": "companion-forge",
        "title": "companion-forge",
        "badge": "Mac · iPhone · iPad",
        "fonts": FONTS,
        "description": (
            "A companion you talk with out loud, on a Mac, iPhone or iPad. "
            "It listens until you have finished, answers in a voice, and "
            "keeps what it remembers encrypted on the device."),
        "og_description": (
            "A protogen LED-visor face, a voice, and a memory sealed on the "
            "device. It has run on an M1 Mac, an iPhone 17 and an iPad with M4."),
        "subhead": (
            "A companion you talk with out loud, with a protogen visor for a "
            "face. It listens, waits until you have finished rather than until "
            "a timer runs out, answers in a voice, and learns how you pause. "
            "It is one person's companion: it knows their voice, keeps a diary "
            "of their days, and catches up on what they told it. Everything "
            "runs locally, and what it remembers is encrypted on the device."),
        "stats": [
            "<b>M1</b> Mac · iPhone 17 · iPad M4",
            "<b>0.9–1.8 s</b> to the first sound, Gemma 4 E4B on the M1",
            "<b>Sealed</b> on this device. The key is never synced",
        ],
    },

    "header_blocks": [
        {
            "kind": "report",
            "text": PIPELINE,
            "caption": (
                "One chain, on the machine in front of you. The voice the "
                "build bundles is voice-polyglot's snepssen, English included, "
                "on voice-core's Piper."),
        },
    ],

    "sections": [
        {
            "id": "turns",
            "jump": "Turns",
            "eyebrow": "Turns, not timers",
            "heading": "It waits for a silence longer than yours",
            "blocks": [
                {"kind": "prose", "class": "lede", "text": [
                    "interpreter-forge cuts speech on pauses, punctuation and a "
                    "fixed 5 second ceiling. A conversation can do better. "
                    "Every time you go quiet and then carry on, that gap was "
                    "a pause inside your turn, and the companion keeps the "
                    "last 200 of them.",
                ]},
                {"kind": "prose", "text": [
                    "It waits for a silence longer than nearly all of those: "
                    "the 90th percentile, shortened after a question, "
                    "lengthened when the words so far trail off on "
                    "&ldquo;and&rdquo; or &ldquo;um&rdquo;, and pushed out "
                    "further each time a reply cut you off. It starts at "
                    "0.9 seconds and moves from there. What it has learned "
                    "is shown in Settings.",
                    "The reply is drafted while you are still pausing, as "
                    "soon as the pause is long enough to be worth a guess: "
                    "transcribed, written and turned into speech, but held. "
                    "If you carry on, it is thrown away. If the pause runs "
                    "to the learned wait, what is ready plays at once. Most "
                    "of the model's time is spent inside the silence you "
                    "were leaving anyway.",
                ]},
            ],
        },
        {
            "id": "aloud",
            "jump": "Out loud",
            "eyebrow": "Speaking out loud",
            "heading": "The microphone and the voice share one engine",
            "blocks": [
                {"kind": "prose", "text": [
                    "On an iPhone or iPad, Apple's voice processing is on, "
                    "which cancels the voice's echo. It can only subtract "
                    "what it plays itself, so nothing is played any other "
                    "way. On a Mac it is not used. On the M1, on 2026-10-20, "
                    "its microphone side delivered nothing at all, whatever "
                    "devices it was pointed at, so the microphone is taken "
                    "as it is. The checks below keep the voice out, and the "
                    "first words of a turn are also checked against the end "
                    "of the last reply.",
                    "Some echo always gets through, so talking over a reply "
                    "has to pass two checks. It has to sound like confident "
                    "speech for 0.35 seconds. Then it is compared two ways: "
                    "by its words, because the reply's own voice coming back "
                    "says the words being said, and by its level. The "
                    "companion knows what it played, learns how loud that "
                    "comes back in this room, and a person talking over it "
                    "is louder than twice that. Either check can call it "
                    "echo. Only something that passes both stops the reply, "
                    "and then only the part actually said is kept.",
                ]},
                {"kind": "heading", "text": "Where the voice sits"},
                {"kind": "prose", "text": [
                    "With the spatial voice on, which it is in Settings by "
                    "default, the voice is placed half a metre in front of "
                    "you and a little below, where a phone or tablet held at "
                    "the chest is. On AirPods that track the head, on iOS 18 "
                    "and macOS 15 and later, it stays there when you turn "
                    "your head. On speakers it sounds as before. If that "
                    "path will not start on a device, it falls back to the "
                    "plain voice and says so. It has not yet been heard on "
                    "AirPods.",
                ]},
            ],
        },
        {
            "id": "face",
            "jump": "The face",
            "eyebrow": "The face",
            "heading": "Protoke's visor, drawn as an LED panel",
            "blocks": [
                {"kind": "prose", "class": "lede", "text": [
                    "Protoke's face is continuous dials: eyes and a mouth "
                    "that are one shape each, at different settings, so any "
                    "expression is part way to any other and a viseme is "
                    "just a mouth. The dials, the outline geometry and the "
                    "LED grid are ported number for number.",
                ]},
                {"kind": "prose", "text": [
                    "The face eases between idle, listening, thinking, "
                    "speaking and surprised, and blinks and breathes on its "
                    "own. A sentence Apple's on-device sentiment score finds "
                    "glad is said with Protoke's happy eyes. The sad side "
                    "is not used: the score treats a plain question as sadly "
                    "as sympathy.",
                    "The mouth follows what the voice says, phoneme by "
                    "phoneme. The voice graph reports how long it spent on "
                    "each one, and espeak's IPA maps to Protoke's mouth "
                    "shapes, so &ldquo;my mom&rdquo; is mouthed "
                    "m-ah-ee, m-ah-m. The polyglot voice, whose layout "
                    "differs, falls back to timing words by their spelling.",
                ]},
                {"kind": "heading", "text": "Nothing to press"},
                {"kind": "prose", "text": [
                    "It listens as soon as its models are loaded, for as "
                    "long as the app is open. On a phone or tablet, that is "
                    "while it is on screen. Quitting is how you stop it, and "
                    "closing the Mac window quits. The face fills the "
                    "window, with the last thing each of you said "
                    "underneath, dimming once the conversation goes quiet. "
                    "While it listens, the panel's unlit cells brighten "
                    "with your voice. While it loads, it is half asleep. "
                    "Double-click or double-tap the face to leave only the "
                    "face, for a tablet on a stand.",
                    "Settings has the visor's colour and style, an LED panel "
                    "or Protoke's smooth outlines, the model, echo "
                    "cancellation, what it remembers and what it has learned "
                    "about your pauses. The speech bubble shows the whole "
                    "conversation.",
                ]},
            ],
        },
        {
            "id": "room",
            "jump": "The room",
            "eyebrow": "In the room",
            "heading": "It looks at whoever is speaking, and lags when you move it",
            "blocks": [
                {"kind": "prose", "text": [
                    "The face looks straight at them while it listens, "
                    "mostly at them while it answers, and only glances while "
                    "it thinks. Its head turns a little after its eyes. The "
                    "front camera does this if you turn on &ldquo;Look at "
                    "whoever is talking&rdquo; in Settings, which is off by "
                    "default. Vision finds the faces and their lips about "
                    "ten times a second. The one whose mouth keeps opening "
                    "and shutting is talking, and with nobody talking it "
                    "looks at the nearest face. Each picture is looked at "
                    "and let go. On a Mac it uses the built-in camera, never "
                    "a virtual one. This works with the echo canceller on.",
                    "On an iPhone or iPad with the echo canceller off, and "
                    "headphones, the level difference between the front "
                    "microphones' two sides says left or right. The "
                    "canceller gives one channel, so out loud this is the "
                    "camera's job. A Mac's microphone is one channel. "
                    "<span class=\"mono\">ccrun --from-right</span> speaks "
                    "from one side of a stereo microphone and then the "
                    "other: the face turned to 0.84 across, then to "
                    "&minus;0.84. Neither the camera nor the phone's stereo "
                    "microphones have been tried on a device yet. If the "
                    "face turns the wrong way, the picture or the microphone "
                    "is mirrored.",
                ]},
                {"kind": "prose", "text": [
                    "The face hangs behind the glass on a spring. Move the "
                    "phone and it lags and swings back; turn it and the face "
                    "tilts after it. On a Mac, which has no motion sensors, "
                    "dragging the window does the same. Shake it hard for a "
                    "second and its eyes go wide and it says so "
                    "(&ldquo;Woah there! This ain't a rodeo. Slow down, "
                    "please.&rdquo;, and four others in turn), at most once "
                    "every 25 seconds, and never over somebody talking. "
                    "Walking measures about 0.05 on the shake meter, a shake "
                    "2 and up, and it speaks at 1.2. With nothing else going "
                    "on, its eyes look around: a quick dart, a hold of one "
                    "to five seconds, often back to the middle. It looks at "
                    "you while it listens and up to one side while it thinks.",
                ]},
            ],
        },
        {
            "id": "memory",
            "jump": "Memory",
            "eyebrow": "Memory",
            "heading": "Three layers, then a diary it keeps for itself",
            "blocks": [
                {"kind": "prose", "class": "lede", "text": [
                    "Conversations are kept in full, one JSON line per turn, "
                    "and nothing is decided there about what matters. Notes "
                    "are short sentences about the person, written by the "
                    "language model once a conversation has been quiet for "
                    "45 seconds, or when Talk is stopped. Each note names "
                    "the conversation and the turns it came from. Small "
                    "talk, greetings and general questions are left out. A "
                    "note that says the same thing as an older one replaces "
                    "it.",
                ]},
                {"kind": "prose", "text": [
                    "Notes about who you are, your name, your work, the "
                    "people and pets in your life, go into every reply. A "
                    "4B model asked to mark these seldom does, so the "
                    "companion recognises them too. Before each reply, what "
                    "you just said is compared with the notes by meaning, "
                    "using bge-small-en-v1.5 on MLX, 134 MB, downloaded on "
                    "first launch. Apple's built-in sentence embedding "
                    "ranked too poorly to use. A note must score 0.45 and "
                    "be within 0.12 of the best match to be brought up. What "
                    "comes to mind goes in just before your words, so the "
                    "rest of the conversation stays in the model's cache. "
                    "When you ask about the past, the original turns behind "
                    "the best note are read back word for word.",
                    "You can also ask out loud. &ldquo;Remember that my "
                    "sister's birthday is on the third of March&rdquo; is "
                    "noted at once, in your own words. &ldquo;Forget what I "
                    "said about my sister's birthday&rdquo; finds the "
                    "closest note and deletes it, and it says which it did. "
                    "Both happen only once your turn is over, so a "
                    "half-heard sentence changes nothing, and &ldquo;remember "
                    "when&rdquo; is a question, not a command. Writing notes "
                    "gives way to talking: it stops the moment you speak and "
                    "picks up where it left off. Settings shows everything "
                    "it remembers, with a button to forget any of it, or "
                    "all of it and the logs.",
                ]},
                {"kind": "report", "text": (
                    "ccrun --memory   Gemma 4 E4B\n"
                    "  two earlier conversations, 16 turns\n"
                    "  7 notes in 9.6 s, three of them lasting\n"
                    "  recalling a note: 7 to 25 ms\n"
                    "\n"
                    "  “Do you remember what I told you about my sister?”\n"
                    "  brought up the note and the turns behind it\n"
                    "  “You mentioned your sister Ana is visiting.”\n"
                    "\n"
                    "  “What's the weather like?”\n"
                    "  brought up nothing"
                ), "caption": (
                    "The sister, and the weather, are that run. "
                    "&ldquo;Work was exhausting&rdquo; stays with the note "
                    "about night shifts, which is what the 0.45 and 0.12 "
                    "cut is for.")},
                {"kind": "heading", "text": "A diary, a calendar, and catching up"},
                {"kind": "prose", "text": [
                    "Under the notes are two layers the person never sets "
                    "up. Once a conversation is written up, the companion "
                    "writes a few lines about it. Once a week is over, those "
                    "entries are summed up in a few more. Anything said with "
                    "a date on it goes on a calendar, each entry pointing at "
                    "the note and the diary line it came from. Dates are "
                    "read as people say them: tonight, on Friday, this "
                    "weekend, the 3rd, 12 March, in two weeks, counted from "
                    "the day they were said. Birthdays and anniversaries "
                    "come round every year. Something on today, asked before "
                    "evening, or tomorrow, is brought up in passing, at most "
                    "once every five days.",
                    "A note about something with a time on it becomes worth "
                    "asking about once it has happened or had a few days to "
                    "go somewhere: an evening thing the next morning, a "
                    "weekend on the Monday, something under way after a few "
                    "days. From the fourth turn, at a calm moment, it asks "
                    "how it went. What they say is written up like anything "
                    "else. Something they told it after the fact is not "
                    "asked about again. Opening the app after two hours or "
                    "more, it says hello: a few words that fit the time of "
                    "day and how long it has been, with anything to catch up "
                    "on in the same breath. The first time, it says it is "
                    "glad to meet them and asks their name. Back within two "
                    "hours, it says nothing.",
                ]},
                {"kind": "heading", "text": "Sealed on this device"},
                {"kind": "prose", "text": [
                    "What it remembers, the logs and the notes, the diary "
                    "and the calendar, is sealed with AES-GCM under a key "
                    "made on first use and kept in the Keychain on this "
                    "device only. The key is never synced, and never put in "
                    "a backup that could be restored elsewhere. On an iPhone "
                    "or iPad the folder is also unreadable while the device "
                    "is locked. A Mac relies on the sealing, and on "
                    "FileVault. Files written before sealing still open, and "
                    "are sealed the next time they are written. If the "
                    "Keychain will not give the key, it says so and runs "
                    "unsealed. It never makes a new key over an old one, "
                    "which would lock away everything sealed with it.",
                ]},
            ],
        },
        {
            "id": "person",
            "jump": "Whose voice",
            "eyebrow": "Its person, and guests",
            "heading": "The first voice it hears for long enough is its person",
            "blocks": [
                {"kind": "prose", "text": [
                    "It keeps that voice as the average of CAM++ voiceprints, "
                    "through FluidAudio, of what they have said, steadier "
                    "the more it hears. Anyone else is a guest, met kindly, "
                    "told nothing it knows about its person, and kept out of "
                    "its memory. Each sees only their own side of the "
                    "conversation. Told everything, it once told a guest "
                    "about its person's nerves over a visit mentioned "
                    "minutes before.",
                ]},
                {"kind": "report", "text": (
                    "ccrun --speakers   thirteen system voices, eight clips each\n"
                    "  against an averaged print at 0.80\n"
                    "  every clip over 1.5 s went to the right voice\n"
                    "  none went to a wrong one\n"
                    "  short turns (“yeah”, “hm”) decide nothing"
                ), "caption": (
                    "Out of a conversation, only its person starts one. Left "
                    "on all night, it had answered a television and the "
                    "street. In a conversation, a guest joins in if they are "
                    "about as near as its person. &ldquo;Know my voice&rdquo; "
                    "is on by default. The model is fetched the first time, "
                    "and without it everyone is its person, as before.")},
            ],
        },
        {
            "id": "serious",
            "jump": "When it's serious",
            "eyebrow": "When it's serious",
            "heading": "It stays, and it says so plainly",
            "blocks": [
                {"kind": "prose", "text": [
                    "If what they say sounds like they might be thinking "
                    "about suicide or hurting themselves, the reply follows "
                    "what crisis lines train their volunteers to do rather "
                    "than what makes a product feel covered: stay, listen, "
                    "take it seriously, ask directly, and don't judge, "
                    "argue, minimise, joke or tell them what to do. Asking "
                    "does not put the idea there. Clear words get all of "
                    "that. Words that might only mean a bad day "
                    "(&ldquo;I can't cope anymore&rdquo;) get a gentle "
                    "&ldquo;are you okay? Like, really?&rdquo;.",
                    "In the first reply it mentions, once, the national line "
                    "where they are. Twenty-four countries' lines, checked "
                    "on 2026-10-21 against Wikipedia's list and "
                    "findahelpline.com, with the emergency number, as "
                    "something for them and not a way of ending the "
                    "conversation. It keeps talking for as long as they "
                    "want. If two replies go by and the model still has not "
                    "said it, the companion says it itself. Numbers are read "
                    "digit by digit. Where it cannot be sure of a line, it "
                    "points to findahelpline.com. The next day it asks how "
                    "they are doing, not how it went.",
                ]},
            ],
        },
        {
            "id": "languages",
            "jump": "Languages",
            "eyebrow": "Other languages",
            "heading": "It looks the word up before it answers",
            "blocks": [
                {"kind": "prose", "text": [
                    "Asked how to say breakfast in Romanian, what "
                    "&ldquo;köszönöm&rdquo; means, or &ldquo;and in "
                    "Polish?&rdquo;, it looks the word up before the model "
                    "answers, in an offline dictionary built from English "
                    "Wiktionary, about 130 MB: translations between English "
                    "and fifteen languages, and what English words mean. "
                    "None of the three models knew &ldquo;micul dejun&rdquo;. "
                    "Told nothing is there, it says it does not know rather "
                    "than guess.",
                    "A sentence can mix languages. A quoted word in the "
                    "language they named, or one Apple's detector is sure "
                    "of, and a whole sentence in another language, are each "
                    "spoken in their own language by the polyglot voice and "
                    "joined. English is that same voice. The eight languages "
                    "the voice was trained on sound like it, and the rest go "
                    "through plain espeak-ng, accent and all.",
                ]},
                {"kind": "heading", "text": "Who it is"},
                {"kind": "prose", "text": [
                    "Three personalities, chosen in Settings. Playful is the "
                    "default: jokes, wordplay, plays along. Gentle is warm "
                    "and calm. Deadpan is dry wit, delivered straight. "
                    "Playful and deadpan drop the act when someone is having "
                    "a hard time. Small models follow examples far better "
                    "than descriptions, so each comes with a few lines in "
                    "its voice. Told only the rules, it was correct and flat.",
                ]},
            ],
        },
        {
            "id": "measured",
            "jump": "Measured",
            "eyebrow": "Measured",
            "heading": "On an M1 with 16 GB, recognition and memory loaded",
            "blocks": [
                {"kind": "prose", "class": "lede", "text": [
                    "Footprint is what iOS holds against an app, and on "
                    "Apple silicon it includes what MLX keeps on the GPU. "
                    "The run is <span class=\"mono\">ccrun</span> on "
                    "2026-10-20, with recognition, the embedder, the voice "
                    "and memory all loaded. The same day, with Gemma 4 E4B, "
                    "the reply started 0.9 to 1.8 seconds after you stop "
                    "talking.",
                ]},
                {"kind": "raw", "html": MODELS},
                {"kind": "prose", "class": "caption", "text": [
                    "Most of that time is the learned wait itself. A reply "
                    "is drafted halfway into the pause, transcribed in 0.14 "
                    "seconds, its first words written 0.3 seconds later and "
                    "its first sentence voiced by about 0.8 seconds, so it "
                    "is ready when the wait ends. The rest is a long first "
                    "sentence.",
                ]},
                {"kind": "prose", "text": [
                    "With the reply's echo leaking back at 0.05, roughly "
                    "what voice processing leaves, echo measured 1.0 times "
                    "its learned level and an interruption 11 to 18 times, "
                    "so none was stopped falsely and the interruption was "
                    "caught on its first check. At 0.3, barely cancelled, "
                    "17 echo fragments were let go and the interruption was "
                    "caught on its third check.",
                    "The model is shown the last 16 to 23 turns. The window "
                    "moves 8 turns at a time rather than one, and after each "
                    "reply the model reads the next prompt in while you "
                    "talk. Sliding a turn at a time made every reply past "
                    "the sixteenth re-read about 230 tokens, and its first "
                    "words came 1.86 seconds after you finished instead of "
                    "0.31. With both changes, every turn of a 22-turn "
                    "conversation started in 0.31 to 0.37 seconds.",
                ]},
            ],
        },
        {
            "id": "get",
            "jump": "Get it",
            "eyebrow": "Getting it",
            "heading": "Built from this checkout",
            "blocks": [
                {"kind": "prose", "text": [
                    "The package resolves from this checkout, plus voice-core "
                    "by URL. Nothing else has to sit beside it. The voice the "
                    "build bundles is voice-polyglot's snepssen, English "
                    "included: its newest export where that checkout is beside "
                    "this one, otherwise its latest GitHub release, checked "
                    "against the release's SHA256SUMS and fetched again when "
                    "a newer one is out. No separate English voice is fetched. "
                    "The first build also fetches English Wiktionary's "
                    "extract, 523 MB, and cuts the dictionary from it. The "
                    "language model is downloaded from Settings. Set "
                    "<span class=\"mono\">WORKSHOP_ROOT</span> to the folder that "
                    "holds the workshop checkouts, and one already in "
                    "interpreter-forge's <span class=\"mono\">models/</span> is used "
                    "as it is.",
                ]},
                {"kind": "raw", "html": """  <pre class="code">scripts/fetch-models.sh <span class="c"># Silero VAD, once, from the Silero repository</span>
./build.sh               <span class="c"># checks, then Companion.app and ccrun</span>
swift run cccheck        <span class="c"># the model-free parts, held to their cases</span>

iOS/build-ios.sh         <span class="c"># build, install on a connected iPhone or iPad</span>
iOS/build-ios.sh --no-install</pre>"""},
                {"kind": "prose", "text": [
                    "The iPhone and iPad app is the same engine and views, "
                    "generated with xcodegen as interpreter-forge's is. It offers "
                    "the models that fit beside recognition, the embedder "
                    "and the voice: Qwen3 4B or Gemma 4 E2B on an 8 GB "
                    "iPhone, with the increased memory entitlement, and "
                    "Gemma 4 E4B from 12 GB. It listens while it is on "
                    "screen. Leaving the app stops it and writes the "
                    "conversation up, and coming back starts it again. The "
                    "screen stays on while it is in front. MLX needs a real "
                    "GPU, so there is no Simulator build. It has run on an "
                    "iPhone 17 and an iPad with M4.",
                ]},
            ],
        },
        {
            "id": "limits",
            "jump": "Untried",
            "eyebrow": "Honesty",
            "heading": "What has not been measured yet",
            "blocks": [
                {"kind": "prose", "text": [
                    "It has run on an M1 Mac, an iPhone 17 and an iPad with "
                    "M4. The numbers above are the Mac's. Memory and lag on "
                    "the phone and the tablet are still to be measured the "
                    "same way.",
                    "The spatial voice has not been heard on AirPods. The "
                    "camera, and the phone's stereo microphones, have not "
                    "been tried on a device. Desktop beyond the Mac, and "
                    "Android, are not this app: the README's next step is "
                    "llama.cpp and sherpa-onnx, as interpreter-forge's Android "
                    "port already runs Silero, Parakeet and Piper.",
                    "The sad side of the visor is unused on purpose. If the "
                    "Keychain will not give the key, it says so and runs "
                    "unsealed rather than inventing a new key. Without the "
                    "voiceprint model, everyone is treated as its person.",
                ]},
            ],
        },
    ],

    "footer": [
        '<a href="https://github.com/snepssen/companion-forge">github.com/snepssen/companion-forge</a>'
        ' · part of the <a href="https://snepssen.github.io/tools-core/">snepssen workshop</a>',
    ],
}
