import SwiftUI

/// The „Zeit“ card of the sample view (variant A): date (bold) and time
/// window on one line, sun or moon and the time zone on the next; each
/// pair stacks when it doesn't fit (large type). The card's header
/// replaces a calendar icon, so the date has the full width.
///
/// Sun and moon follow the light phase (`ConditionsDisplay.skyItems`):
/// sunrise and sunset by day, the moon by night, both in twilight.
struct SampleTimeCard: View {
    let texts: SampleDateTexts
    let skyItems: [ConditionsDisplay.SkyItem]
    /// „Europe/Berlin (MEZ)“; nil for a new, unsaved sample.
    let zoneLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            SectionHeader(title: "Zeit")
            row
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                    skyLine.lineLimit(1)
                    Spacer(minLength: AppSpacing.sm)
                    zoneText
                }
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    skyLine
                    zoneText
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
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

    @ViewBuilder
    private var zoneText: some View {
        if let zoneLabel {
            Text(zoneLabel)
                .font(AppFont.footnote)
                .foregroundStyle(AppColor.textSecondary)
        }
    }

    /// „🌅 07:31  🌇 16:42  🌕 Vollmond, 98 %“ side by side; one per line
    /// when that doesn't fit (AX sizes).
    @ViewBuilder
    private var skyLine: some View {
        if !skyItems.isEmpty {
            // All in one line; else sunrise and sunset together and the
            // moon below (twilight); else one per line (AX sizes).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.lg) {
                    ForEach(skyItems) { skyLabel($0) }
                }
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.lg) {
                        ForEach(sunItems) { skyLabel($0) }
                    }
                    ForEach(otherItems) { skyLabel($0) }
                }
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    ForEach(skyItems) { skyLabel($0) }
                }
            }
            .font(AppFont.subhead)
        }
    }

    private var sunItems: [ConditionsDisplay.SkyItem] {
        skyItems.filter { $0.id == "sunrise" || $0.id == "sunset" }
    }

    private var otherItems: [ConditionsDisplay.SkyItem] {
        skyItems.filter { $0.id != "sunrise" && $0.id != "sunset" }
    }

    private func skyLabel(_ item: ConditionsDisplay.SkyItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            Image(systemName: item.symbol)
                .foregroundStyle(AppColor.textSecondary)
                .accessibilityHidden(true)
            Text(item.value)
                .monospacedDigit()
        }
    }

    private var a11yLabel: String {
        var parts = [texts.spoken]
        parts += skyItems.map(\.spoken)
        if let zoneLabel { parts.append(zoneLabel) }
        return parts.joined(separator: ", ")
    }
}

/// Sample data for previews and snapshots: a day sample, a night sample
/// (light trap) and one in twilight.
enum SampleTimeCardPreviewData {
    static let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    /// Fixed, so previews and snapshots don't depend on the simulator's
    /// language; the app uses the device's region.
    static let locale = Locale(identifier: "de_DE")

    static let sun: [ConditionsDisplay.SkyItem] = [
        .init(id: "sunrise", symbol: "sunrise", value: "07:43", spoken: "Sonnenaufgang 07:43 Uhr"),
        .init(id: "sunset", symbol: "sunset", value: "16:29", spoken: "Sonnenuntergang 16:29 Uhr")
    ]
    static let moon = ConditionsDisplay.SkyItem(
        id: "moon", symbol: "moonphase.waxing.gibbous", value: "zunehmender Mond, 78\u{00A0}%",
        spoken: "Mond: zunehmender Mond, 78 Prozent beleuchtet"
    )

    static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date()
    }

    static var day: SampleTimeCard {
        SampleTimeCard(
            texts: SampleDateTexts(begin: date("2026-11-23T15:45:00Z"), end: date("2026-11-23T16:00:00Z"),
                                   isAllDay: false, zone: zone, locale: locale),
            skyItems: sun, zoneLabel: "Europe/Berlin (MEZ)"
        )
    }

    static var night: SampleTimeCard {
        SampleTimeCard(
            texts: SampleDateTexts(begin: date("2026-11-23T20:40:00Z"), end: date("2026-11-24T02:10:00Z"),
                                   isAllDay: false, zone: zone, locale: locale),
            skyItems: [moon], zoneLabel: "Europe/Berlin (MEZ)"
        )
    }

    static var twilight: SampleTimeCard {
        SampleTimeCard(
            texts: SampleDateTexts(begin: date("2026-11-23T15:50:00Z"), end: date("2026-11-23T16:20:00Z"),
                                   isAllDay: false, zone: zone, locale: locale),
            skyItems: sun + [moon], zoneLabel: "Europe/Berlin (MEZ)"
        )
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
    AppCard { SampleTimeCardPreviewData.twilight }
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
