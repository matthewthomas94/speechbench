import AVFoundation
import SwiftUI

@main
struct SpeechBenchApp: App {
    @StateObject private var telemetry = TelemetryMonitor()
    @StateObject private var tts = TTSController()
    @StateObject private var stt = STTController()

    init() {
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
                TelemetryView()
                    .tabItem { Label("Telemetry", systemImage: "gauge.with.dots.needle.67percent") }
            }
            .environmentObject(telemetry)
            .environmentObject(tts)
            .environmentObject(stt)
            .onAppear { telemetry.start() }
        }
    }
}
