import SwiftUI

/// Detail page of „Wetter und Klima“: every value Tempus delivered for
/// the sample, grouped by subject, each group with its source and
/// licence.
struct ConditionsDetailView: View {
    let model: ConditionsDetailModel

    var body: some View {
        List {
            Section {
                if let queriedFor = model.queriedFor {
                    LabeledContent("Abgefragt für", value: queriedFor)
                }
                if let fetchedAt = model.fetchedAt {
                    LabeledContent("Abgerufen am", value: fetchedAt)
                }
                if model.isProvisional {
                    Text("Die Werte sind vorläufig und werden später durch endgültige ersetzt.")
                        .font(AppFont.footnote)
                        .foregroundStyle(AppColor.textSecondary)
                }
            } footer: {
                if let note = model.elevationNote {
                    Text(note + ". Temperatur und Taupunkt sind auf diese Höhe korrigiert.")
                }
            }
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        LabeledContent(row.label, value: row.value)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(row.spoken)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    source(of: group)
                }
            }
        }
        .navigationTitle("Wetter und Klima")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func source(of group: ConditionsDetailModel.Group) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if let attribution = group.attribution {
                Text("Quelle: " + attribution)
            }
            if let name = group.licenseName {
                if let url = group.licenseURL {
                    Link("Lizenz: " + name, destination: url)
                } else {
                    Text("Lizenz: " + name)
                }
            }
        }
    }
}
