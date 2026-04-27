import SwiftUI
import SleepKit

/// Full-screen "good night" hero shown while a session is active. Mirrors
/// the Apple `Hello` boot screen: large semibold display text that cycles
/// through localized greetings with a soft cross-fade. Forced-dark.
struct TrackingHeroView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var model: HomeViewModel

    @State private var index: Int = 0
    @State private var elapsed: TimeInterval = 0
    @State private var tickTimer: Timer?
    @State private var rotateTimer: Timer?

    /// Localized, multi-language "sweet dreams" cycle. Order picked for
    /// visual rhythm — short / long / accent / Latin / CJK.
    private let phrases: [String] = [
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

    var body: some View {
        ZStack {
            // Deep nightfall gradient — quiet, not flashy.
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.03, blue: 0.10),
                    Color(red: 0.10, green: 0.07, blue: 0.20),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Text(phrases[index])
                    .font(.system(size: 56, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .id(index) // force transition on change
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                Text(durationLabel)
                    .font(.system(.title3, design: .monospaced).weight(.regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .contentTransition(.numericText())

                Spacer()

                Button {
                    Task { await model.toggleSession() }
                } label: {
                    Text("home.tracking.stop")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.10))
                .foregroundStyle(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .padding(.horizontal, 28)
                .padding(.bottom, 36)
            }
        }
        .onAppear { startTimers() }
        .onDisappear { stopTimers() }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(phrases[0]))
    }

    private var durationLabel: String {
        guard let started = appState.workout.sessionStartedAt else { return "00:00" }
        let s = Int(Date().timeIntervalSince(started))
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, ss)
            : String(format: "%02d:%02d", m, ss)
    }

    private func startTimers() {
        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.9)) {
                index = (index + 1) % phrases.count
            }
        }
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsed += 1 // triggers a redraw via the binding chain
        }
    }

    private func stopTimers() {
        rotateTimer?.invalidate(); rotateTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
    }
}
