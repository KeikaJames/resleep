import SwiftUI
import SleepKit

/// Full-screen hero shown while a session is active.
///
/// Design beats (top → bottom):
///  1. A **layered night sky**: deep indigo gradient + slow drifting aurora
///     + Canvas-driven twinkling starfield. Three independent
///     `TimelineView` animations, all frame-locked.
///  2. A **breathing moon glyph** (SF Symbol `moon.stars.fill`) that
///     floats gently and pulses, reusing the AppIcon brand language.
///  3. A **multilingual greeting rotator** that auto-shrinks to fit even
///     the longest Cyrillic / Spanish phrases on a 6.1" device — no more
///     truncation. Phrase transitions use a soft blur + lift.
///  4. A **live duration label** isolated in its own `TimelineView` so
///     the parent never invalidates each second.
///  5. A **hold-to-end** capsule with a fillable progress ring. Apple's
///     "consequential action" pattern (cf. unlock-with-passcode haptic
///     ramp). Single tap is intentionally not enough — accidental wakes
///     in the night shouldn't terminate the session.
struct TrackingHeroView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var model: HomeViewModel

    @State private var phraseIndex: Int = 0
    @State private var rotateTimer: Timer?

    /// Localized "sweet dreams" cycle. Mixed scripts give visual rhythm.
    private static let phrases: [String] = [
        "做个好梦",
        "Sweet dreams",
        "Buenas noches",
        "Bonne nuit",
        "おやすみ",
        "Gute Nacht",
        "잘 자요",
        "Dolci sogni",
        "Доброй ночи",
        "晚安"
    ]

    private static let cycle: TimeInterval = 3.2
    private static let fade: Double = 1.1

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 26) {
                Spacer(minLength: 0)
                MoonGlyph()
                phraseRotator
                LiveDurationLabel(start: appState.workout.sessionStartedAt)
                Spacer(minLength: 0)
                HoldToEndButton {
                    Task { await model.toggleSession() }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 36)
            }
        }
        .onAppear { startRotation() }
        .onDisappear { stopRotation() }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Self.phrases[0]))
    }

    // MARK: Backdrop layers

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.07),
                    Color(red: 0.06, green: 0.05, blue: 0.16),
                    Color(red: 0.02, green: 0.02, blue: 0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            AuroraLayer()
                .ignoresSafeArea()
                .blendMode(.screen)
                .opacity(0.85)

            StarfieldCanvas()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            BreathingGlow()
                .ignoresSafeArea()
        }
    }

    // MARK: Phrase rotator

    private var phraseRotator: some View {
        // Single Text with `.id(phraseIndex)` so SwiftUI treats each phrase as
        // a new view → transition fires. `minimumScaleFactor` rescues long
        // Latin / Cyrillic strings on narrow devices, so we never clip.
        Text(Self.phrases[phraseIndex])
            .font(.system(size: 60, weight: .semibold, design: .default))
            .tracking(isCJK(Self.phrases[phraseIndex]) ? 2 : -0.6)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.white,
                        Color(red: 0.92, green: 0.93, blue: 1.00).opacity(0.92)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .shadow(color: .white.opacity(0.06), radius: 18, y: 0)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .id(phraseIndex)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.97)),
                removal: .opacity.combined(with: .offset(y: -10))
            ))
    }

    private func isCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x3000...0x9FFF).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    private func startRotation() {
        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: Self.cycle, repeats: true) { _ in
            withAnimation(.easeInOut(duration: Self.fade)) {
                phraseIndex = (phraseIndex + 1) % Self.phrases.count
            }
        }
    }

    private func stopRotation() {
        rotateTimer?.invalidate()
        rotateTimer = nil
    }
}

// MARK: - Hold-to-end capsule

/// Apple-style "consequential action" control. Holding fills a ring around
/// the label; releasing early cancels and the ring drains. Completing the
/// hold fires a heavy haptic and triggers `onComplete`. Visually echoes
/// iOS Emergency SOS / unlock-with-Apple-Watch language.
private struct HoldToEndButton: View {
    let onComplete: () -> Void

    @State private var progress: CGFloat = 0
    @State private var isHolding: Bool = false
    @State private var holdTask: Task<Void, Never>?
    private static let duration: Double = 1.0

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .background(
                        Capsule().fill(.ultraThinMaterial)
                    )
                    .frame(height: 56)

                // Progress fill — radial gradient sweeps from leading to
                // trailing as the hold progresses. Subtle blur so the
                // animation reads as light, not as a loading bar.
                GeometryReader { geo in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.85, green: 0.40, blue: 0.40).opacity(0.55),
                                    Color(red: 0.95, green: 0.55, blue: 0.55).opacity(0.85)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * progress))
                        .frame(maxHeight: .infinity)
                        .blur(radius: 0.5)
                        .animation(.linear(duration: 0.06), value: progress)
                }
                .clipShape(Capsule())
                .frame(height: 56)
                .padding(2)

                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("home.tracking.stop")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
                .opacity(0.9 + 0.1 * Double(progress))
            }
            .scaleEffect(isHolding ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHolding)
            .gesture(
                LongPressGesture(minimumDuration: Self.duration)
                    .onChanged { _ in beginHold() }
                    .onEnded { _ in completeHold() }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHolding { beginHold() }
                    }
                    .onEnded { _ in
                        if progress < 1.0 { cancelHold() }
                    }
            )

            Text("home.tracking.holdHint")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(0.3)
        }
    }

    private func beginHold() {
        guard !isHolding else { return }
        isHolding = true
        Haptics.selection()
        holdTask?.cancel()
        let start = Date()
        holdTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                progress = CGFloat(min(1.0, elapsed / Self.duration))
                if progress >= 1.0 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func completeHold() {
        holdTask?.cancel()
        progress = 1.0
        isHolding = false
        Haptics.tapHeavy()
        Haptics.success()
        onComplete()
    }

    private func cancelHold() {
        holdTask?.cancel()
        isHolding = false
        withAnimation(.easeOut(duration: 0.35)) {
            progress = 0
        }
    }
}

