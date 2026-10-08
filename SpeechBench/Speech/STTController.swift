import AVFoundation
import FluidAudio
import Foundation
import VoiceGlowKit

@MainActor
final class STTController: ObservableObject {
    @Published private(set) var phase: ModelPhase = .unloaded
    @Published private(set) var progressText: String?
    @Published private(set) var errorMessage: String?

    private var manager: AsrManager?

    func load() async {
        await unload()
        phase = .loading
        errorMessage = nil
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
            let dir = try await AsrModels.download(version: .v2, progressHandler: progress)
            progressText = "Loading into Core ML…"
            let models = try await AsrModels.load(
                from: dir, configuration: nil, version: .v2, encoderComputeUnits: nil, progressHandler: progress)
            let m = AsrManager()
            try await m.loadModels(models)
            manager = m
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
        phase = .unloaded
    }

    /// Transcribes 16 kHz mono audio with the loaded model.
    func transcribeText(_ samples16k: [Float]) async throws -> String? {
        guard let manager else { return nil }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples16k, decoderState: &state).text
    }
}

/// Captures mono microphone audio at the hardware rate. The microphone is `meter`'s, so the voice
/// overlay's glow follows the same audio being recorded.
@MainActor
final class MicRecorder {
    let meter = VoiceMeter()
    private let take = Take()
    private var handler: UUID?

    func start() async throws {
        take.reset()
        handler = meter.addBufferHandler { [take] in take.append($0) }
        do { try await meter.start() } catch { _ = stop(); throw error }
    }

    func stop() -> (samples: [Float], sampleRate: Double) {
        meter.stop()
        if let handler { meter.removeBufferHandler(handler) }
        handler = nil
        return take.contents
    }
}

/// The recording so far, appended to off the main thread.
private final class Take: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000

    func reset() { lock.withLock { samples.removeAll() } }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock {
            sampleRate = buffer.format.sampleRate
            samples.append(contentsOf: chunk)
        }
    }

    var contents: (samples: [Float], sampleRate: Double) { lock.withLock { (samples, sampleRate) } }
}
