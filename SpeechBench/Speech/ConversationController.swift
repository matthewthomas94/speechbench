import AVFoundation
import FluidAudio
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import VoiceGlowKit

/// Push-to-talk voice loop: Parakeet → Gemma → Kokoro. Gemma's reply is cut into sentences as it
/// streams, so Kokoro starts speaking while the rest of the reply is still being generated.
@MainActor
final class ConversationController: ObservableObject {
    enum State { case idle, listening, thinking, speaking }

    struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    static let modelConfig = LLMRegistry.gemma3_1B_qat_4bit
    static let instructions = """
        You are a friendly voice assistant running entirely on an iPhone. Reply in one to three short, \
        conversational sentences. Plain spoken English only: no markdown, lists, headings or emoji.
        """
    static let generateParameters = GenerateParameters(maxTokens: 200, temperature: 0.7)

    @Published private(set) var state: State = .idle
    @Published private(set) var llmPhase: ModelPhase = .unloaded
    @Published private(set) var llmProgress: String?
    @Published private(set) var messages: [Message] = []
    @Published private(set) var listeningSince: Date?
    @Published private(set) var errorMessage: String?

    private let tts: TTSController
    private let stt: STTController
    private let recorder = MicRecorder()
    private let player = SpeechPlayer()
    private var container: ModelContainer?
    private var session: ChatSession?
    private var turn: Task<Void, Never>?

    init(tts: TTSController, stt: STTController) {
        self.tts = tts
        self.stt = stt
    }

    /// The microphone, for the voice overlay's glow.
    var meter: VoiceMeter { recorder.meter }

    /// All three models are loaded, so a turn can run.
    var isReady: Bool { stt.phase.isLoaded && llmPhase.isLoaded && tts.phase.isLoaded }

    func loadAll() async {
        errorMessage = nil
        if stt.phase == .unloaded {
            await stt.load()
            if let e = stt.errorMessage { errorMessage = "Parakeet: \(e)"; return }
        }
        if llmPhase == .unloaded {
            await loadLLM()
            if errorMessage != nil { return }
        }
        if tts.phase == .unloaded {
            await tts.load()
            if let e = tts.errorMessage { errorMessage = "Kokoro: \(e)" }
        }
    }

    private func loadLLM() async {
        #if targetEnvironment(simulator)
        // MLX needs a real Metal GPU; touching it in the simulator aborts the app.
        errorMessage = "Gemma needs a real iPhone — MLX can't run in the simulator."
        return
        #endif
        llmPhase = .loading
        // Keep MLX's freed-buffer cache small so the footprint reflects what the model needs.
        // Kokoro relies on this too: uncapped, its cache grows ~1 GB a sentence and iOS kills the app.
        Memory.cacheLimit = 20 * 1024 * 1024
        do {
            let dir = try await HubDownloader().download(
                id: Self.modelConfig.name, revision: nil, matching: ["*.safetensors", "*.json", "*.jinja"],
                useLatest: false,
                progressHandler: { progress in
                    Task { @MainActor [weak self] in
                        self?.llmProgress = "Downloading Gemma · \(Int(progress.fractionCompleted * 100))%"
                    }
                })
            llmProgress = "Loading Gemma weights…"

            let container = try await LLMModelFactory.shared.loadContainer(
                from: HubDownloader(), using: TransformersTokenizerLoader(),
                configuration: ModelConfiguration(directory: dir, extraEOSTokens: Self.modelConfig.extraEOSTokens))
            self.container = container
            session = ChatSession(container, instructions: Self.instructions, generateParameters: Self.generateParameters)
            llmPhase = .ready
        } catch {
            errorMessage = "Gemma load failed: \(error.localizedDescription)"
            llmPhase = .unloaded
        }
        llmProgress = nil
    }

