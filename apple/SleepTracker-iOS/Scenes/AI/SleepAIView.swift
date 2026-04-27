import SwiftUI
import SleepKit

// MARK: - Apple Intelligence shimmer / border atoms

/// Animated multi-color stroke. Used sparingly — only on the composer pill
/// and the small "Sleep AI" pill on the consent sheet.
struct AppleIntelligenceStroke: ViewModifier {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat = 1.5

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
            )
            .onAppear {
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    func appleIntelligenceStroke(cornerRadius: CGFloat,
                                 lineWidth: CGFloat = 1.5) -> some View {
        modifier(AppleIntelligenceStroke(cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

/// A drifting rainbow gradient text fill — the "Apple Intelligence look".
/// Used for the hero greeting word + the prompt.
struct ShimmerText: ViewModifier {
    @State private var offset: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color.purple, Color.pink, Color.orange,
                        Color.yellow, Color.cyan, Color.blue, Color.purple
                    ],
                    startPoint: UnitPoint(x: offset, y: 0.5),
                    endPoint: UnitPoint(x: offset + 1, y: 0.5)
                )
            )
            .onAppear {
                withAnimation(.linear(duration: 5).repeatForever(autoreverses: true)) {
                    offset = 1
                }
            }
    }
}

extension View {
    func aiShimmer() -> some View { modifier(ShimmerText()) }
}

// MARK: - Root view

struct SleepAIView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = SleepAIViewModel()
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                switch model.phase {
                case .needsConsent:
                    consent
                case .needsModel, .ready, .chatting:
                    main
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Sleep AI")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if case .chatting = model.phase {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.easeInOut) { model.resetChat() }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.body)
                        }
                        .accessibilityLabel(Text("ai.consent.cta"))
                    }
                }
            }
            .task {
                model.attach(appState: appState)
                await model.refreshContext()
            }
        }
    }

    // MARK: Main scene (idle + chat)

    private var main: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 28) {
                        if model.messages.isEmpty {
                            heroHeader
                                .padding(.top, 40)
                                .padding(.horizontal, 24)
                            suggestionsGrid
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(model.messages) { msg in
                                    ChatBubble(message: msg)
                                        .id(msg.id)
                                        .transition(.asymmetric(
                                            insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity
                                        ))
                                }
                                if model.isReplying {
                                    ThinkingDots()
                                        .id("__thinking__")
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            composer
        }
    }

    // MARK: Hero

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(model.timeBasedGreetingKey))
                .font(.system(size: 36, weight: .semibold, design: .default))
                .foregroundStyle(.primary)
            Text("ai.hero.prompt")
                .font(.system(size: 36, weight: .semibold, design: .default))
                .aiShimmer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Suggestions

    private var suggestionsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(Array(model.suggestionCards.enumerated()), id: \.offset) { _, card in
                Button {
                    Task { await model.send(prompt: card.text) }
                } label: {
                    SuggestionCard(card: card)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField(text: $model.draft, axis: .vertical) {
                    Text("ai.chat.placeholder")
                }
                .focused($composerFocused)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit {
                    submit()
                }
                if !model.draft.isEmpty {
                    Button {
                        submit()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color(.systemBackground))
                            .padding(7)
                            .background(Circle().fill(Color.primary))
                    }
                    .disabled(model.isReplying)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .appleIntelligenceStroke(cornerRadius: 22, lineWidth: 1.2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color(.systemGroupedBackground)
                .overlay(Divider(), alignment: .top)
        )
    }

    private func submit() {
        let text = model.draft
        model.draft = ""
        Task { await model.send(prompt: text) }
    }

    // MARK: Consent (first launch)

    private var consent: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .semibold))
                    .aiShimmer()
                Text("ai.consent.title")
                    .font(.title2.weight(.semibold))
                Text("ai.consent.body")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut) { model.grantConsent() }
            } label: {
                Text("ai.consent.cta")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .foregroundStyle(Color(.systemBackground))
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}

// MARK: - Suggestion card

private struct SuggestionCard: View {
    let card: SleepAIViewModel.SuggestionCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: card.symbol)
                .font(.title3)
                .foregroundStyle(card.tint)
            Text(card.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Chat bubble + thinking

private struct ChatBubble: View {
    let message: SleepAIMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .assistant {
                Text(message.text)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .frame(maxWidth: 320, alignment: .leading)
                Spacer(minLength: 32)
            } else {
                Spacer(minLength: 32)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(Color(.systemBackground))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary)
                    )
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
    }
}

private struct ThinkingDots: View {
    @State private var phase: Int = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1.0 : 0.35)
                    .animation(.easeInOut(duration: 0.25), value: phase)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .accessibilityLabel(Text("ai.chat.thinking"))
    }
}

#Preview {
    SleepAIView()
        .environmentObject(AppState.makeDefault())
}
