import SwiftUI

/// The area „Wetter und Klima“ of the sample view: the weather at the
/// sample's instant, prominent, tiles for wind, clouds, humidity and
/// the rain of the last days, and the Köppen climate. Sun and moon stand
/// with the date, the altitudinal belt with the place. `detail` opens
/// the page with everything Tempus delivered and the sources.
struct ConditionsSection: View {
    let display: ConditionsDisplay
    /// nil hides the link (nothing to show there).
    let detail: ConditionsDetailModel?

    /// Apple HIG tap target. Padding alone falls short of it at the
    /// small text sizes.
    private let minTapTarget: CGFloat = 44

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
        if !display.tiles.isEmpty {
            WeatherTileGrid(tiles: display.tiles)
        }
        HStack(spacing: AppSpacing.sm) {
            if let koppen = display.koppen {
                Text("Köppen \(koppen)")
                    .font(AppFont.footnote.weight(.medium))
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(AppColor.surfaceGrouped, in: Capsule())
                    .accessibilityLabel("Köppen-Klima \(koppen)")
            }
            if detail != nil {
                Spacer(minLength: AppSpacing.sm)
            }
            detailLink
        }
    }

    @ViewBuilder
    private var detailLink: some View {
        if let detail {
            NavigationLink {
                ConditionsDetailView(model: detail)
            } label: {
                // Full width and at least 44 pt high at every text size.
                HStack {
                    Text("Details")
                    Spacer(minLength: AppSpacing.sm)
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                }
                .font(AppFont.body)
                .padding(.vertical, AppSpacing.md)
                .frame(minHeight: minTapTarget)
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
        .font(AppFont.sectionTitle)
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
    display.tiles = [
        WeatherTile(id: "wind", value: "7", unit: "km/h", caption: "Wind", word: "leichte Brise",
                    spoken: "Wind leichte Brise, 7 Kilometer pro Stunde"),
        WeatherTile(id: "humidity", value: "85", unit: "%", caption: "Feuchte", word: "schwül",
                    spoken: "Luftfeuchte schwül, 85 Prozent")
    ]
    display.koppen = "Cfb"
    return NavigationStack {
        ScrollView { ConditionsSection(display: display, detail: nil).padding(.horizontal) }
    }
}

#Preview("Wartet auf Höhe, AX5") {
    ConditionsSection(display: ConditionsDisplay(state: .waitingForElevation), detail: nil)
        .padding(.horizontal)
        .dynamicTypeSize(.accessibility5)
}

/// The weather tiles: four in a row, two at accessibility sizes. Not a
/// lazy grid: inside the sample's ScrollView a lazy one estimates rows
/// out of sight and makes the view jitter (see `ValuePairGrid`).
private struct WeatherTileGrid: View {
    let tiles: [WeatherTile]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : 4
    }

    private var rows: [[WeatherTile]] {
        stride(from: 0, to: tiles.count, by: columnCount).map {
            Array(tiles[$0 ..< min($0 + columnCount, tiles.count)])
        }
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    ForEach(row) { WeatherTileView(tile: $0) }
                    ForEach(row.count ..< columnCount, id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: 0)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

private struct WeatherTileView: View {
    let tile: WeatherTile

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xxs) {
                Text(tile.value)
                    .font(AppFont.headline)
                    .monospacedDigit()
                if let unit = tile.unit {
                    Text(unit)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            Text(tile.caption)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            if let word = tile.word {
                Text(word)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textPrimary)
            }
        }
        .padding(AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(AppColor.surfaceGrouped, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.spoken)
    }
}
