import Foundation
import MLXAudioTTS

enum ModelPhase: Equatable {
    case unloaded, loading, ready, busy
}

/// Kokoro on MLX. FluidAudio's Core ML Kokoro segfaults in libBNNS on iOS 26.4+ whatever the
/// compute units (FluidAudio issues #844, #889), so Kokoro runs on the same engine as Gemma.
@MainActor
final class TTSController: ObservableObject {
    static let voice = "am_puck"
    static let repo = "mlx-community/Kokoro-82M-bf16"

    @Published private(set) var phase: ModelPhase = .unloaded
    @Published private(set) var errorMessage: String?

    private var model: KokoroModel?

    func load() async {
        await unload()
        phase = .loading
        errorMessage = nil
        do {
            // The English phonemizer alone: KokoroMultilingualProcessor re-checks the Hub on every call.
            model = try await KokoroModel.fromPretrained(Self.repo, textProcessor: MisakiTextProcessor())
            phase = .ready
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
            phase = .unloaded
        }
    }

    func unload() async {
        model = nil
        phase = .unloaded
    }

    /// Synthesizes one chunk of speech with the loaded model.
    func synthesizeSamples(_ input: String) async throws -> (samples: [Float], sampleRate: Int)? {
        guard let model else { return nil }
        let samples = try await Self.synthesize(model, input, voice: Self.voice)
        return (samples, model.sampleRate)
    }

    /// Off the main actor, since reading the samples out runs the model.
    private nonisolated static func synthesize(_ model: KokoroModel, _ text: String, voice: String) async throws -> [Float] {
        let audio = try await model.generate(text: text, voice: voice, refAudio: nil, refText: nil, language: nil)
        return audio.asArray(Float.self)
    }
}
