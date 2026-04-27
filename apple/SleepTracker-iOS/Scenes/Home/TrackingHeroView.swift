import SwiftUI
import SleepKit

/// Full-screen hero shown while a session is active. Inspired by the macOS
/// "Hello" boot screen and the system Sleep state: deep-night gradient,
/// large semibold display text that cross-fades through localized
/// "good night" greetings with a soft blur, and an ambient breathing glow
/// behind the text. The duration counter is isolated into its own
/// `TimelineView` so the parent never re-renders on the second.
struct TrackingHeroView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var model: HomeViewModel

    @State private var index: Int = 0
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

    private static let cycle: TimeInterval = 2.8
    private static let fade: Double = 1.0

    var body: some View {
        ZStack {
            // Deep nightfall — quiet, not flashy.
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.02, blue: 0.08),
                    Color(red: 0.07, green: 0.05, blue: 0.16),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            BreathingGlow()
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Text(Self.phrases[index])
                        .font(.system(size: 68, weight: .semibold, design: .default))
                        .tracking(isCJK(Self.phrases[index]) ? 2 : -0.8)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.white,
                                    Color(red: 0.92, green: 0.93, blue: 1.00)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity
                        ))
                }
                .frame(height: 96)

                LiveDurationLabel(start: appState.workout.sessionStartedAt)

                Spacer()

                Button {
                    Task { await model.toggleSession() }
                } label: {
                    Text("home.tracking.stop")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .onAppear { startRotation() }
        .onDisappear { stopRotation() }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Self.phrases[0]))
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
                index = (index + 1) % Self.phrases.count
            }
        }
    }

    private func stopRotation() {
        rotateTimer?.invalidate()
        rotateTimer = nil
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
                .foregroundStyle(.white.opacity(0.42))
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

// MARK: - Ambient glow

/// Slow breathing radial halo behind the greeting. Driven by `TimelineView
/// (.animation)` so it's frame-locked and stops automatically when off-screen.
private struct BreathingGlow: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 0.35) + 1) / 2 // 0…1
            let opacity = 0.18 + 0.10 * phase
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
            .blur(radius: 24)
            .allowsHitTesting(false)
        }
    }
}
