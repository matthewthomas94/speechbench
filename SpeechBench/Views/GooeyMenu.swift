import SwiftUI

/// SwiftUI port of the Libraries.dev Gooey menu (`liquid-gooey`), using the values tuned in the
/// Libraries.dev Studio. The blobs are blurred and alpha-thresholded so they merge like liquid; the
/// buttons are drawn on top, unblurred, with the same offsets and timing.
///
/// Choosing the mic docks it, a third bigger, at the bottom centre as the talk button. Home then
/// shrinks it back into the plus. While listening, the mic melts into a waveform that follows the voice.
struct GooeyMenu: View {
    /// The mic sits enlarged at the bottom centre as the talk button, and the menu only offers home.
    let docked: Bool
    let listening: Bool
    /// The microphone's RMS, 0 while it is off.
    let level: () -> Double
    let onHome: () -> Void
    let onMic: () -> Void
    let onTalk: () -> Void

    @State private var open = false

    private enum Item: CaseIterable { case home, mic, plus }

    private static let size: CGFloat = 48
    private static let dockedScale: CGFloat = 4 / 3
    /// From the bottom-right corner of the screen to the plus button's centre.
    private static let inset = CGSize(width: 26 + size / 2, height: 27 + size / 2)
    private static let ease = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.55)

    var body: some View {
        GeometryReader { geo in
            let anchor = CGPoint(x: geo.size.width - Self.inset.width, y: geo.size.height - Self.inset.height)
            let dock = CGSize(width: geo.size.width / 2 - anchor.x, height: 0)
            ZStack {
                // Dark liquid glass cut to the gooey shape: the blurred backdrop, a dark tint, and light
                // catching the top and bottom rims.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .mask(canvas(dock: dock) { ctx, _ in Self.goo(ctx, at: anchor, color: .white) })
                    .allowsHitTesting(false)
                canvas(dock: dock) { ctx, _ in
                    var tint = ctx
                    tint.opacity = 0.72
                    Self.goo(tint, at: anchor, color: .black)
                    Self.rim(ctx, at: anchor, shift: 1.5, opacity: 0.4)
                    Self.rim(ctx, at: anchor, shift: -1.5, opacity: 0.12)
                }

                Group {
                    button(.home, systemImage: "house.fill", dock: dock) { select(onHome) }
                    button(.mic, systemImage: "mic.fill", dock: dock) { docked ? onTalk() : select(onMic) }
                    button(.plus, systemImage: "plus", dock: dock) { open.toggle() }
                }
                .position(anchor)
            }
        }
    }

    /// A canvas whose symbols are the blobs, moving with the menu.
    private func canvas(dock: CGSize, renderer: @escaping (inout GraphicsContext, CGSize) -> Void) -> some View {
        Canvas(renderer: renderer) {
            ForEach(Item.allCases, id: \.self) { item in
                Circle()
                    .frame(width: Self.size, height: Self.size)
                    .scaleEffect(scale(item))
                    .offset(offset(item, dock: dock))
                    .animation(animation(item), value: open)
                    .animation(animation(item), value: docked)
                    .tag(item)
            }
        }
        .allowsHitTesting(false)
    }

    /// Fills the gooey shape, moved `shift` points down, in `color`.
    private static func goo(_ ctx: GraphicsContext, at anchor: CGPoint, color: Color, shift: CGFloat = 0) {
        var ctx = ctx
        // Filters apply last-added first: blur, then threshold the alpha back to a hard edge.
        ctx.addFilter(.alphaThreshold(min: 0.42, color: color))
        ctx.addFilter(.blur(radius: 6))
        ctx.drawLayer { layer in
            for item in Item.allCases {
                if let blob = ctx.resolveSymbol(id: item) { layer.draw(blob, at: CGPoint(x: anchor.x, y: anchor.y + shift)) }
            }
        }
    }

    /// Light along one edge of the gooey shape: the shape less itself moved `shift` points down.
    private static func rim(_ ctx: GraphicsContext, at anchor: CGPoint, shift: CGFloat, opacity: Double) {
        var ctx = ctx
        ctx.opacity = opacity
        ctx.drawLayer { edge in
            goo(edge, at: anchor, color: .white)
            var cut = edge
            cut.blendMode = .destinationOut
            goo(cut, at: anchor, color: .white, shift: shift)
        }
    }

    private func button(_ item: Item, systemImage: String, dock: CGSize, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if item == .mic {
                    TalkGlyph(wave: listening ? 1 : 0, level: level).animation(Self.ease, value: listening)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(item == .plus && open ? 45 : 0))
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(shown(item) ? 1 : 0)
        .allowsHitTesting(shown(item))
        .scaleEffect(scale(item))
        .offset(offset(item, dock: dock))
        .animation(animation(item), value: open)
        .animation(animation(item), value: docked)
    }

    private func select(_ action: () -> Void) {
        action()
        open = false
    }

    private func shown(_ item: Item) -> Bool {
        item == .plus || open || (item == .mic && docked)
    }

    private func scale(_ item: Item) -> CGFloat {
        item == .mic && docked ? Self.dockedScale : 1
    }

    private func offset(_ item: Item, dock: CGSize) -> CGSize {
        switch item {
        case .home:
            return open ? CGSize(width: 0, height: -64) : .zero
        case .mic:
            if docked { return dock }
            return open ? CGSize(width: -54, height: -34) : .zero
        case .plus:
            return .zero
        }
    }

    private func animation(_ item: Item) -> Animation {
        item == .home ? Self.ease.delay(0.04) : Self.ease
    }
}

