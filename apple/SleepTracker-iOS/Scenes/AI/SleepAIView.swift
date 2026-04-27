import SwiftUI
import SleepKit

// MARK: - Apple Intelligence atoms

/// Animated multi‑color stroke. Used on the composer pill and consent UI.
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

/// Drifting gradient text fill. Used for the prompt headline.
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

/// Full‑screen rotating rainbow border that lives at the device's edge.
/// Quietly visible behind the navigation chrome — signals "Apple Intelligence
/// is on" without taking focus.
private struct RainbowEdgeOverlay: View {
    @State private var rotation: Double = 0

    var body: some View {
        GeometryReader { geo in
            let r = max(min(geo.size.width, geo.size.height) * 0.18, 38)
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            .purple, .pink, .orange, .yellow,
                            .mint, .cyan, .blue, .purple
                        ]),
                        center: .center,
                        angle: .degrees(rotation)
                    ),
                    lineWidth: 2.5
                )
                .blur(radius: 0.4)
                .opacity(0.85)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Root view

struct SleepAIView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = SleepAIViewModel()
    @FocusState private var composerFocused: Bool
    @State private var historyOpen: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                switch model.phase {
                case .needsEULA:
                    eulaScreen
                case .ready, .chatting:
                    main
                }

                // Rainbow marquee — only when actually using the assistant.
                if model.phase != .needsEULA {
                    RainbowEdgeOverlay()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task {
                model.attach(appState: appState)
                await model.refreshContext()
            }
            .sheet(isPresented: $historyOpen) {
                HistorySheet(model: model, isPresented: $historyOpen)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.phase != .needsEULA {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    historyOpen = true
                } label: {
                    HamburgerIcon()
                }
                .accessibilityLabel(Text("ai.toolbar.history"))
            }
            ToolbarItem(placement: .principal) {
                Text("Sleep AI")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut) { model.startNewChat() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                }
                .accessibilityLabel(Text("ai.toolbar.newChat"))
            }
        }
    }

    // MARK: Main scene

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
                                    ThinkingDots().id("__thinking__")
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
            disclaimer
            composer
        }
    }

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

    private var suggestionsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(Array(model.suggestionCards.enumerated()), id: \.offset) { _, card in
                Button {
                    composerFocused = false
                    Task { await model.send(prompt: card.text) }
                } label: {
                    SuggestionCard(card: card)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Disclaimer + composer

    private var disclaimer: some View {
        Text("ai.disclaimer.short")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField(text: $model.draft, axis: .vertical) {
                    Text("ai.chat.placeholder")
                }
                .focused($composerFocused)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit { submit() }

                if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { submit() } label: {
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
        .padding(.bottom, 10)
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

    // MARK: EULA gate

    private var eulaScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .semibold))
                    .aiShimmer()
                Text("ai.eula.title")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)

            ScrollView {
                Text(markdown(model.eulaMarkdown()))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                    .textSelection(.enabled)
            }

            VStack(spacing: 10) {
                Text("ai.eula.short")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    withAnimation(.easeInOut) { model.acceptEULA() }
                } label: {
                    Text("ai.eula.accept")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
    }

    private func markdown(_ raw: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attr
        }
        return AttributedString(raw)
    }
}

// MARK: - Hamburger icon (varied bar lengths)

private struct HamburgerIcon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            bar(width: 18)
            bar(width: 13)
            bar(width: 16)
        }
        .frame(width: 22, height: 22, alignment: .leading)
    }

    private func bar(width: CGFloat) -> some View {
        Capsule()
            .frame(width: width, height: 2)
            .foregroundStyle(.primary)
    }
}

// MARK: - History sheet

private struct HistorySheet: View {
    @ObservedObject var model: SleepAIViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("ai.history.empty")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(grouped, id: \.key) { section in
                            Section(section.key) {
                                ForEach(section.value) { chat in
                                    Button {
                                        model.openChat(chat)
                                        isPresented = false
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(chat.title)
                                                    .font(.body)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(chat.createdAt, format: .dateTime.hour().minute())
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            model.deleteChat(chat)
                                        } label: {
                                            Label("ai.history.delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("ai.history.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("settings.localData.confirmCancel") {
                        isPresented = false
                    }
                }
                if !model.history.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            model.clearAllHistory()
                            isPresented = false
                        } label: {
                            Label("ai.history.clearAll", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var grouped: [(key: String, value: [StoredChat])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today

        var todayList: [StoredChat] = []
        var yLst: [StoredChat] = []
        var earlier: [StoredChat] = []

        for c in model.history {
            let day = cal.startOfDay(for: c.createdAt)
            if day == today { todayList.append(c) }
            else if day == yesterday { yLst.append(c) }
            else { earlier.append(c) }
        }

        var out: [(String, [StoredChat])] = []
        if !todayList.isEmpty { out.append((NSLocalizedString("ai.history.today", comment: ""), todayList)) }
        if !yLst.isEmpty { out.append((NSLocalizedString("ai.history.yesterday", comment: ""), yLst)) }
        if !earlier.isEmpty { out.append((NSLocalizedString("ai.history.title", comment: ""), earlier)) }
        return out
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

// MARK: - Chat bubble (markdown) + thinking

private struct ChatBubble: View {
    let message: SleepAIMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .assistant {
                bubble
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

    private var bubble: some View {
        Text(rendered)
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    /// Render assistant text as Markdown (bold/italic/code/links).
    /// `inlineOnlyPreservingWhitespace` keeps line breaks intact while still
    /// honoring inline formatting — perfect for short chat replies.
    private var rendered: AttributedString {
        if let attr = try? AttributedString(
            markdown: message.text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attr
        }
        return AttributedString(message.text)
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
