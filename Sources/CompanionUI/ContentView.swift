import CompanionCore
import CompanionEngine
import SwiftUI

/// The face, what was last said underneath it, and one button.
public struct ContentView: View {
    @Bindable var companion: Companion
    @State private var settings = false

    public init(companion: Companion) { self.companion = companion }

    public var body: some View {
        VStack(spacing: 0) {
            FaceView(performance: companion.face)
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            captions
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            bar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.white.opacity(0.04))
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .task { await companion.prepare() }
    }

    /// The last thing each of them said.
    private var captions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(companion.lines.suffix(2)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.speaker == .person ? "You" : "Companion")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(line.speaker == .person ? .secondary : Color.cyan.opacity(0.8))
                        .frame(width: 84, alignment: .trailing)
                    Text(line.text + (line.interrupted ? " —" : ""))
                        .font(.body)
                        .foregroundStyle(.white.opacity(line.speaker == .person ? 0.7 : 0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 64, alignment: .bottom)
        .animation(.easeOut(duration: 0.2), value: companion.lines)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status).font(.callout).foregroundStyle(.white.opacity(0.85))
                if let notice = companion.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if companion.phase == .needsModel {
                Button("Choose a model…") { settings = true }
            }
            Button(companion.listening ? "Stop" : "Talk") {
                Task { await companion.toggle() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!(companion.phase == .ready || companion.phase == .live))
            .buttonStyle(.borderedProminent)
            .tint(companion.listening ? .red : .cyan)
            Button {
                settings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")
            .popover(isPresented: $settings, arrowEdge: .bottom) {
                SettingsView(companion: companion)
            }
        }
    }

    private var status: String {
        switch companion.phase {
        case .idle: "Starting…"
        case let .loading(what): what
        case .needsModel: "No language model on this Mac yet."
        case .ready: "Ready. Press Talk or Space."
        case .live:
            switch companion.face.mood {
            case .listening: "Listening…"
            case .thinking: "Thinking…"
            case .speaking: "Speaking"
            default: "Listening for you"
            }
        case let .failed(message): message
        }
    }
}

/// The model, echo cancellation, and what it has learned about your pauses.
struct SettingsView: View {
    @Bindable var companion: Companion

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
                            Image(systemName: "checkmark").foregroundStyle(.cyan)
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
            Section("Speaking") {
                Toggle("Echo cancellation", isOn: $companion.echoCancellation)
                Text("Lets it talk out of the speakers without hearing itself. Takes effect the next time you press Talk.")
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
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
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
