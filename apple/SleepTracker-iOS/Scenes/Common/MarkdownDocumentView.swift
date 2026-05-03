import SwiftUI

/// Block-level Markdown renderer for the legal documents bundled with the
/// app (EULA, Privacy, Terms, Acknowledgments, Open-Source Notices).
///
/// SwiftUI's built-in `Text(markdown:)` only handles *inline* syntax (bold,
/// italic, code, links). It silently leaks `#`, `##`, `-`, `1.`, `|` chars
/// into the UI when fed real Markdown — which is what early legal pages
/// were doing.
///
/// This view parses line-by-line and emits the right SwiftUI primitive for
/// each block. Supports:
///
///   • `# / ## / ### / ####`  → typographic headers (H1 …  H4)
///   • `- ` / `* `            → bulleted list rows
///   • `1. 2. 3. …`           → numbered list rows (preserves the digit
///                              that was actually written so a list that
///                              starts at 5 reads as "5. xxx")
///   • `> `                   → blockquote (italic, secondary, accent rule)
///   • `| a | b |` (≥ 2 rows) → table with bold header + body rows
///   • `--- / *** / ___`      → `Divider`
///   • blank line             → vertical breathing room
///   • anything else          → paragraph with inline markdown applied
///
/// Inline markdown (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`)
/// is delegated to `AttributedString(markdown:)`. A line that is *entirely*
/// wrapped in `**…**` is rendered as a slightly-stronger paragraph (used
/// for callout-style headings in Chinese legal copy that don't use `#`).

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

    // MARK: - Block model

    fileprivate struct TableData {
        let headers: [AttributedString]
        let rows: [[AttributedString]]
    }

    fileprivate enum Block {
        case h1(AttributedString)
        case h2(AttributedString)
        case h3(AttributedString)
        case h4(AttributedString)
        case paragraph(AttributedString)
        /// A paragraph whose original line was entirely wrapped in `**…**`.
        /// Rendered slightly heavier than a normal paragraph so legal
        /// callouts ("生效日期：xxx") read as their own beat.
        case strongParagraph(AttributedString)
        case bullet(AttributedString)
        case numbered(marker: String, content: AttributedString)
        case quote(AttributedString)
        case table(TableData)
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
            case .h4(let s):
                Text(s)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 6)
            case .paragraph(let s):
                Text(s)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            case .strongParagraph(let s):
                Text(s)
                    .font(.callout.weight(.semibold))
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
            case .numbered(let marker, let s):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(marker)
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                    Text(s)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 2)
            case .quote(let s):
                Text(s)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: 3)
                            .padding(.vertical, 4)
                    }
            case .table(let data):
                TableView(data: data)
            case .rule:
                Divider()
                    .padding(.vertical, 6)
            case .spacer:
                Spacer().frame(height: 6)
            }
        }

        var bottomSpacing: CGFloat {
            switch self {
            case .h1, .h2, .h3, .h4:   return 6
            case .paragraph:           return 12
            case .strongParagraph:     return 12
            case .bullet:              return 6
            case .numbered:            return 6
            case .quote:               return 14
            case .table:               return 14
            case .rule:                return 6
            case .spacer:              return 0
            }
        }
    }

    // MARK: - Parsing

    fileprivate static func parse(_ raw: String) -> [Block] {
        var out: [Block] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Blank line → squashed spacer.
            if trimmed.isEmpty {
                if let last = out.last, case .spacer = last { i += 1; continue }
                out.append(.spacer); i += 1; continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out.append(.rule); i += 1; continue
            }

            // Headings (longest prefix first so `####` doesn't match `###`).
            if trimmed.hasPrefix("#### ") {
                out.append(.h4(inline(String(trimmed.dropFirst(5))))); i += 1; continue
            }
            if trimmed.hasPrefix("### ") {
                out.append(.h3(inline(String(trimmed.dropFirst(4))))); i += 1; continue
            }
            if trimmed.hasPrefix("## ") {
                out.append(.h2(inline(String(trimmed.dropFirst(3))))); i += 1; continue
            }
            if trimmed.hasPrefix("# ") {
                out.append(.h1(inline(String(trimmed.dropFirst(2))))); i += 1; continue
            }

            // Blockquote.
            if trimmed.hasPrefix("> ") {
                out.append(.quote(inline(String(trimmed.dropFirst(2))))); i += 1; continue
            }

            // Bullet list.
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(.bullet(inline(String(trimmed.dropFirst(2))))); i += 1; continue
            }

            // Numbered list (`1. `, `12. `, etc.).
            if let (marker, body) = matchNumbered(trimmed) {
                out.append(.numbered(marker: marker + ".", content: inline(body))); i += 1; continue
            }

            // Table block: a line starting with `|` that is followed by an
            // alignment row (`| --- | --- |`). We scan forward to collect
            // every contiguous `|`-row.
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                if let (block, consumed) = consumeTable(lines: lines, startingAt: i) {
                    out.append(.table(block))
                    i += consumed
                    continue
                }
            }

            // Whole-line strong emphasis: a paragraph that is entirely
            // wrapped in `**…**`. Renders as a slightly heavier paragraph
            // so Chinese legal callouts ("**生效日期：…**") have weight
            // without abusing a heading.
            if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") && trimmed.count > 4 {
                let inner = String(trimmed.dropFirst(2).dropLast(2))
                out.append(.strongParagraph(inline(inner))); i += 1; continue
            }

            out.append(.paragraph(inline(trimmed)))
            i += 1
        }
        return out
    }

    /// Match `^(\d+)\.\s+(.*)$`. Returns `(marker, body)` if the line is a
    /// numbered list item.
    private static func matchNumbered(_ s: String) -> (String, String)? {
        // Find the first non-digit.
        var idx = s.startIndex
        var digits = ""
        while idx < s.endIndex, s[idx].isASCII, s[idx].isNumber {
            digits.append(s[idx])
            idx = s.index(after: idx)
        }
        guard !digits.isEmpty, idx < s.endIndex, s[idx] == "." else { return nil }
        let afterDot = s.index(after: idx)
        guard afterDot < s.endIndex, s[afterDot].isWhitespace else { return nil }
        let body = s[s.index(after: afterDot)...].trimmingCharacters(in: .whitespaces)
        return (digits, body)
    }

    /// Consume a contiguous Markdown table starting at `start`. Expects the
    /// shape:
    ///
    ///     | h1 | h2 |
    ///     | --- | --- |
    ///     | r1c1 | r1c2 |
    ///     | r2c1 | r2c2 |
    ///
    /// Returns `(parsed-table, lines-consumed)`. Returns `nil` if the
    /// alignment row is missing — in which case the caller falls back to
    /// rendering each `|`-line as a plain paragraph.
    private static func consumeTable(lines: [String], startingAt start: Int)
        -> (TableData, Int)? {
        guard start + 1 < lines.count else { return nil }
        let header = lines[start].trimmingCharacters(in: .whitespaces)
        let align = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard isTableRow(header), isAlignmentRow(align) else { return nil }

        let headers = splitRow(header).map(inline)

        var rows: [[AttributedString]] = []
        var i = start + 2
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if !isTableRow(l) { break }
            let cells = splitRow(l).map(inline)
            // Pad / trim to header width.
            var normalised = cells
            if normalised.count < headers.count {
                normalised.append(contentsOf:
                    Array(repeating: AttributedString(""), count: headers.count - normalised.count))
            } else if normalised.count > headers.count {
                normalised = Array(normalised.prefix(headers.count))
            }
            rows.append(normalised)
            i += 1
        }

        return (TableData(headers: headers, rows: rows), i - start)
    }

    private static func isTableRow(_ s: String) -> Bool {
        s.hasPrefix("|") && s.hasSuffix("|") && s.contains("|")
    }

    /// Alignment row: cells contain only `-`, `:`, and whitespace.
    private static func isAlignmentRow(_ s: String) -> Bool {
        guard isTableRow(s) else { return false }
        let cells = splitRow(s)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let t = cell.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            for ch in t where !(ch == "-" || ch == ":") { return false }
        }
        return true
    }

    private static func splitRow(_ s: String) -> [String] {
        let trimmed = s
            .trimmingCharacters(in: .whitespaces)
            .trimmingPrefix("|")
            .trimmingSuffix("|")
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parse inline markdown (bold/italic/code/links) into an AttributedString.
    /// Falls back to plain text if the parse fails.
    fileprivate static func inline(_ s: String) -> AttributedString {
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

// MARK: - Helpers

private extension String {
    func trimmingPrefix(_ p: String) -> String {
        hasPrefix(p) ? String(dropFirst(p.count)) : self
    }
    func trimmingSuffix(_ s: String) -> String {
        hasSuffix(s) ? String(dropLast(s.count)) : self
    }
}

// MARK: - Table view

private struct TableView: View {
    let data: MarkdownDocumentView.TableData

    var body: some View {
        VStack(spacing: 0) {
            // Header row.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ForEach(Array(data.headers.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.10))

            // Body rows.
            ForEach(Array(data.rows.enumerated()), id: \.offset) { idx, row in
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(idx.isMultiple(of: 2)
                            ? Color.clear
                            : Color.secondary.opacity(0.04))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }
}
