import SwiftUI

struct STTView: View {
    @EnvironmentObject private var stt: STTController
    @EnvironmentObject private var tts: TTSController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $stt.model) {
                        ForEach(ParakeetModel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Compute units", selection: $stt.compute) {
                        ForEach(ParakeetCompute.allCases) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Button(stt.phase == .unloaded ? "Load model" : "Reload model") {
                            Task { await stt.load() }
                        }
                        .disabled(stt.phase == .loading || stt.phase == .busy || stt.recordingStart != nil)
                        Spacer()
                        if stt.phase != .unloaded && stt.phase != .loading {
                            Button("Unload", role: .destructive) { Task { await stt.unload() } }
                        }
                    }
                    if stt.phase == .loading {
                        HStack {
                            ProgressView()
                            Text(stt.progressText ?? "Preparing…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let info = stt.loadInfo { LoadInfoView(info: info) }
                } header: {
                    Text("Model · Parakeet TDT (Core ML)")
                } footer: {
                    Text("0.6B models are ~450–600 MB to download the first time. Changing model or compute units needs a reload.")
                }

                Section {
                    Button {
                        Task { await stt.toggleRecording() }
                    } label: {
                        if let start = stt.recordingStart {
                            TimelineView(.periodic(from: start, by: 0.1)) { context in
                                Label(
                                    "Stop & transcribe (\(Fmt.num(context.date.timeIntervalSince(start), 1)) s)",
                                    systemImage: "stop.circle.fill")
                            }
                        } else {
                            Label(stt.phase == .busy ? "Transcribing…" : "Record", systemImage: "mic.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(stt.recordingStart == nil ? .accentColor : .red)
                    .disabled(stt.phase != .ready)

                    Button {
                        if let output = tts.lastOutput { Task { await stt.transcribeRoundTrip(output) } }
                    } label: {
                        Label("Transcribe last Kokoro output", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(stt.phase != .ready || tts.lastOutput == nil || stt.recordingStart != nil)
                } header: {
                    Text("Input")
                } footer: {
                    Text("Round-trip feeds the most recent TTS audio into Parakeet and reports word error rate against the original text.")
                }

                if let error = stt.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }

                if !stt.runs.isEmpty {
                    Section {
                        ForEach(stt.runs) { STTRunRow(run: $0) }
                    } header: {
                        HStack {
                            Text("Runs (newest first)")
                            Spacer()
                            Button("Clear") { stt.clearRuns() }.font(.caption)
                        }
                    } footer: {
                        Text("RTFx = seconds of audio transcribed per second of compute. Energy is the kernel's CPU estimate and excludes Neural Engine work.")
                    }
                }
            }
            .navigationTitle("Parakeet STT")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { TelemetryHUD() }
        }
    }
}

private struct STTRunRow: View {
    let run: STTController.Run

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.text.isEmpty ? "(no speech detected)" : run.text)
                .font(.callout)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                stat("RTFx", Fmt.num(run.rtfx, 1, suffix: "×"))
                stat("Latency", Fmt.seconds(run.cost.wallSeconds))
                stat("Audio", Fmt.seconds(run.audioSeconds))
                stat("Confidence", Fmt.num(Double(run.confidence), 2))
                if let wer = run.wer { stat("WER", Fmt.num(wer * 100, 1, suffix: "%")) }
            }
            CostLine(cost: run.cost)
            Text("\(run.source) · \(run.model)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
