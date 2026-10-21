import CompanionCore
import CompanionEngine
import SwiftUI

/// The face and what was last said underneath it. There is nothing to press
/// to talk: it listens as soon as it is ready. Double-click or double-tap the
/// face to leave only the face, for a tablet on a stand.
public struct ContentView: View {
    @Bindable var companion: Companion
    @State private var settings = false
    @State private var transcript = false
    @State private var faceOnly = false
    @AppStorage(VisorColour.key) private var colour = VisorColour.cyan
    @AppStorage(VisorStyle.key) private var style = VisorStyle.panel
    #if os(iOS)
    /// A phone on its side: little height, so the face gets what there is.
    @Environment(\.verticalSizeClass) private var height
    private var short: Bool { height == .compact }
    #else
    private let short = false
    #endif

    public init(companion: Companion) { self.companion = companion }

    public var body: some View {
        VStack(spacing: 0) {
            FaceView(performance: companion.face, colour: colour.color, style: style,
                     hearing: { [companion] in companion.listening ? companion.level : 0 },
                     felt: { [motion = companion.motion] in motion.felt() },
                     look: { [attention = companion.attention] in attention.look() },
                     dance: { [beat = companion.beat] in beat.step() })
            #if os(macOS)
            .background(WindowMotion(motion: companion.motion))
            #endif
            .padding(.horizontal, faceOnly ? 16 : 40)
            .padding(.vertical, faceOnly || short ? 8 : 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.3)) { faceOnly.toggle() } }
            .accessibilityAction(named: faceOnly ? "Show controls" : "Show only the face") { faceOnly.toggle() }
            if !faceOnly {
                captions
                    .padding(.horizontal, 24)
                    .padding(.bottom, short ? 4 : 12)
                    .transition(.opacity)
            }
            if !faceOnly {
                bar
                    .padding(.horizontal, 16)
                    .padding(.vertical, short ? 6 : 12)
                    .background(.white.opacity(0.04))
                    .transition(.opacity)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .tint(colour.color)
        .task { await companion.prepare() }
        .sheet(isPresented: $transcript) { TranscriptView(companion: companion, colour: colour.color) }
    }

    /// The last thing each of them said, dimming once the conversation goes quiet.
    private var captions: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let quiet = context.date.timeIntervalSince(companion.lines.last?.at ?? .distantPast)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(companion.lines.suffix(2)) { line in
                    LineView(line: line, colour: colour.color)
                }
            }
            .opacity(quiet < 12 ? 1 : max(0.3, 1 - (quiet - 12) / 4))
            .animation(.easeOut(duration: 1), value: quiet > 12)
        }
        .overlay(alignment: .topLeading) {
            if !companion.recalled.isEmpty {
                Label(companion.recalled.map(\.text).joined(separator: " · "), systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(colour.color.opacity(0.55))
                    .lineLimit(1)
                    .offset(y: -22)
                    .accessibilityLabel("Remembering: \(companion.recalled.map(\.text).joined(separator: ", "))")
            }
        }
        .frame(minHeight: 64, alignment: .bottom)
        .animation(.easeOut(duration: 0.2), value: companion.lines)
    }

    private var bar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Label(status, systemImage: companion.listening ? "mic.fill" : "mic.slash")
                    .font(.callout).foregroundStyle(.white.opacity(0.85))
                if let notice = companion.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if companion.phase == .needsModel {
                Button("Choose a model…") { settings = true }
            }
            Button {
                transcript = true
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.borderless)
            .disabled(companion.lines.isEmpty)
            .accessibilityLabel("Conversation")
            .help("The whole conversation")
            Button {
                settings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")
            #if os(macOS)
            .popover(isPresented: $settings, arrowEdge: .bottom) {
                SettingsView(companion: companion)
            }
            #else
            // A sheet on iPhone and iPad: an iPad's popover sized itself to
            // nothing around a form.
            .sheet(isPresented: $settings) {
                NavigationStack {
                    SettingsView(companion: companion)
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } }
                        }
                }
            }
            #endif
        }
        .foregroundStyle(.white.opacity(0.8))
    }

    private var status: String {
        switch companion.phase {
        case .idle: "Waking up…"
        case let .loading(what): what
        case .needsModel: "It needs a language model to talk with."
        case .ready: "Ready."
        case .live:
            switch companion.face.mood {
            case .listening: "Listening…"
            case .thinking: "Thinking…"
            case .speaking, .cheerful: "Speaking"
            default: "Listening for you"
            }
        case let .failed(message): message
        }
    }
}

/// One line of the conversation: who, and what.
struct LineView: View {
    let line: Companion.Line
    let colour: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.speaker == .person ? "You" : "Companion")
                .font(.caption.weight(.semibold))
                .foregroundStyle(line.speaker == .person ? Color.white.opacity(0.45) : colour.opacity(0.8))
                .frame(width: 84, alignment: .trailing)
            Text(line.text + (line.interrupted ? " —" : ""))
                .font(.body)
                .foregroundStyle(.white.opacity(line.speaker == .person ? 0.7 : 0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

/// The whole conversation since the app opened.
struct TranscriptView: View {
    let companion: Companion
    let colour: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversation").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(companion.lines) { line in
                            LineView(line: line, colour: colour).id(line.id)
                        }
                    }
                    .padding()
                }
                .onAppear { scroller.scrollTo(companion.lines.last?.id, anchor: .bottom) }
                .onChange(of: companion.lines.count) { scroller.scrollTo(companion.lines.last?.id, anchor: .bottom) }
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 560, height: 560)
        #endif
    }
}

