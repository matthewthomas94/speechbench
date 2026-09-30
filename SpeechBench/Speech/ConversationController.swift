import AVFoundation
import FluidAudio
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Push-to-talk voice loop: Parakeet → Gemma → Kokoro. Gemma's reply is cut into sentences as it
/// streams, so Kokoro starts speaking while the rest of the reply is still being generated.
@MainActor
final class ConversationController: ObservableObject {
    enum State { case idle, listening, thinking, speaking }

    struct Metrics {
        let heardSeconds: Double
        let sttSeconds: Double
        let promptTokens: Int
        let generatedTokens: Int
        /// From sending the prompt to Gemma's first text chunk (includes prefill).
        let timeToFirstToken: Double?
        let tokensPerSecond: Double
        let firstSentenceSynthSeconds: Double?
        /// From tapping "send" to the first reply audio being queued for playback.
        let toFirstAudio: Double?
        /// Answered from the status report in a one-off exchange, without chat history.
        let usedStatus: Bool
        let cost: RunCost
    }

    struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        var text: String
        var metrics: Metrics?
    }

    static let modelConfig = LLMRegistry.gemma3_1B_qat_4bit
    static let instructions = """
        You are a friendly voice assistant running entirely on an iPhone. Reply in one to three short, \
        conversational sentences. Plain spoken English only: no markdown, lists, headings or emoji.
        """
    /// For questions about the app itself. These run without chat history: with earlier status
    /// reports in context, Gemma 3 1B repeats old answers instead of reading the new numbers.
    static let statusInstructions = """
        You are Gemma 3 1B, the voice assistant inside SpeechBench, an iPhone app that benchmarks \
        on-device speech models. The status report above the question describes the user's phone and \
        this app. Answer only what was asked, using its numbers; never make up numbers. Reply in one or \
        two short spoken sentences, without markdown or emoji.
        """
    static let generateParameters = GenerateParameters(maxTokens: 200, temperature: 0.7)

    @Published private(set) var state: State = .idle
    @Published private(set) var llmPhase: ModelPhase = .unloaded
    @Published private(set) var llmProgress: String?
    @Published private(set) var llmLoadInfo: LoadInfo?
    @Published private(set) var messages: [Message] = []
    @Published private(set) var listeningSince: Date?
    @Published private(set) var errorMessage: String?

    private let tts: TTSController
    private let stt: STTController
    private let telemetry: TelemetryMonitor
    private let recorder = MicRecorder()
    private let player = SpeechPlayer()
    private var container: ModelContainer?
    private var session: ChatSession?
    private var turn: Task<Void, Never>?

    init(tts: TTSController, stt: STTController, telemetry: TelemetryMonitor) {
        self.tts = tts
        self.stt = stt
        self.telemetry = telemetry
    }

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
        llmPhase = .loading
        // Keep MLX's freed-buffer cache small so the footprint reflects what the model needs.
        Memory.cacheLimit = 20 * 1024 * 1024
        do {
            let downloadStart = ProcessInfo.processInfo.systemUptime
            let dir = try await HubDownloader().download(
                id: Self.modelConfig.name, revision: nil, matching: ["*.safetensors", "*.json", "*.jinja"],
                useLatest: false,
                progressHandler: { progress in
                    Task { @MainActor [weak self] in
                        self?.llmProgress = "Downloading Gemma · \(Int(progress.fractionCompleted * 100))%"
                    }
                })
            let downloadSeconds = ProcessInfo.processInfo.systemUptime - downloadStart
            llmProgress = "Loading Gemma weights…"

            let meter = RunMeter()
            let container = try await LLMModelFactory.shared.loadContainer(
                from: HubDownloader(), using: TransformersTokenizerLoader(),
                configuration: ModelConfiguration(directory: dir, extraEOSTokens: Self.modelConfig.extraEOSTokens))
            self.container = container
            session = ChatSession(container, instructions: Self.instructions, generateParameters: Self.generateParameters)
            llmLoadInfo = LoadInfo(
                label: "Gemma 3 1B · 4-bit QAT · MLX (GPU)", downloadSeconds: downloadSeconds, cost: meter.finish(),
                footprintAfterMB: SystemMetrics.processFootprintBytes().map { Double($0) / 1_048_576 })
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
            try recorder.start()
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
        guard let container, let session else { return }
        let start = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - start }
        let meter = RunMeter()
        do {
            let samples16k = try AudioConverter().resample(raw.samples, from: raw.sampleRate)
            let heard = (try await stt.transcribeText(samples16k) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sttSeconds = elapsed()
            try Task.checkCancellation()
            guard !heard.isEmpty else {
                errorMessage = "Didn't catch that — try again."
                state = .idle
                return
            }
            let usedStatus = Self.isAboutStatus(heard)
            let chat = usedStatus
                ? ChatSession(container, instructions: Self.statusInstructions, generateParameters: Self.generateParameters)
                : session
            let prompt = usedStatus ? statusSnapshot() + "\n\nQuestion: " + heard : heard
            messages.append(Message(isUser: true, text: heard))
            messages.append(Message(isUser: false, text: ""))
            let reply = messages.count - 1

            let (sentences, sentenceSink) = AsyncStream.makeStream(of: String.self)
            async let spoken = speak(sentences, turnStart: start)

            let llmStart = ProcessInfo.processInfo.systemUptime
            var firstToken: Double?
            var info: GenerateCompletionInfo?
            var splitter = SentenceSplitter()
            for try await item in chat.streamDetails(to: prompt) {
                try Task.checkCancellation()
                switch item {
                case .chunk(let text):
                    if firstToken == nil { firstToken = ProcessInfo.processInfo.systemUptime - llmStart }
                    messages[reply].text += text
                    for sentence in splitter.append(text) { sentenceSink.yield(sentence) }
                case .info(let i):
                    info = i
                case .toolCall:
                    break
                }
            }
            try Task.checkCancellation()
            if let rest = splitter.finish() { sentenceSink.yield(rest) }
            sentenceSink.finish()

            let (toFirstAudio, firstSynth) = await spoken
            let cost = meter.finish()  // compute only; excludes waiting for playback to end
            await player.waitUntilDrained()
            try Task.checkCancellation()
            player.stop()

            messages[reply].metrics = Metrics(
                heardSeconds: Double(samples16k.count) / 16_000, sttSeconds: sttSeconds,
                promptTokens: info?.promptTokenCount ?? 0, generatedTokens: info?.generationTokenCount ?? 0,
                timeToFirstToken: firstToken, tokensPerSecond: info?.tokensPerSecond ?? 0,
                firstSentenceSynthSeconds: firstSynth, toFirstAudio: toFirstAudio, usedStatus: usedStatus, cost: cost)
            state = .idle
        } catch is CancellationError {
            // Interrupted by the user; `interrupt()` already reset the state.
        } catch {
            errorMessage = "Turn failed: \(error.localizedDescription)"
            player.stop()
            state = .idle
        }
    }

    /// Questions about the app itself get the status report; everything else is plain chat.
    static func isAboutStatus(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["speech recognition", "last reply", "last answer"].contains(where: lower.contains) { return true }
        return lower.split { !$0.isLetter }.contains { word in statusWordPrefixes.contains { word.hasPrefix($0) } }
    }

    private static let statusWordPrefixes = [
        "model", "parakeet", "kokoro", "gemma", "transcri", "memory", "ram", "megabyte", "gigabyte", "cpu",
        "processor", "core", "power", "watt", "energy", "battery", "charg", "hot", "heat", "warm", "temperature",
        "thermal", "fast", "slow", "speed", "latency", "load", "token", "performance", "benchmark", "telemetry",
        "status", "stats",
    ]

    /// Models and live telemetry as plain text, for questions about them. Kept short because Gemma
    /// has to read it before answering, with units spelled out so Kokoro reads them naturally.
    private func statusSnapshot() -> String {
        func whole(_ v: Double?, _ unit: String) -> String { v.map { "\(Int($0.rounded())) \(unit)" } ?? "unknown" }
        func ms(_ s: Double?) -> String { whole(s.map { $0 * 1000 }, "milliseconds") }
        func secs(_ s: Double?) -> String { s.map { String(format: "%.1f seconds", $0) } ?? "unknown" }

        let s = telemetry.latest
        let stt = (self.stt.loadedLabel ?? "Parakeet").replacingOccurrences(of: " · ", with: ", ")
        let heat = switch telemetry.thermalState {
        case .nominal: "cool"
        case .fair: "slightly warm"
        case .serious: "hot"
        case .critical: "very hot"
        @unknown default: "unknown"
        }
        let battery = telemetry.batteryLevel < 0 ? "unknown" : "\(Int(telemetry.batteryLevel * 100)) percent, \(telemetry.batteryState.label.lowercased())"
        var lines = [
            "[Status]",
            "Models: speech recognition \(stt); you are Gemma 3 1B 4-bit on the GPU; voice Kokoro 82M, Puck, \(tts.loadedCompute?.rawValue ?? "unknown").",
            "Load times: Parakeet took \(secs(self.stt.loadInfo?.cost.wallSeconds)), Gemma took \(secs(llmLoadInfo?.cost.wallSeconds)), Kokoro took \(secs(tts.loadInfo?.cost.wallSeconds)).",
            "Memory: app \(whole(s?.footprintMB, "megabytes")), peak \(whole(telemetry.sessionPeakMB, "megabytes")), headroom \(whole(s?.availableMB, "megabytes")).",
            "CPU: app \(whole(s?.appCPU, "percent")), whole phone \(whole(s?.systemCPU, "percent")), app CPU power \(s?.appPowerW.map { String(format: "%.2f watts", $0) } ?? "unknown").",
            "Heat: the phone is \(heat) (thermal state \(telemetry.thermalState.label.lowercased())). Battery \(battery).",
        ]
        if let m = messages.last(where: { $0.metrics != nil })?.metrics {
            lines.append("Last reply speed: \(secs(m.toFirstAudio)) until your voice started.")
            lines.append(
                "Last reply details: speech recognition \(ms(m.sttSeconds)), your first word \(secs(m.timeToFirstToken)), \(whole(m.tokensPerSecond, "tokens per second")), voice synthesis \(ms(m.firstSentenceSynthSeconds)).")
        }
        return lines.joined(separator: "\n")
    }

    /// Synthesizes each sentence as it arrives and queues it behind the previous one.
    private func speak(_ sentences: AsyncStream<String>, turnStart: TimeInterval) async -> (Double?, Double?) {
        var toFirstAudio: Double?, firstSynth: Double?
        for await sentence in sentences {
            if Task.isCancelled { break }
            let synthStart = ProcessInfo.processInfo.systemUptime
            do {
                guard let audio = try await tts.synthesizeSamples(sentence), !Task.isCancelled else { continue }
                if firstSynth == nil { firstSynth = ProcessInfo.processInfo.systemUptime - synthStart }
                try player.enqueue(audio.samples, sampleRate: audio.sampleRate)
                if toFirstAudio == nil {
                    toFirstAudio = ProcessInfo.processInfo.systemUptime - turnStart
                    state = .speaking
                }
            } catch {
                errorMessage = "Kokoro failed on “\(sentence)”: \(error.localizedDescription)"
            }
        }
        return (toFirstAudio, firstSynth)
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
        if !engine.isRunning { try engine.start() }
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
