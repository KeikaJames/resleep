import SwiftUI

/// Block-level Markdown renderer for the legal documents bundled with the
/// app (EULA, Privacy, Terms, License, Third-Party Notices). SwiftUI's
/// built-in `Text(markdown:)` only handles *inline* syntax (bold, italic,
/// code, links). It silently leaks `#`, `##`, `-` characters into the UI
/// when fed real Markdown — which is what the AI EULA was doing.
///
/// This view parses line-by-line and emits the right SwiftUI primitive
/// for each block:
///   • `# / ## / ###`  → typographic headers
///   • `- / *`         → bulleted list rows
///   • `> `            → blockquote (italic, secondary)
///   • `---` / `***`   → `Divider`
///   • blank line      → vertical breathing room
///   • anything else   → paragraph with inline markdown applied
///
/// Inline markdown (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`)
/// is delegated to `AttributedString(markdown:)`.
/// Lightweight composable renderer that emits the parsed blocks without
/// any chrome. Use this when you want to embed Markdown content inside
/// another screen (e.g. the AI EULA gate which has its own scroll view
/// and bottom CTA).
struct MarkdownBody: View {
    let text: String

    var body: some View {
        let parsed = MarkdownDocumentView.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { _, block in
                block.view
                    .padding(.bottom, block.bottomSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownDocumentView: View {

    let titleKey: LocalizedStringKey
    let text: String
    /// Optional eyebrow line drawn above the title — used for prominent
    /// regulatory notices ("非医疗器械 · Not a Medical Device").
    var eyebrow: LocalizedStringKey? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .padding(.bottom, 6)
                }
                MarkdownBody(text: text)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .textSelection(.enabled)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(titleKey)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Parsing

    fileprivate enum Block {
        case h1(AttributedString)
        case h2(AttributedString)
        case h3(AttributedString)
        case paragraph(AttributedString)
        case bullet(AttributedString)
        case quote(AttributedString)
        case rule
        case spacer

        @ViewBuilder
        var view: some View {
            switch self {
            case .h1(let s):
                Text(s)
                    .font(.title.weight(.bold))
                    .padding(.top, 6)
            case .h2(let s):
                Text(s)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 14)
            case .h3(let s):
                Text(s)
                    .font(.headline)
                    .padding(.top, 8)
            case .paragraph(let s):
                Text(s)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            case .bullet(let s):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("•")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(s)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 4)
            case .quote(let s):
                Text(s)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                    }
            case .rule:
                Divider()
                    .padding(.vertical, 6)
            case .spacer:
                Spacer().frame(height: 6)
            }
        }

        var bottomSpacing: CGFloat {
            switch self {
            case .h1, .h2, .h3:        return 6
            case .paragraph:           return 12
            case .bullet:              return 6
            case .quote:               return 12
            case .rule:                return 6
            case .spacer:              return 0
            }
        }
    }

    fileprivate static func parse(_ raw: String) -> [Block] {
        var out: [Block] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if let last = out.last, case .spacer = last { continue }
                out.append(.spacer)
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out.append(.rule); continue
            }
            if trimmed.hasPrefix("### ") {
                out.append(.h3(inline(String(trimmed.dropFirst(4)))));   continue
            }
            if trimmed.hasPrefix("## ") {
                out.append(.h2(inline(String(trimmed.dropFirst(3)))));   continue
            }
            if trimmed.hasPrefix("# ") {
                out.append(.h1(inline(String(trimmed.dropFirst(2)))));   continue
            }
            if trimmed.hasPrefix("> ") {
                out.append(.quote(inline(String(trimmed.dropFirst(2))))); continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(.bullet(inline(String(trimmed.dropFirst(2))))); continue
            }
            out.append(.paragraph(inline(trimmed)))
        }
        return out
    }

    /// Parse inline markdown (bold/italic/code/links) into an AttributedString.
    /// Falls back to plain text if the parse fails.
    private static func inline(_ s: String) -> AttributedString {
        if let a = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return a
        }
        return AttributedString(s)
    }
}
