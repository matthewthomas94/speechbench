import FluidAudio
import Foundation

enum ModelPhase: Equatable {
    case unloaded, loading, ready, busy
}

@MainActor
final class TTSController: ObservableObject {
    static let voice = "am_puck"

    @Published private(set) var phase: ModelPhase = .unloaded
    @Published private(set) var errorMessage: String?

    private var manager: KokoroAneManager?

    func load() async {
        await unload()
        phase = .loading
        errorMessage = nil
        let m = KokoroAneManager(defaultVoice: Self.voice, computeUnits: .default)
        do {
            try await m.initialize(preloadVoices: [Self.voice])
            manager = m
            phase = .ready
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
            phase = .unloaded
        }
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        phase = .unloaded
    }

    /// Synthesizes one chunk of speech with the loaded model.
    func synthesizeSamples(_ input: String) async throws -> (samples: [Float], sampleRate: Int)? {
        guard let manager else { return nil }
        let result = try await manager.synthesizeDetailed(text: input, speed: 1.0)
        return (result.samples, result.sampleRate)
    }
}
