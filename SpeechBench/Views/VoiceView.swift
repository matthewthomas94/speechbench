import SwiftUI
import ThinkingOrbsKit
import VoiceGlowKit

/// The voice overlay. The docked mic in `GooeyMenu` talks to Gemma; the orb shows what it's doing.
struct VoiceView: View {
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var stt: STTController
    @EnvironmentObject private var tts: TTSController

    /// Searching while waiting for the user, listening while they talk, solving while Gemma
    /// works on and speaks the reply.
    private var orb: OrbState {
        switch conversation.state {
        case .idle: .searching
        case .listening: .listening
        case .thinking, .speaking: .solving
        }
    }

    private var status: String {
        switch conversation.state {
        case .idle: "How can I help?"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: "Replying…"
        }
    }

    private var caption: String? {
        if let error = conversation.errorMessage { return error }
        if conversation.isReady { return nil }
        return stt.progressText ?? conversation.llmProgress
            ?? (tts.phase == .loading ? "Loading Kokoro…" : "Loading models…")
    }

    /// The Libraries.dev voice glow's mono palette, with its custom colours and mid band.
    private static let glow: VoiceGlowOptions = {
        var options = VoiceGlowOptions()
        options.colors = ["#508cff", "#3cbeff", "#bef0ff", "#78beff", "#a0dcfa", "#3c6eff", "#c8ebff"]
            .compactMap(VoiceGlowColor.init(hex:))
        options.bandColors.mid = VoiceGlowColor(hex: "#7ec4ff")
        return options
    }()

    var body: some View {
        // The glow rises from the bottom edge of the screen, following the mic while the user talks.
        VoiceGlow(
            type: .mobile, meter: conversation.meter, colorVariant: .mono, theme: .dark, cornerRadius: 55,
            options: Self.glow
        ) {
            content
        }
        .ignoresSafeArea()
    }

    private var content: some View {
        ZStack {
            // Figma's tint: slate blue from far above the screen fading to near-black, at 95% so the
            // blurred home screen shows through at about 5%. `RootView` blurs the home screen itself.
            LinearGradient(
                colors: [Color(red: 70 / 255, green: 82 / 255, blue: 123 / 255), Color(hex: 0x0C0E15)],
                startPoint: UnitPoint(x: 0.5, y: -3.868), endPoint: .bottom
            )
            .opacity(0.95)
            // The 64pt design drawn at 140pt; all orbs share one clock, so the crossfade is seamless.
            // Figma puts the orb 75pt above centre and its status 82pt below.
            ThinkingOrb(state: orb, size: .px64, theme: .dark, speed: 0.5, displaySize: 140)
                .id(orb)
                .transition(.opacity)
                .offset(y: -75)
            Text(status)
                .font(.custom("Helvetica Neue", size: 20))
                .foregroundStyle(.white)
                .id(status)
                .transition(.opacity)
                .offset(y: 82)
            if let caption {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .offset(y: 120)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: conversation.state)
    }
}
