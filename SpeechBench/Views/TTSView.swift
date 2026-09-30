import SwiftUI

struct TTSView: View {
    @EnvironmentObject private var tts: TTSController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Compute units", selection: $tts.compute) {
                        ForEach(KokoroCompute.allCases) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Button(tts.phase == .unloaded ? "Load model" : "Reload model") {
                            Task { await tts.load() }
                        }
                        .disabled(tts.phase == .loading || tts.phase == .busy)
                        Spacer()
                        if tts.phase != .unloaded && tts.phase != .loading {
                            Button("Unload", role: .destructive) { Task { await tts.unload() } }
                        }
                    }
                    if tts.phase == .loading {
                        HStack {
                            ProgressView()
                            Text("Downloading & compiling for the Neural Engine — first load can take a minute…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let info = tts.loadInfo { LoadInfoView(info: info) }
                    if let loaded = tts.loadedCompute, loaded != tts.compute {
                        Text("Loaded with “\(loaded.rawValue)”. Reload to apply the new compute units.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Model · Kokoro 82M (Core ML)")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Speed \(Fmt.num(tts.speed, 2))×").font(.subheadline)
                        Slider(value: $tts.speed, in: 0.5...2.0, step: 0.05)
                    }
                    TextEditor(text: $tts.text)
                        .frame(minHeight: 110)
                        .font(.callout)
                    HStack {
                        Menu("Sample text") {
                            ForEach(TTSController.sampleTexts, id: \.label) { sample in
                                Button(sample.label) { tts.text = sample.text }
                            }
                        }
                        Spacer()
                        Text("\(tts.text.count) chars").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button {
                            Task { await tts.synthesize() }
                        } label: {
                            Label(tts.phase == .busy ? "Synthesizing…" : "Synthesize", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tts.phase != .ready || tts.text.isEmpty)
                        Spacer()
                        Button("Replay") { tts.play() }.disabled(tts.lastOutput == nil)
                        Button("Stop") { tts.stopPlayback() }
                    }
                } header: {
                    Text("Input · voice \(TTSController.voice)")
                }

                if let error = tts.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }

                if !tts.runs.isEmpty {
                    Section {
                        ForEach(Array(tts.runs.enumerated()), id: \.element.id) { index, run in
                            TTSRunRow(run: run, expanded: index == 0)
                        }
                    } header: {
                        HStack {
                            Text("Runs (newest first)")
                            Spacer()
                            Button("Clear") { tts.clearRuns() }.font(.caption)
                        }
                    } footer: {
                        Text("RTFx = seconds of audio produced per second of compute. Energy is the kernel's CPU estimate and excludes Neural Engine work.")
                    }
                }
            }
            .navigationTitle("Kokoro TTS")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { TelemetryHUD() }
        }
    }
}

private struct TTSRunRow: View {
    let run: TTSController.Run
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                stat("RTFx", Fmt.num(run.rtfx, 1, suffix: "×"))
                stat("Synth", Fmt.seconds(run.cost.wallSeconds))
                stat("Audio", Fmt.seconds(run.audioSeconds))
                stat("J / audio-s", Fmt.num(run.cost.energyJ.map { $0 / run.audioSeconds }, 3))
            }
            CostLine(cost: run.cost)
            Text("\(run.characters) chars · \(run.compute)")
                .font(.caption2).foregroundStyle(.secondary)
            if expanded {
                let t = run.stages
                Text(
                    "Stages (ms): albert \(Fmt.num(t.albert, 0)) · postAlbert \(Fmt.num(t.postAlbert, 0)) · align \(Fmt.num(t.alignment, 0)) · prosody \(Fmt.num(t.prosody, 0)) · noise \(Fmt.num(t.noise, 0)) · vocoder \(Fmt.num(t.vocoder, 0)) · tail \(Fmt.num(t.tail, 0)) = \(Fmt.num(t.totalMs, 0))"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
