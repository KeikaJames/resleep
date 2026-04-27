import SwiftUI
import SleepKit

/// Bottom sheet shown to the user shortly after a session is archived.
/// Apple-style: large title, plain segmented controls, no emoji, native
/// stepper rules.
///
/// All inputs are optional. The user may submit the empty form (Skip),
/// in which case nothing is recorded.
struct WakeUpSurveySheet: View {
    let sessionId: String
    let onDone: () -> Void

    @EnvironmentObject private var appState: AppState

    @State private var quality: Int = 3
    @State private var alarmFeltGood: Bool? = nil
    @State private var actualFellAsleepAt: Date? = nil
    @State private var actualWokeUpAt: Date? = nil
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ForEach(1...5, id: \.self) { v in
                            Button {
                                quality = v
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(v <= quality ? Color.accentColor
                                                          : Color(.systemGray5))
                                        .frame(width: 36, height: 36)
                                    Text("\(v)")
                                        .foregroundStyle(v <= quality ? .white : .primary)
                                        .font(.body.weight(.semibold))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
                } header: {
                    Text("survey.quality.title", bundle: .main,
                         comment: "Wake-up survey: quality header")
                } footer: {
                    Text("survey.quality.footer", bundle: .main,
                         comment: "1 = poor, 5 = excellent")
                }

                Section {
                    Picker(selection: $alarmFeltGood) {
                        Text("survey.alarm.unset").tag(Bool?.none)
                        Text("survey.alarm.good").tag(Bool?.some(true))
                        Text("survey.alarm.bad").tag(Bool?.some(false))
                    } label: {
                        Text("survey.alarm.title")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("survey.alarm.header")
                } footer: {
                    Text("survey.alarm.footer")
                }

                Section {
                    OptionalDatePicker(
                        title: "survey.fellasleep.title",
                        date: $actualFellAsleepAt
                    )
                    OptionalDatePicker(
                        title: "survey.wokeup.title",
                        date: $actualWokeUpAt
                    )
                } header: {
                    Text("survey.times.header")
                }

                Section {
                    TextField("survey.note.placeholder", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("survey.note.header")
                }
            }
            .navigationTitle(Text("survey.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("survey.skip") { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("survey.submit") {
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        let s = WakeSurvey(
                            quality: quality,
                            actualFellAsleepAt: actualFellAsleepAt,
                            actualWokeUpAt: actualWokeUpAt,
                            alarmFeltGood: alarmFeltGood,
                            note: trimmed.isEmpty ? nil : trimmed
                        )
                        Task {
                            await appState.submitWakeSurvey(sessionId: sessionId, survey: s)
                            onDone()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(false)
    }
}

private struct OptionalDatePicker: View {
    let title: LocalizedStringKey
    @Binding var date: Date?
    @State private var local: Date = Date()

    var body: some View {
        Toggle(isOn: Binding(
            get: { date != nil },
            set: { isOn in date = isOn ? local : nil }
        )) {
            Text(title)
        }
        if date != nil {
            DatePicker("",
                       selection: Binding(get: { local },
                                          set: { local = $0; date = $0 }),
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
        }
    }
}
