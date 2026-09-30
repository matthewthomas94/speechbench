import AVFoundation
import SwiftUI

@main
struct SpeechBenchApp: App {
    @StateObject private var telemetry: TelemetryMonitor
    @StateObject private var tts: TTSController
    @StateObject private var stt: STTController
    @StateObject private var conversation: ConversationController

    init() {
        let telemetry = TelemetryMonitor(), tts = TTSController(), stt = STTController()
        _telemetry = StateObject(wrappedValue: telemetry)
        _tts = StateObject(wrappedValue: tts)
        _stt = StateObject(wrappedValue: stt)
        _conversation = StateObject(wrappedValue: ConversationController(tts: tts, stt: stt, telemetry: telemetry))

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                TTSView()
                    .tabItem { Label("Kokoro TTS", systemImage: "waveform") }
                STTView()
                    .tabItem { Label("Parakeet STT", systemImage: "mic") }
                ConversationView()
                    .tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }
                TelemetryView()
                    .tabItem { Label("Telemetry", systemImage: "gauge.with.dots.needle.67percent") }
            }
            .environmentObject(telemetry)
            .environmentObject(tts)
            .environmentObject(stt)
            .environmentObject(conversation)
            .onAppear { telemetry.start() }
        }
    }
}