/// The model, echo cancellation, memory, and what it has learned about your pauses.
struct SettingsView: View {
    @Bindable var companion: Companion
    @State private var showingMemory = false
    @AppStorage(VisorColour.key) private var colour = VisorColour.cyan
    @AppStorage(VisorStyle.key) private var style = VisorStyle.panel

    var body: some View {
        Form {
            Section("Language model") {
                ForEach(ModelCatalog.all) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name).fontWeight(model == companion.model ? .semibold : .regular)
                            Text(model.tagline).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let downloading = companion.downloading, downloading.model == model {
                            ProgressView(value: downloading.progress).frame(width: 80)
                        } else if model == companion.model && companion.isDownloaded(model) {
                            Image(systemName: "checkmark").foregroundStyle(colour.color)
                        } else {
                            Button(companion.isDownloaded(model)
                                   ? "Use" : "Download \(ByteCountFormatter.string(fromByteCount: model.download, countStyle: .file))") {
                                Task { await companion.use(model) }
                            }
                            .disabled(companion.downloading != nil)
                        }
                    }
                }
            }
            Section("Personality") {
                Picker("Personality", selection: $companion.personality) {
                    ForEach(Personality.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(companion.personality.summary).font(.caption).foregroundStyle(.secondary)
            }
            Section("Face") {
                Picker("Visor", selection: $style) {
                    ForEach(VisorStyle.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    ForEach(VisorColour.allCases) { option in
                        Button {
                            colour = option
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.white, lineWidth: option == colour ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(option == colour ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
                #if os(macOS)
                Text("Double-click the face to hide everything else; double-click again to bring it back.")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("Double-tap the face to hide everything else; double-tap again to bring it back.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                Picker("Dance to music", selection: $companion.dance) {
                    Text("Off").tag(Dance.Pattern?.none)
                    Text("Up and down").tag(Dance.Pattern?.some(.nod))
                    Text("Infinity").tag(Dance.Pattern?.some(.infinity))
                }
                Text("When it hears music with a steady kick drum, it moves to the beat, landing on each kick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speaking") {
                Toggle("Echo cancellation", isOn: $companion.echoCancellation)
                #if os(macOS)
                Text("On a Mac it keeps its own voice out by itself; this switch only matters on iPhone and iPad.")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("Lets it talk out of the speakers without hearing itself. Turn it off only on headphones.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                Toggle("Look at whoever is talking", isOn: $companion.watching)
                Text("Uses the front camera to see who is talking and turn to them. Nothing it sees is kept or leaves "
                     + "this device. Without the echo canceller, the microphones tell it too.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Spatial voice", isOn: $companion.spatialVoice)
                Text("On AirPods, its voice comes from where your phone or Mac is, and stays there when you turn your head.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Memory") {
                LabeledContent("Remembers", value: companion.notes.count == 1 ? "1 thing" : "\(companion.notes.count) things")
                if companion.writingUp {
                    Text("Writing up the last conversation…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Show what it remembers…") { showingMemory = true }
                    .disabled(companion.notes.isEmpty)
                Text("Notes are written from your conversations when they go quiet, and the full conversations are kept "
                     + "on this Mac so it can look back at what was said.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Turn timing") {
                let timing = companion.timing
                LabeledContent("After a question", value: seconds(timing.wait(after: .question)))
                LabeledContent("After a statement", value: seconds(timing.wait(after: .statement)))
                LabeledContent("When you trail off", value: seconds(timing.wait(after: .open)))
                Text(learned(timing)).font(.caption).foregroundStyle(.secondary)
                Button("Forget and start learning again") { companion.resetTiming() }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        // A fixed height, so the form scrolls: sized to its content it ran
        // off the bottom of the screen with nothing to scroll.
        .frame(width: 420, height: 560)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .sheet(isPresented: $showingMemory) { MemoryView(companion: companion) }
    }

    private func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }

    private func learned(_ timing: PauseModel) -> String {
        let pauses = timing.pauses.count
        if pauses < 8 {
            return "Still learning how you pause: \(pauses) of 8 pauses heard. Until then it waits 0.9 s after a statement."
        }
        let cutIns = timing.cutIns == 1 ? "1 time" : "\(timing.cutIns) times"
        return "Learned from your last \(pauses) pauses. It has cut in on you \(cutIns) in \(timing.replies) replies."
    }
}

/// Everything it remembers, to read and to take back.
struct MemoryView: View {
    let companion: Companion
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What it remembers").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            List {
                let lasting = companion.notes.filter(\.lasting)
                if !lasting.isEmpty {
                    Section("About you") {
                        ForEach(lasting) { row($0) }
                    }
                }
                Section("From your conversations") {
                    ForEach(companion.notes.filter { !$0.lasting }) { row($0) }
                }
            }
            HStack {
                Text("Forgetting everything deletes every note and every saved conversation.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Forget everything…", role: .destructive) { confirming = true }
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
        .confirmationDialog("Forget everything it remembers, and delete every saved conversation?",
                            isPresented: $confirming) {
            Button("Forget everything", role: .destructive) {
                Task { await companion.forgetEverything() }
            }
        }
    }

    private func row(_ note: Note) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.text)
                Text(Remembering.when(note.at)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await companion.forget(note) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Forget this")
        }
    }
}