// MARK: - Moon glyph

/// Brand glyph above the greeting. Uses the system `moon.stars.fill` with
/// a slow vertical float and a subtle `.symbolEffect(.pulse)`. Tinted in a
/// warm cream that echoes the AppIcon.
private struct MoonGlyph: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let float = sin(t * 0.55) * 4.0
            let opacity = 0.85 + 0.10 * sin(t * 0.7)

            Image(systemName: "moon.stars.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.94, blue: 0.84),
                            Color(red: 0.86, green: 0.82, blue: 0.74)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color(red: 0.95, green: 0.85, blue: 0.6).opacity(0.35),
                        radius: 18, y: 0)
                .offset(y: float)
                .opacity(opacity)
                .symbolEffect(.pulse, options: .repeating, value: 0)
                .accessibilityHidden(true)
        }
        .frame(height: 48)
    }
}

// MARK: - Live duration

/// Self-contained ticking label. Owns a `TimelineView` so the surrounding
/// hero never invalidates each second.
private struct LiveDurationLabel: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            Text(format(context.date))
                .font(.system(.title3, design: .monospaced).weight(.regular))
                .foregroundStyle(.white.opacity(0.46))
                .contentTransition(.numericText())
                .monospacedDigit()
        }
    }

    private func format(_ now: Date) -> String {
        guard let s = start else { return "00:00" }
        let total = max(0, Int(now.timeIntervalSince(s)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let ss = total % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, ss)
            : String(format: "%02d:%02d", m, ss)
    }
}

// MARK: - Ambient breathing glow

private struct BreathingGlow: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 0.32) + 1) / 2
            let opacity = 0.16 + 0.10 * phase
            let scale = 0.92 + 0.10 * phase

            RadialGradient(
                colors: [
                    Color(red: 0.45, green: 0.40, blue: 0.85).opacity(opacity),
                    Color.clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 360
            )
            .scaleEffect(scale)
            .blur(radius: 28)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Aurora drift

/// Two large radial gradients that slowly orbit around the canvas at
/// different rates. Combined with `.blendMode(.screen)` on the parent,
/// they read as a faint aurora — never demanding, just alive.
private struct AuroraLayer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let p1 = unitPos(t: t, freqX: 0.06, freqY: 0.045, phaseX: 0.0, phaseY: 1.2)
                let p2 = unitPos(t: t, freqX: 0.04, freqY: 0.07, phaseX: 2.4, phaseY: 0.6)

                ZStack {
                    RadialGradient(
                        colors: [
                            Color(red: 0.30, green: 0.45, blue: 0.95).opacity(0.30),
                            .clear
                        ],
                        center: UnitPoint(x: p1.x, y: p1.y),
                        startRadius: 0,
                        endRadius: max(w, h) * 0.55
                    )
                    .blur(radius: 60)

                    RadialGradient(
                        colors: [
                            Color(red: 0.62, green: 0.32, blue: 0.85).opacity(0.28),
                            .clear
                        ],
                        center: UnitPoint(x: p2.x, y: p2.y),
                        startRadius: 0,
                        endRadius: max(w, h) * 0.50
                    )
                    .blur(radius: 70)
                }
            }
        }
    }

    private func unitPos(t: TimeInterval, freqX: Double, freqY: Double,
                         phaseX: Double, phaseY: Double) -> CGPoint {
        let x = 0.5 + 0.32 * sin(t * freqX + phaseX)
        let y = 0.5 + 0.30 * cos(t * freqY + phaseY)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Starfield

/// Deterministic twinkling starfield rendered into a `Canvas` so it costs
/// roughly nothing per frame. The 60 star positions are seeded once with
/// a fixed RNG so they never jitter; only their brightness sin-cycles.
private struct StarfieldCanvas: View {
    private struct Star { let x: Double; let y: Double; let r: Double; let phase: Double; let speed: Double }

    private static let stars: [Star] = {
        var rng = SystemRNG(seed: 0xC0FFEE)
        return (0..<70).map { _ in
            Star(
                x: rng.next(),
                y: rng.next() * 0.85, // bias upward so the lower 15% is calm
                r: 0.5 + rng.next() * 1.6,
                phase: rng.next() * .pi * 2,
                speed: 0.4 + rng.next() * 1.2
            )
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for s in Self.stars {
                    let twinkle = (sin(t * s.speed + s.phase) + 1) / 2
                    let alpha = 0.18 + 0.55 * twinkle
                    let cx = s.x * size.width
                    let cy = s.y * size.height
                    let r = s.r * (0.85 + 0.35 * twinkle)
                    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                    let path = Path(ellipseIn: rect)
                    context.fill(
                        path,
                        with: .color(Color.white.opacity(alpha))
                    )
                    if s.r > 1.6 {
                        // Big stars get a faint halo
                        let halo = CGRect(x: cx - r * 3, y: cy - r * 3, width: r * 6, height: r * 6)
                        context.fill(
                            Path(ellipseIn: halo),
                            with: .color(Color.white.opacity(alpha * 0.06))
                        )
                    }
                }
            }
        }
    }
}

/// Tiny xorshift RNG so the starfield is stable across launches.
private struct SystemRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEF : seed }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000.0
    }
}
