import SwiftUI

/// The home screen, with the voice overlay opened and closed by the gooey menu in place of a tab bar.
struct RootView: View {
    @EnvironmentObject private var conversation: ConversationController
    @State private var voice = false

    var body: some View {
        ZStack {
            // Behind the blur so its soft edges fade into the page colour rather than a hard line.
            HomeView.background.ignoresSafeArea()
            HomeView()
                .blur(radius: voice ? 8 : 0)
            if voice { VoiceView().transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.25), value: voice)
        .overlay {
            GooeyMenu(
                docked: voice, listening: conversation.state == .listening, level: conversation.meter.currentRMS,
                onHome: { voice = false }, onMic: { voice = true }, onTalk: talk)
                .ignoresSafeArea()
        }
    }

    private func talk() {
        guard conversation.isReady else { return }
        Task { await conversation.toggleTalk() }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
