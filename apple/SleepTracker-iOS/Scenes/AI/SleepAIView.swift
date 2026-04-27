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

/// Soft, breathing color halo anchored to the bottom edge of the screen.
/// Mirrors the iOS 18 Apple Intelligence Siri activation aesthetic — a
/// gentle multi‑hue glow rather than a hard stroke that fights the device's
/// real corner radius. Sits behind the composer; never blocks input.
private struct IntelligenceGlow: View {
    var active: Bool = true

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breathe = (sin(t * 0.6) + 1) / 2  // 0…1
            let amp = active ? (0.55 + 0.25 * breathe) : 0.25

            GeometryReader { geo in
                let h = geo.size.height
                let w = geo.size.width
                ZStack {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.purple.opacity(0.55 * amp),
                                    Color.pink.opacity(0.30 * amp),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.7
                            )
                        )
                        .frame(width: w * 1.4, height: h * 0.55)
                        .offset(x: -w * 0.2, y: h * 0.55)
                        .blur(radius: 60)

                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.cyan.opacity(0.45 * amp),
                                    Color.blue.opacity(0.25 * amp),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.6
                            )
                        )
                        .frame(width: w * 1.2, height: h * 0.5)
                        .offset(x: w * 0.25, y: h * 0.6)
                        .blur(radius: 60)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Root view

struct SleepAIView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = SleepAIViewModel(
        serviceFactory: { tier in MLXSleepAIService(tier: tier) }
    )
    @FocusState private var composerFocused: Bool
    @State private var historyOpen: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                switch model.phase {
                case .needsEULA:
                    eulaScreen
                case .regionBlocked:
                    regionBlockedScreen
                case .ready, .chatting:
                    main
                }

                // Apple Intelligence bottom glow — only when actually using
                // the assistant (not on the EULA / region-block screens).
                if model.phase == .ready || model.phase == .chatting {
                    IntelligenceGlow(active: model.isReplying)
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
            .sensoryFeedback(.success, trigger: model.isReplying) { old, new in
                old == true && new == false
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.phase == .ready || model.phase == .chatting {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    historyOpen = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.medium))
                }
                .accessibilityLabel(Text("ai.toolbar.history"))
            }
            ToolbarItem(placement: .principal) {
                ModelPickerLabel(model: model)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut) {
                        Haptics.selection()
                        model.startNewChat()
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body)
                }
                .accessibilityLabel(Text("ai.toolbar.newChat"))
            }
        } else if model.phase == .regionBlocked {
            // Region-blocked state still gets a working "switch model"
            // affordance in the principal slot so the user is never stuck.
            ToolbarItem(placement: .principal) {
                ModelPickerLabel(model: model)
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
                            if !model.summaryText.isEmpty {
                                contextSnapshotCard
                                    .padding(.horizontal, 20)
                            }
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

    private var contextSnapshotCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("ai.summary.title")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(model.summaryText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var suggestionsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(Array(model.suggestionCards.enumerated()), id: \.offset) { _, card in
                Button {
                    composerFocused = false
                    Haptics.tapSoft()
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
        Haptics.tapRigid()
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
                MarkdownBody(text: model.eulaMarkdown())
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
                    Haptics.tapHeavy()
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

// MARK: - Model picker

/// Toolbar label that doubles as a Menu of available model tiers. Mirrors
/// the ChatGPT/Claude pattern: name + caret in the principal slot, tap to
/// reveal a list with subtitles + checkmark on the active row.
private struct ModelPickerLabel: View {
    @ObservedObject var model: SleepAIViewModel
    @Environment(\.locale) private var locale

    private var isChinese: Bool {
        locale.language.languageCode?.identifier == "zh"
            || (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
    }

    var body: some View {
        Menu {
            ForEach(model.availableTiers) { tier in
                Button {
                    if tier.brand != model.selectedTier.brand {
                        Haptics.selection()
                        model.selectBrand(tier.brand)
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(tier.displayName)
                            Text(tier.subtitle(chinese: isChinese))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        if tier.brand == model.selectedTier.brand {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.selectedTier.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .accessibilityLabel(Text("ai.toolbar.modelPicker"))
        }
    }
}

// MARK: - Region-blocked screen

private extension SleepAIView {
    var regionBlockedScreen: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text(model.regionBlockTitle)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(model.regionBlockBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            Button {
                Haptics.selection()
                model.selectTier(model.regionFallbackTier.kind)
            } label: {
                Text(model.regionBlockSwitchCTA)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Markdown rendering

/// Tiny block‑level Markdown renderer for chat bubbles. SwiftUI's
/// `Text(AttributedString)` only renders *inline* markdown — bold / italic
/// / code / links — and silently strips bullet markers. We still want
/// proper bullet lists in assistant replies, so this view splits on
/// blank lines and renders each block as either a paragraph (inline‑parsed
/// AttributedString) or a list (one row per `•` / `-` / `*` line).
private struct MarkdownText: View {
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let lines):
                    Text(inline(lines.joined(separator: "\n")))
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(inline(item))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private enum Block { case paragraph([String]); case list([String]) }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var list: [String] = []
        func flush() {
            if !list.isEmpty { out.append(.list(list)); list = [] }
            if !paragraph.isEmpty { out.append(.paragraph(paragraph)); paragraph = [] }
        }
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let bullet = bulletContent(of: trimmed) {
                if !paragraph.isEmpty {
                    out.append(.paragraph(paragraph))
                    paragraph = []
                }
                list.append(bullet)
            } else {
                if !list.isEmpty {
                    out.append(.list(list))
                    list = []
                }
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    /// Returns the content of a bullet line if `line` starts with one of
    /// `•`, `-`, `*`, `+ ` (with required trailing space), else nil.
    private func bulletContent(of line: String) -> String? {
        for marker in ["• ", "- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
        }
        return nil
    }

    private func inline(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(s)
    }
}

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
        MarkdownText(raw: message.text)
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    /// Inline‑only markdown fallback (kept for callers that want a single
    /// AttributedString, e.g. snapshot tests).
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
