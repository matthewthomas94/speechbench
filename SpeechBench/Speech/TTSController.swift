import AVFoundation
import FluidAudio
import Foundation

enum KokoroCompute: String, CaseIterable, Identifiable {
    case standard = "Default (OS-tuned)"
    case aneTailGpu = "ANE + GPU tail"
    case aneTailCpu = "ANE + CPU tail"
    case allAne = "All ANE"
    case cpuAndGpu = "CPU + GPU (no ANE)"
    case cpuOnly = "CPU only"

    var id: String { rawValue }

    var units: KokoroAneComputeUnits {
        switch self {
        case .standard: .default
        case .aneTailGpu: .aneTailGpu
        case .aneTailCpu: .aneTailCpu
        case .allAne: .allAne
        case .cpuAndGpu: .cpuAndGpu
        case .cpuOnly: .cpuOnly
        }
    }
}

enum ModelPhase: Equatable {
    case unloaded, loading, ready, busy
}

struct LoadInfo {
    let label: String
    let downloadSeconds: Double?
    let cost: RunCost
    let footprintAfterMB: Double?
}

@MainActor
final class TTSController: ObservableObject {
    struct Output {
        let samples: [Float]
        let sampleRate: Int
        let text: String
    }

    struct Run: Identifiable {
        let id = UUID()
        let characters: Int
        let compute: String
        let audioSeconds: Double
        let stages: KokoroAneStageTimings
        let cost: RunCost
        var rtfx: Double { audioSeconds / cost.wallSeconds }
    }

    static let sampleTexts: [(label: String, text: String)] = [
        ("Short", "Hello! This is Kokoro running entirely on this iPhone."),
        ("Medium", "On-device speech synthesis lets your phone talk without a network connection. This paragraph exists to measure how quickly Kokoro turns text into audio, and how much power and memory it takes to do it."),
        ("Long", "The Neural Engine is a dedicated block of silicon designed to run machine learning models efficiently. Kokoro is an eighty-two million parameter text to speech model, small enough to fit comfortably in memory, yet expressive enough to sound natural. In this benchmark we split the model into seven stages, run most of them on the Neural Engine, and hand the rest to the GPU or CPU. Longer passages like this one are chunked automatically, so you can compare real-time factor, energy per second of audio, and peak memory across different lengths of text."),
    ]

    static let voice = "am_puck"

    @Published var compute: KokoroCompute = .standard
    @Published var speed: Double = 1.0
    @Published var text = TTSController.sampleTexts[1].text
    @Published private(set) var phase: ModelPhase = .unloaded
    @Published private(set) var loadedCompute: KokoroCompute?
    @Published private(set) var loadInfo: LoadInfo?
    @Published private(set) var runs: [Run] = []
    @Published private(set) var lastOutput: Output?
    @Published private(set) var errorMessage: String?

    private var manager: KokoroAneManager?
    private var player: AVAudioPlayer?

    func load() async {
        await unload()
        phase = .loading
        errorMessage = nil
        let selected = compute
        let meter = RunMeter()
        let m = KokoroAneManager(defaultVoice: Self.voice, computeUnits: selected.units)
        do {
            try await m.initialize(preloadVoices: [Self.voice])
            manager = m
            loadedCompute = selected
            loadInfo = LoadInfo(
                label: "Kokoro 82M · \(Self.voice) · \(selected.rawValue)", downloadSeconds: nil, cost: meter.finish(),
                footprintAfterMB: SystemMetrics.processFootprintBytes().map { Double($0) / 1_048_576 })
            phase = .ready
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
            phase = .unloaded
        }
    }

    func unload() async {
        stopPlayback()
        await manager?.cleanup()
        manager = nil
        loadedCompute = nil
        loadInfo = nil
        phase = .unloaded
    }

    func synthesize() async {
        guard let manager, phase == .ready else { return }
        stopPlayback()
        phase = .busy
        errorMessage = nil
        let input = text
        let meter = RunMeter()
        do {
            let result = try await manager.synthesizeDetailed(text: input, speed: Float(speed))
            let cost = meter.finish()
            runs.insert(
                Run(characters: input.count, compute: loadedCompute?.rawValue ?? "",
                    audioSeconds: Double(result.samples.count) / Double(result.sampleRate),
                    stages: result.timings, cost: cost),
                at: 0)
            lastOutput = Output(samples: result.samples, sampleRate: result.sampleRate, text: input)
            play()
        } catch {
            errorMessage = "Synthesis failed: \(error.localizedDescription)"
        }
        phase = .ready
    }

    /// Synthesizes with the loaded model without recording a run (used by the conversation loop).
    func synthesizeSamples(_ input: String) async throws -> (samples: [Float], sampleRate: Int)? {
        guard let manager else { return nil }
        let result = try await manager.synthesizeDetailed(text: input, speed: Float(speed))
        return (result.samples, result.sampleRate)
    }

    func play() {
        guard let lastOutput else { return }
        do {
            let wav = try AudioWAV.data(
                from: lastOutput.samples, sampleRate: Double(lastOutput.sampleRate), normalize: false)
            player = try AVAudioPlayer(data: wav)
            player?.play()
        } catch {
            errorMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
    }

    func clearRuns() { runs.removeAll() }
}
