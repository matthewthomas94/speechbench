import AVFoundation
import CoreML
import FluidAudio
import Foundation

enum ParakeetModel: String, CaseIterable, Identifiable {
    case v2 = "v2 · English 0.6B"
    case v3 = "v3 · Multilingual 0.6B"
    case ultra = "Ultra · Multilingual 0.6B"
    case redux = "Redux · 2-bit 0.6B"
    case tdtCtc110m = "TDT-CTC · 110M"

    var id: String { rawValue }

    var version: AsrModelVersion {
        switch self {
        case .v2: .v2
        case .v3: .v3
        case .ultra: .ultra
        case .redux: .redux
        case .tdtCtc110m: .tdtCtc110m
        }
    }
}

enum ParakeetCompute: String, CaseIterable, Identifiable {
    case standard = "ANE (default)"
    case encoderGpu = "Encoder on GPU"
    case cpuAndGpu = "CPU + GPU (no ANE)"
    case cpuOnly = "CPU only"

    var id: String { rawValue }

    /// nil keeps FluidAudio's per-model defaults (preprocessor on CPU, rest on ANE).
    var configuration: MLModelConfiguration? {
        switch self {
        case .standard, .encoderGpu: return nil
        case .cpuAndGpu, .cpuOnly:
            let config = AsrModels.defaultConfiguration()
            config.computeUnits = self == .cpuOnly ? .cpuOnly : .cpuAndGPU
            return config
        }
    }

    var encoderUnits: MLComputeUnits? { self == .encoderGpu ? .cpuAndGPU : nil }
}

@MainActor
final class STTController: ObservableObject {
    struct Run: Identifiable {
        let id = UUID()
        let source: String
        let model: String
        let audioSeconds: Double
        let text: String
        let confidence: Float
        let reference: String?
        let wer: Double?
        let cost: RunCost
        var rtfx: Double { audioSeconds / cost.wallSeconds }
    }

    @Published var model: ParakeetModel = .v2
    @Published var compute: ParakeetCompute = .standard
    @Published private(set) var phase: ModelPhase = .unloaded
    @Published private(set) var loadedLabel: String?
    @Published private(set) var progressText: String?
    @Published private(set) var loadInfo: LoadInfo?
    @Published private(set) var runs: [Run] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var recordingStart: Date?

    private var manager: AsrManager?
    private let recorder = MicRecorder()

    func load() async {
        await unload()
        phase = .loading
        errorMessage = nil
        let selectedModel = model, selectedCompute = compute
        let progress: ProgressHandler = { [weak self] p in
            let text: String
            switch p.phase {
            case .listing: text = "Listing files…"
            case .downloading(let done, let total): text = "Downloading \(done)/\(total) files · \(Int(p.fractionCompleted * 100))%"
            case .compiling(let name): text = "Compiling \(name)…"
            }
            Task { @MainActor in self?.progressText = text }
        }
        do {
            let downloadStart = ProcessInfo.processInfo.systemUptime
            let dir = try await AsrModels.download(version: selectedModel.version, progressHandler: progress)
            let downloadSeconds = ProcessInfo.processInfo.systemUptime - downloadStart
            progressText = "Loading into Core ML…"

            let meter = RunMeter()
            let models = try await AsrModels.load(
                from: dir, configuration: selectedCompute.configuration, version: selectedModel.version,
                encoderComputeUnits: selectedCompute.encoderUnits, progressHandler: progress)
            let m = AsrManager()
            try await m.loadModels(models)
            let label = "Parakeet \(selectedModel.rawValue) · \(selectedCompute.rawValue)"
            loadInfo = LoadInfo(
                label: label, downloadSeconds: downloadSeconds, cost: meter.finish(),
                footprintAfterMB: SystemMetrics.processFootprintBytes().map { Double($0) / 1_048_576 })
            manager = m
            loadedLabel = label
            phase = .ready
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
            phase = .unloaded
        }
        progressText = nil
    }

    func unload() async {
        if let manager { await manager.cleanup() }
        manager = nil
        loadedLabel = nil
        loadInfo = nil
        phase = .unloaded
    }

    func toggleRecording() async {
        if recordingStart != nil {
            let raw = recorder.stop()
            recordingStart = nil
            do {
                let samples = try AudioConverter().resample(raw.samples, from: raw.sampleRate)
                await transcribe(samples, source: "Microphone", reference: nil)
            } catch {
                errorMessage = "Resample failed: \(error.localizedDescription)"
            }
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access denied — enable it in Settings › SpeechBench."
            return
        }
        do {
            try recorder.start()
            recordingStart = Date()
            errorMessage = nil
        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    /// Feed Kokoro's output back through Parakeet and score it against the input text.
    func transcribeRoundTrip(_ output: TTSController.Output) async {
        do {
            let samples = try AudioConverter().resample(output.samples, from: Double(output.sampleRate))
            await transcribe(samples, source: "Kokoro round-trip", reference: output.text)
        } catch {
            errorMessage = "Resample failed: \(error.localizedDescription)"
        }
    }

    private func transcribe(_ samples16k: [Float], source: String, reference: String?) async {
        guard let manager, phase == .ready else { return }
        guard samples16k.count > 1600 else {
            errorMessage = "Recording too short."
            return
        }
        phase = .busy
        errorMessage = nil
        let meter = RunMeter()
        do {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples16k, decoderState: &state)
            let cost = meter.finish()
            runs.insert(
                Run(source: source, model: loadedLabel ?? "", audioSeconds: Double(samples16k.count) / 16_000,
                    text: result.text, confidence: result.confidence, reference: reference,
                    wer: reference.map { wordErrorRate(reference: $0, hypothesis: result.text) }, cost: cost),
                at: 0)
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
        }
        phase = .ready
    }

    /// Transcribes with the loaded model without recording a run (used by the conversation loop).
    func transcribeText(_ samples16k: [Float]) async throws -> String? {
        guard let manager else { return nil }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples16k, decoderState: &state).text
    }

    func clearRuns() { runs.removeAll() }
}

/// Captures mono microphone audio at the hardware rate.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000

    func start() throws {
        lock.withLock { samples.removeAll() }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> (samples: [Float], sampleRate: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { (samples, sampleRate) }
    }
}

/// Word error rate after lowercasing and stripping punctuation.
func wordErrorRate(reference: String, hypothesis: String) -> Double {
    func words(_ s: String) -> [String] {
        let cleaned = s.lowercased().map { (c: Character) -> Character in
            c.isLetter || c.isNumber || c == "'" ? c : " "
        }
        return String(cleaned).split(separator: " ").map(String.init)
    }
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var prev = Array(0...h.count)
    for i in 1...r.count {
        var cur = [i] + Array(repeating: 0, count: h.count)
        for j in stride(from: 1, through: h.count, by: 1) {
            cur[j] = r[i - 1] == h[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], cur[j - 1])
        }
        prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
}
