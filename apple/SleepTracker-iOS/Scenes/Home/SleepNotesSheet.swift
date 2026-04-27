import SwiftUI
import SleepKit

/// Bottom sheet shown before tracking starts (or attached to a completed
/// session, retroactively). Lets the user tag conditions that affect sleep:
/// caffeine, alcohol, exercise, stress, late meal, travel, medication, screens.
struct SleepNotesSheet: View {
    let sessionId: String
    let onDone: () -> Void

    @EnvironmentObject private var appState: AppState

    @State private var selectedTags: Set<SleepTag> = []
    @State private var note: String = ""

    private let columns = [
        GridItem(.flexible()), GridItem(.flexible())
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(SleepTag.allCases, id: \.self) { tag in
                            TagChip(tag: tag,
                                    selected: selectedTags.contains(tag)) {
                                if selectedTags.contains(tag) {
                                    selectedTags.remove(tag)
                                } else {
                                    selectedTags.insert(tag)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("notes.tags.header")
                } footer: {
                    Text("notes.tags.footer")
                }

                Section {
                    TextField("notes.note.placeholder", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("notes.note.header")
                }
            }
            .navigationTitle(Text("notes.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("notes.cancel") { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("notes.save") {
                        let tags = selectedTags.map { $0.rawValue }
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await appState.attachSleepNotes(
                                sessionId: sessionId,
                                tags: tags.isEmpty ? nil : tags,
                                note: trimmed.isEmpty ? nil : trimmed
                            )
                            onDone()
                        }
                    }
                }
            }
        }
    }
}

private struct TagChip: View {
    let tag: SleepTag
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tag.systemSymbol)
                Text(LocalizedStringKey(tag.localizedKey))
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18)
                                   : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}
