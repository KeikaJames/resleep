import SwiftUI
import SleepKit

// MARK: - Apple-Intelligence-style border

/// Animated rainbow conic-gradient border, in the spirit of Apple
/// Intelligence's "siri" affordance. Wrap any view in `.appleIntelligenceBorder()`
/// to get a slowly rotating multicolor stroke.
struct AppleIntelligenceBorder: ViewModifier {
    var cornerRadius: CGFloat = 24
    var lineWidth: CGFloat = 2.5
    var animated: Bool = true

    @State private var rotation: Double = 0

    private var palette: [Color] {
        [.purple, .pink, .orange, .yellow, .mint, .cyan, .blue, .purple]
    }

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            gradient: Gradient(colors: palette),
                            center: .center,
                            angle: .degrees(rotation)
                        ),
                        lineWidth: lineWidth
                    )
                    .blur(radius: 0.4)
            )
            .onAppear {
                guard animated else { return }
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    func appleIntelligenceBorder(cornerRadius: CGFloat = 24,
                                 lineWidth: CGFloat = 2.5) -> some View {
        modifier(AppleIntelligenceBorder(cornerRadius: cornerRadius,
                                          lineWidth: lineWidth))
    }
}

// MARK: - Glow halo (used on the hero card)

private struct AIGlowHalo: View {
    @State private var pulse: CGFloat = 0.85

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.purple.opacity(0.55), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 90
                    )
                )
                .blur(radius: 20)
                .scaleEffect(pulse)
                .frame(width: 160, height: 160)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                pulse = 1.15
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Root view

struct SleepAIView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = SleepAIViewModel()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        heroCard

                        switch model.phase {
                        case .needsConsent:
                            consentCard
                        case .needsModel:
                            downloadCard
                        case .ready, .chatting:
                            summaryCard
                            chatCard(proxy: proxy)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Text("tab.ai"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                model.attach(appState: appState)
                await model.refreshContext()
            }
        }
    }

    // MARK: Sections

    private var heroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                AIGlowHalo()
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .pink, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        Color.white
                    )
            }
            .frame(height: 120)

            Text("ai.hero.title")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("ai.hero.subtitle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .appleIntelligenceBorder()
    }

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ai.consent.title", systemImage: "lock.shield.fill")
                .font(.headline)
            Text("ai.consent.body")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                bullet("ai.consent.bullet.onDevice")
                bullet("ai.consent.bullet.noUpload")
                bullet("ai.consent.bullet.optional")
            }

            Button {
                model.grantConsent()
            } label: {
                Text("ai.consent.cta")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("ai.download.title", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Spacer()
                Text("\(model.modelDescriptor.approximateMB) MB")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("ai.download.body")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.modelStatus {
            case .notInstalled, .failed:
                Button {
                    model.startDownload()
                } label: {
                    Text("ai.download.cta")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                if case .failed(let reason) = model.modelStatus {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

            case .downloading(let p):
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(.purple)
                HStack {
                    Text(String(format: "%.0f%%", p * 100))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("ai.download.cancel") { model.cancelDownload() }
                        .font(.footnote)
                }
            case .installed:
                EmptyView()
            }

            Text("ai.download.skip")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ai.summary.title", systemImage: "moon.stars.fill")
                .font(.headline)
            Text(model.summaryText)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .appleIntelligenceBorder(cornerRadius: 18, lineWidth: 1.4)
    }

    private func chatCard(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ai.chat.title", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.messages) { msg in
                    ChatBubble(message: msg)
                        .id(msg.id)
                }
                if model.isReplying {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("ai.chat.thinking")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .id("__thinking__")
                }
            }

            // Suggestions
            if !model.suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.suggestions, id: \.self) { s in
                            Button {
                                Task { await model.send(prompt: s) }
                            } label: {
                                Text(s)
                                    .font(.footnote)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule().fill(Color.purple.opacity(0.12))
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(Color.purple.opacity(0.4), lineWidth: 1)
                                    )
                                    .foregroundStyle(Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Composer
            HStack(spacing: 8) {
                TextField("ai.chat.placeholder", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button {
                    let text = model.draft
                    model.draft = ""
                    Task { await model.send(prompt: text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            LinearGradient(colors: [.purple, .pink],
                                           startPoint: .top, endPoint: .bottom)
                        )
                }
                .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isReplying)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .onChange(of: model.messages.count) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) {
                if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func bullet(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.purple)
            Text(key)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: SleepAIMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                Text(message.text)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.purple.opacity(0.10))
                    )
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: 320, alignment: .leading)
                Spacer(minLength: 16)
            } else {
                Spacer(minLength: 16)
                Text(message.text)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .font(.subheadline)
    }
}

// MARK: - Preview

#Preview {
    SleepAIView()
        .environmentObject(AppState.makeDefault())
}