    /// Idle → start listening. Listening → send. Thinking/speaking → interrupt and listen (barge-in).
    func toggleTalk() async {
        if state == .listening {
            let raw = recorder.stop()
            listeningSince = nil
            state = .thinking
            turn = Task { await runTurn(raw) }
            return
        }
        interrupt()
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access denied — enable it in Settings › SpeechBench."
            return
        }
        do {
            try await recorder.start()
            listeningSince = Date()
            state = .listening
            errorMessage = nil
        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    func reset() {
        interrupt()
        if state == .listening {
            _ = recorder.stop()
            listeningSince = nil
            state = .idle
        }
        messages.removeAll()
        Task { await session?.clear() }
    }

    private func interrupt() {
        turn?.cancel()
        turn = nil
        player.stop()
        if state != .listening { state = .idle }
    }

    private func runTurn(_ raw: (samples: [Float], sampleRate: Double)) async {
        guard let session else { return }
        do {
            let samples16k = try AudioConverter().resample(raw.samples, from: raw.sampleRate)
            let heard = (try await stt.transcribeText(samples16k) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !heard.isEmpty else {
                errorMessage = "Didn't catch that — try again."
                state = .idle
                return
            }
            messages.append(Message(isUser: true, text: heard))
            messages.append(Message(isUser: false, text: ""))
            let reply = messages.count - 1

            let (sentences, sentenceSink) = AsyncStream.makeStream(of: String.self)
            async let spoken: Void = speak(sentences)

            var splitter = SentenceSplitter()
            for try await item in session.streamDetails(to: heard) {
                try Task.checkCancellation()
                switch item {
                case .chunk(let text):
                    messages[reply].text += text
                    for sentence in splitter.append(text) { sentenceSink.yield(sentence) }
                case .info, .toolCall:
                    break
                }
            }
            try Task.checkCancellation()
            if let rest = splitter.finish() { sentenceSink.yield(rest) }
            sentenceSink.finish()

            await spoken
            await player.waitUntilDrained()
            try Task.checkCancellation()
            player.stop()
            state = .idle
        } catch is CancellationError {
            // Interrupted by the user; `interrupt()` already reset the state.
        } catch {
            errorMessage = "Turn failed: \(error.localizedDescription)"
            player.stop()
            state = .idle
        }
    }

    /// Synthesizes each sentence as it arrives and queues it behind the previous one.
    private func speak(_ sentences: AsyncStream<String>) async {
        for await sentence in sentences {
            if Task.isCancelled { break }
            do {
                guard let audio = try await tts.synthesizeSamples(sentence), !Task.isCancelled else { continue }
                try player.enqueue(audio.samples, sampleRate: audio.sampleRate)
                if state == .thinking { state = .speaking }
            } catch {
                errorMessage = "Kokoro failed on “\(sentence)”: \(error.localizedDescription)"
            }
        }
    }
}

extension ModelPhase {
    var isLoaded: Bool { self == .ready || self == .busy }
}

/// Cuts streamed text into sentences as soon as each is complete, using relay-runner's
/// end-of-sentence rule, and strips what Kokoro shouldn't read aloud.
struct SentenceSplitter {
    private var buffer = ""

    mutating func append(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let match = buffer.firstMatch(of: #/[.!?]+["')\]]*\s+|\n+/#) {
            let end = match.range.upperBound
            if let s = Self.speakable(String(buffer[..<end])) { sentences.append(s) }
            buffer.removeSubrange(..<end)
        }
        return sentences
    }

    mutating func finish() -> String? {
        defer { buffer = "" }
        return Self.speakable(buffer)
    }

    static func speakable(_ text: String) -> String? {
        var s = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*(#+|[-+*]|\d+\.)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        s.unicodeScalars.removeAll { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.contains { $0.isLetter || $0.isNumber } ? s : nil
    }
}

/// Plays Kokoro chunks back-to-back through one player node so sentences join without gaps.
final class SpeechPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var connected = false
    private var generation = 0
    private var pending = 0
    private var drained: CheckedContinuation<Void, Never>?

    func enqueue(_ samples: [Float], sampleRate: Int) throws {
        guard !samples.isEmpty,
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        if !connected {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connected = true
        }
        if !engine.isRunning {
            // The mic meter deactivates the shared audio session when it stops.
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        }
        let gen = lock.withLock { pending += 1; return generation }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferFinished(gen)
        }
        if !node.isPlaying { node.play() }
    }

    /// Returns once everything queued so far has been heard, or `stop()` is called.
    func waitUntilDrained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock {
                if pending == 0 { return true }
                drained = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func stop() {
        let waiter = lock.withLock {
            generation += 1
            pending = 0
            defer { drained = nil }
            return drained
        }
        if connected {
            node.stop()
            engine.stop()
        }
        waiter?.resume()
    }

    private func bufferFinished(_ gen: Int) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard gen == generation else { return nil }
            pending -= 1
            guard pending == 0 else { return nil }
            defer { drained = nil }
            return drained
        }
        waiter?.resume()
    }
}
