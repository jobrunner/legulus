import SwiftUI

/// The area „Wetter und Klima“ of the sample view: the weather at the
/// sample's instant, the days before, sun and moon, the climate of the
/// place, and where the values come from. `detail` opens the page with
/// everything Tempus delivered.
struct ConditionsSection: View {
    let display: ConditionsDisplay
    /// nil hides the link (nothing to show there).
    let detail: ConditionsDetailModel?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            header
            switch display.state {
            case .noCoordinate:
                message("Ohne Koordinate keine Wetterdaten")
            case .waitingForElevation:
                message("Wartet auf die Höhe des Fundorts")
            case .pending:
                message("Wird ermittelt …")
            case .legacy:
                message("Noch keine Wetterdaten")
            case .values:
                values
            }
        }
        .padding(.vertical, AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        // The status moves below the title when both do not fit in one
        // line (large type); it is text, never colour alone.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Wetter und Klima")
                Spacer(minLength: AppSpacing.sm)
                provisionalLabel
            }
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                SectionHeader(title: "Wetter und Klima")
                provisionalLabel
            }
        }
    }

    @ViewBuilder
    private var provisionalLabel: some View {
        if display.state == .values, display.isProvisional {
            Text("vorläufig")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .accessibilityLabel("Werte vorläufig")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(AppFont.subhead)
            .foregroundStyle(AppColor.textSecondary)
    }

    @ViewBuilder
    private var values: some View {
        if display.weatherTitle != nil || display.temperature != nil {
            weatherLine
        }
        if let note = display.note {
            message(note)
        }
        if !display.hourly.isEmpty {
            ValuePairGrid(display.hourly)
        }
        if !display.daily.isEmpty {
            ValuePairGrid(display.daily)
        }
        if !display.sky.isEmpty || display.climate != nil {
            ValuePairGrid(display.sky + [display.climate].compactMap { $0 })
        }
        if let attribution = display.attribution {
            Text("Quellen: " + attribution)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        }
        if let detail {
            NavigationLink {
                ConditionsDetailView(model: detail)
            } label: {
                // The padding makes the row a full tap target.
                HStack {
                    Text("Details")
                    Spacer(minLength: AppSpacing.sm)
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                }
                .font(AppFont.body)
                .padding(.vertical, AppSpacing.md)
                .contentShape(Rectangle())
            }
            .accessibilityHint("Zeigt alle Wetter-, Klima- und Astronomiewerte")
        }
    }

    private var weatherLine: some View {
        // Title and temperature in one line; below each other when that
        // would squeeze them (large type).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                weatherTitle
                Spacer(minLength: AppSpacing.sm)
                temperatureText
            }
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                weatherTitle
                temperatureText
            }
        }
        .font(AppFont.bodyEmphasized)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [display.weatherTitle, display.temperatureSpoken].compactMap { $0 }.joined(separator: ", ")
        )
    }

    private var weatherTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            if let symbol = display.weatherSymbol {
                Image(systemName: symbol)
                    .foregroundStyle(AppColor.textSecondary)
                    .accessibilityHidden(true)
            }
            if let title = display.weatherTitle {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var temperatureText: some View {
        if let temperature = display.temperature {
            Text(temperature)
                .monospacedDigit()
        }
    }
}

#Preview("Werte") {
    var display = ConditionsDisplay(state: .values)
    display.isProvisional = true
    display.weatherTitle = "Leichter Regen"
    display.weatherSymbol = "cloud.rain"
    display.temperature = "16,0 °C"
    display.temperatureSpoken = "16,0 Grad Celsius"
    display.hourly = [
        LabeledValue(id: "h", label: "Luftfeuchte", value: "85 %", spoken: "Luftfeuchte 85 Prozent"),
        LabeledValue(id: "w", label: "Wind", value: "7 km/h", spoken: "Wind 7 Kilometer pro Stunde")
    ]
    display.sky = [LabeledValue(id: "m", label: "Mond", value: "Vollmond, 98 %", spoken: "Mond: Vollmond")]
    display.attribution = "Weather data by Open-Meteo.com"
    return NavigationStack {
        ScrollView { ConditionsSection(display: display, detail: nil).padding(.horizontal) }
    }
}

#Preview("Wartet auf Höhe, AX5") {
    ConditionsSection(display: ConditionsDisplay(state: .waitingForElevation), detail: nil)
        .padding(.horizontal)
        .dynamicTypeSize(.accessibility5)
}