/// The talk button's glyph: the mic, or the SF Symbols `waveform` drawn bar by bar so the bars can follow
/// the voice. Between the two, both pass through the menu's blur-and-threshold goo, so the mic melts into
/// the bars like liquid.
private struct TalkGlyph: View, Animatable {
    /// 0 is the mic, 1 the waveform.
    var wave: Double
    let level: () -> Double

    @State private var loudness = Loudness()

    var animatableData: Double {
        get { wave }
        set { wave = newValue }
    }

    /// The `waveform` symbol's bars at 18pt semibold, measured: width, pitch and heights.
    private static let bar: CGFloat = 1.7
    private static let pitch: CGFloat = 3.1
    private static let heights: [CGFloat] = [4.9, 12.3, 18.9, 9.9, 15.1, 6.6]

    var body: some View {
        if wave <= 0 {
            Image(systemName: "mic.fill")
        } else {
            TimelineView(.animation) { timeline in
                let loud = loudness.next(rms: level(), at: timeline.date)
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                    let melt = sin(.pi * min(wave, 1))
                    if melt > 0.01 {
                        // As in `GooeyMenu.goo`: blur, then threshold the alpha back to a hard edge.
                        ctx.addFilter(.alphaThreshold(min: 0.5, color: .white))
                        ctx.addFilter(.blur(radius: 2.5 * melt))
                    }
                    ctx.drawLayer { layer in
                        if wave < 1, let mic = layer.resolveSymbol(id: 0) {
                            var shrink = layer
                            shrink.opacity = 1 - wave
                            shrink.translateBy(x: centre.x, y: centre.y)
                            shrink.scaleBy(x: 1 - 0.4 * wave, y: 1 - 0.4 * wave)
                            shrink.draw(mic, at: .zero)
                        }
                        // Silence leaves short bars; a voice stretches them past the symbol's own heights.
                        for (i, height) in Self.heights.enumerated() {
                            let sway = 1 + 0.12 * (0.3 + loud) * sin(time * 7 + Double(i) * 1.9)
                            let gain = CGFloat((0.3 + 0.9 * loud) * sway)
                            let h = (Self.bar + (height - Self.bar) * gain) * wave
                            let w = Self.bar * min(wave, 1)
                            let x = centre.x + (CGFloat(i) - 2.5) * Self.pitch * wave
                            layer.fill(Capsule().path(in: CGRect(x: x - w / 2, y: centre.y - h / 2, width: w, height: h)), with: .color(.white))
                        }
                    }
                } symbols: {
                    Image(systemName: "mic.fill").tag(0)
                }
            }
        }
    }
}

/// The mic's RMS as 0–1 loudness over −55…−20 dB, rising fast and falling slowly so the bars don't flicker.
private final class Loudness {
    private var value = 0.0
    private var last: Date?

    func next(rms: Double, at date: Date) -> Double {
        let target = min(max((20 * log10(max(rms, 1e-6)) + 55) / 35, 0), 1)
        let dt = last.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        last = date
        value += (target - value) * (1 - exp(-(target > value ? 25 : 6) * dt))
        return value
    }
}
