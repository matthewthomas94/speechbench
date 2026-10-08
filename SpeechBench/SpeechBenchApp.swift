import AVFoundation
import SwiftUI

@main
struct SpeechBenchApp: App {
    @StateObject private var tts: TTSController
    @StateObject private var stt: STTController
    @StateObject private var conversation: ConversationController

    init() {
        let tts = TTSController(), stt = STTController()
        _tts = StateObject(wrappedValue: tts)
        _stt = StateObject(wrappedValue: stt)
        _conversation = StateObject(wrappedValue: ConversationController(tts: tts, stt: stt))

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tts)
                .environmentObject(stt)
                .environmentObject(conversation)
                // Load all three models up front so opening the voice screen never waits on them.
                .task { await conversation.loadAll() }
        }
    }
}
