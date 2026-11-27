import SwiftUI

/// The „Zeit“ card of the sample view: date (bold) and time window on one
/// line, the 24-hour light band with sun and moon at the begin (variant
/// T2), a line each about sun and moon, the time zone. Date and window
/// stack when they don't fit (large type).
struct SampleTimeCard: View {
    let texts: SampleDateTexts
    /// nil without Tempus values: the card shows date and zone only.
    let sky: TimeCardSky?
    /// „Europe/Berlin (MEZ)“; nil for a new, unsaved sample.
    let zoneLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            SectionHeader(title: "Zeit")
            dateRow
            if let sky {
                if sky.showsBand {
                    LightBandView(
                        band: sky.band, markers: sky.markers,
                        sunrise: sky.sunrise.map { ($0.text, $0.at) }, sunset: sky.sunset.map { ($0.text, $0.at) },
                        accessibilityText: sky.accessibilityText
                    )
                    .padding(.top, AppSpacing.xs)
                }
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    ForEach(sky.facts, id: \.self) { fact in
                        Text(fact)
                            .font(AppFont.subhead)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                }
            }
            if let zoneLabel {
                Text(zoneLabel)
                    .font(AppFont.footnote)
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                dateText.lineLimit(1)
                Spacer(minLength: AppSpacing.sm)
                windowText
            }
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                // One line while it fits; at large type sizes the date
                // breaks after the weekday instead of mid-date.
                ViewThatFits(in: .horizontal) {
                    // Truncation never shows: `ViewThatFits` takes the
                    // stacked variant when one line is too narrow.
                    dateText.lineLimit(1)
                    if let weekday = texts.weekday, let rest = texts.dayAndYear {
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(weekday)
                            Text(rest)
                        }
                        .font(AppFont.bodyEmphasized)
                    } else {
                        // A range of days wraps as a whole.
                        dateText
                    }
                }
                windowText
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(texts.spoken)
    }

    private var dateText: some View {
        Text(texts.date)
            .font(AppFont.bodyEmphasized)
    }

    @ViewBuilder
    private var windowText: some View {
        if let window = texts.window {
            Text(window)
                .font(AppFont.body.monospacedDigit())
        }
    }
}

/// Sample data for previews and snapshots: Würzburg on 23.11.2026, a day
/// sample, a night sample over midnight (light trap) and one in twilight.
enum SampleTimeCardPreviewData {
    static let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    /// Fixed, so previews and snapshots don't depend on the simulator's
    /// language; the app uses the device's region.
    static let locale = Locale(identifier: "de_DE")

    static func time(_ hhmm: String, day: Int = 23) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = DateComponents(year: 2026, month: 11, day: day, hour: parts.first, minute: parts.last)
        c.timeZone = zone
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    private static func display(_ phase: ConditionsDisplay.LightPhase, sun: String, moon: String,
                                sunUp: Bool, moonUp: Bool) -> ConditionsDisplay
    {
        var d = ConditionsDisplay(state: .values)
        d.lightPhase = phase
        d.skyEvents = SkyEvents(
            astronomicalDawn: time("05:55"), nauticalDawn: time("06:30"), civilDawn: time("07:05"),
            sunrise: time("07:43"), sunset: time("16:29"), civilDusk: time("17:07"),
            nauticalDusk: time("17:48"), astronomicalDusk: time("18:27"),
            moonrise: time("13:20"), moonset: time("02:50")
        )
        d.sunFact = sun
        d.moonFact = moon
        d.sunIsUp = sunUp
        d.moonIsUp = moonUp
        d.moonIllumination = 78
        d.moonWaxing = true
        return d
    }

    private static func card(_ display: ConditionsDisplay, _ begin: Date, _ end: Date) -> SampleTimeCard {
        SampleTimeCard(
            texts: SampleDateTexts(begin: begin, end: end, isAllDay: false, zone: zone, locale: locale),
            sky: TimeCardSky(display: display, begin: begin, end: end, isAllDay: false, zone: zone, locale: locale),
            zoneLabel: "Europe/Berlin (MEZ)"
        )
    }

    static var day: SampleTimeCard {
        card(display(.day, sun: "Sonne 18° hoch, S", moon: "Mond unter dem Horizont · Aufgang 13:20",
                     sunUp: true, moonUp: false), time("11:15"), time("11:45"))
    }

    static var night: SampleTimeCard {
        card(display(.night, sun: "Sonne unter dem Horizont", moon: "Mond 31° hoch, SO · 78\u{00A0}%",
                     sunUp: false, moonUp: true), time("21:40"), time("03:10", day: 24))
    }

    static var twilight: SampleTimeCard {
        card(display(.twilight, sun: "Sonne unter dem Horizont", moon: "Mond 24° hoch, SSO · 78\u{00A0}%",
                     sunUp: false, moonUp: true), time("16:50"), time("17:20"))
    }
}

#Preview("Tag, Nacht, Dämmerung") {
    VStack(spacing: AppSpacing.md) {
        AppCard { SampleTimeCardPreviewData.day }
        AppCard { SampleTimeCardPreviewData.night }
        AppCard { SampleTimeCardPreviewData.twilight }
    }
    .padding()
    .background(AppColor.surfaceGrouped)
}

#Preview("AX5") {
    AppCard { SampleTimeCardPreviewData.night }
        .padding()
        .background(AppColor.surfaceGrouped)
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dark") {
    AppCard { SampleTimeCardPreviewData.night }
        .padding()
        .background(AppColor.surfaceGrouped)
        .preferredColorScheme(.dark)
}
