import SwiftUI

/// One labelled value of a `ValuePairGrid`. `spoken` is what VoiceOver
/// reads: label and value with the unit written out („Luftfeuchte 62
/// Prozent“).
struct LabeledValue: Equatable, Identifiable {
    let id: String
    let label: String
    let value: String
    let spoken: String
}

/// A compact block of labelled values, e.g. the weather readings of a
/// sample: „Luftfeuchte 62 %   Taupunkt 11,0 °C“.
///
/// Use it where several short measurements belong together and each is
/// just a label and a value. For place fields with a country-specific
/// term use `PlaceFieldRow`; for a value the user can copy use
/// `CopyableValueButton`.
///
/// Layout: two columns; one column at accessibility text sizes, where
/// two would squeeze every value onto several lines. A value never
/// truncates, it wraps. VoiceOver reads each pair as one element.
struct ValuePairGrid: View {
    let items: [LabeledValue]

    init(_ items: [LabeledValue]) {
        self.items = items
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : 2
    }

    /// The items cut into rows of `columnCount`.
    private var rows: [[LabeledValue]] {
        stride(from: 0, to: items.count, by: columnCount).map {
            Array(items[$0 ..< min($0 + columnCount, items.count)])
        }
    }

    /// Deliberately not a LazyVGrid: inside the sample's ScrollView it
    /// only estimates rows out of sight, and a wrapping row („Niederschlag
    /// 120 h“) then changes height on its way back in. The content height
    /// flips, the scroll offset with it, and the view gets stuck jittering.
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: AppSpacing.lg) {
                    ForEach(row) { item in
                        cell(item)
                    }
                    // A lone item of the last row keeps its column width.
                    if row.count < columnCount {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: 0)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func cell(_ item: LabeledValue) -> some View {
        (Text(item.label + " ").foregroundStyle(AppColor.textSecondary)
            + Text(item.value).foregroundStyle(AppColor.textPrimary))
            .font(AppFont.subhead)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.spoken)
    }
}

private struct ValuePairGridPreview: View {
    var body: some View {
        ValuePairGrid([
            LabeledValue(id: "h", label: "Luftfeuchte", value: "62 %", spoken: "Luftfeuchte 62 Prozent"),
            LabeledValue(id: "d", label: "Taupunkt", value: "11,0 °C", spoken: "Taupunkt 11,0 Grad Celsius"),
            LabeledValue(id: "w", label: "Wind", value: "9 km/h", spoken: "Wind 9 Kilometer pro Stunde"),
            LabeledValue(id: "c", label: "Bewölkung", value: "10 %", spoken: "Bewölkung 10 Prozent"),
            LabeledValue(id: "p", label: "Niederschlag", value: "0,0 mm", spoken: "Niederschlag 0,0 Millimeter")
        ])
        .padding()
    }
}

#Preview("Default") {
    ValuePairGridPreview()
}

#Preview("AX5") {
    ValuePairGridPreview()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dark") {
    ValuePairGridPreview()
        .preferredColorScheme(.dark)
}
