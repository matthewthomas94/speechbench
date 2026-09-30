import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var tts: TTSController
    @EnvironmentObject private var stt: STTController

    private var allLoaded: Bool { stt.phase.isLoaded && conversation.llmPhase.isLoaded && tts.phase.isLoaded }
    private var anyLoading: Bool { stt.phase == .loading || conversation.llmPhase == .loading || tts.phase == .loading }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        modelRow("Parakeet STT", stt.phase, stt.progressText ?? stt.loadedLabel)
                        modelRow("Gemma 3 1B (4-bit)", conversation.llmPhase, conversation.llmProgress)
                        modelRow("Kokoro TTS", tts.phase, tts.loadInfo?.label)
                        if !allLoaded {
                            Button(anyLoading ? "Loading…" : "Load all") { Task { await conversation.loadAll() } }
                                .disabled(anyLoading)
                        }
                        if let info = conversation.llmLoadInfo { LoadInfoView(info: info) }
                    } header: {
                        Text("Models")
                    } footer: {
                        Text("Parakeet and Kokoro use the settings from their tabs. First Gemma load downloads ~0.7 GB.")
                    }

                    if let error = conversation.errorMessage {
                        Section { Text(error).foregroundStyle(.red).font(.callout) }
                    }

                    Section {
                        if conversation.messages.isEmpty {
                            Text("Tap the button, speak, then tap again to send. Tap while Gemma is replying to interrupt. You can also ask about the models, speed, CPU, memory, power, battery or temperature.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(conversation.messages) { MessageRow(message: $0).id($0.id) }
                    } header: {
                        Text("Conversation")
                    } footer: {
                        if !conversation.messages.isEmpty {
                            Text("To first audio = tap-to-send until the first reply sentence is queued for playback. Cost covers STT, generation and synthesis, not playback. Questions about the models or telemetry are answered from a live status report, without chat history.")
                        }
                    }
                }
                .onChange(of: conversation.messages.last?.text) {
                    if let id = conversation.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Reset") { conversation.reset() }.disabled(conversation.messages.isEmpty)
            }
            .safeAreaInset(edge: .top, spacing: 0) { TelemetryHUD() }
            .safeAreaInset(edge: .bottom, spacing: 0) { talkButton.disabled(!allLoaded) }
        }
    }

    private var talkButton: some View {
        Button {
            Task { await conversation.toggleTalk() }
        } label: {
            Group {
                switch conversation.state {
                case .idle:
                    Label("Tap to talk", systemImage: "mic.fill")
                case .listening:
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        let seconds = context.date.timeIntervalSince(conversation.listeningSince ?? context.date)
                        Label("Listening \(Fmt.num(seconds, 1)) s · tap to send", systemImage: "waveform")
                            .monospacedDigit()
                    }
                case .thinking:
                    Label("Thinking… tap to interrupt", systemImage: "ellipsis")
                case .speaking:
                    Label("Speaking… tap to interrupt", systemImage: "speaker.wave.2.fill")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(conversation.state == .listening ? .red : .accentColor)
        .padding()
        .background(.bar)
    }

    private func modelRow(_ name: String, _ phase: ModelPhase, _ detail: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            switch phase {
            case .unloaded: Text("Not loaded").foregroundStyle(.secondary)
            case .loading: ProgressView()
            case .ready, .busy: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .font(.callout)
    }
}

private struct MessageRow: View {
    let message: ConversationController.Message

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.isUser ? "You" : "Gemma")
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.isUser ? .blue : .purple)
            Text(message.text.isEmpty ? "…" : message.text)
            if let m = message.metrics {
                HStack(spacing: 12) {
                    stat("To first audio", Fmt.seconds(m.toFirstAudio))
                    stat("STT", Fmt.seconds(m.sttSeconds))
                    stat("First token", Fmt.seconds(m.timeToFirstToken))
                    stat("Tok/s", Fmt.num(m.tokensPerSecond, 1))
                }
                .padding(.top, 2)
                Text(
                    "Heard \(Fmt.num(m.heardSeconds, 1)) s · prompt \(m.promptTokens) tok · reply \(m.generatedTokens) tok · 1st sentence synth \(Fmt.seconds(m.firstSentenceSynthSeconds))\(m.usedStatus ? " · from live status" : "")"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                CostLine(cost: m.cost)
            }
        }
        .padding(.vertical, 2)
    }
}
