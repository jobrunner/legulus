import SwiftUI

/// Sun and moon of a sample for the light band: what is above the
/// horizon at the sample's begin, and whether the moon belongs to the
/// picture at all (not by day).
struct SkyMarkers: Equatable {
    var sunIsUp = false
    var moonIsUp = false
    /// Draws the line of the moon's hours above the band.
    var showsMoon = true
}

/// The 24-hour light band (variant T2): night, twilights and day as
/// coloured stretches, the sample's window as a bracket on it, the moon
/// as a line above while it is up, sun and moon at the begin, hours and
/// sunrise and sunset below.
///
/// A picture: VoiceOver reads one summary (`accessibilityText`).
struct LightBandView: View {
    let band: LightBand
    let markers: SkyMarkers
    /// Sunrise and sunset in the device's format, placed under the band.
    let sunrise: (text: String, at: Double)?
    let sunset: (text: String, at: Double)?
    let accessibilityText: String

    private let bandHeight: CGFloat = 22
    private let markerRow: CGFloat = 30
    private let moonLineY: CGFloat = 8
    private let glyph: CGFloat = 14

    @ScaledMetric(relativeTo: .caption2) private var labelRow: CGFloat = 16
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Half a label's width: keeps the outer labels inside the card at
    /// every text size.
    @ScaledMetric(relativeTo: .caption2) private var hourInset: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var timeInset: CGFloat = 24

    var body: some View {
        VStack(spacing: AppSpacing.xxs) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    if markers.showsMoon {
                        moonLine(width: w)
                    }
                    // Leading: the stack is only as wide as its widest
                    // stretch, the offsets count from the band's start.
                    stretches(width: w)
                        .frame(width: w, height: bandHeight, alignment: .leading)
                        .clipShape(Capsule())
                        .offset(y: markerRow)
                    window(width: w)
                    beginMarkers(width: w)
                }
            }
            .frame(height: markerRow + bandHeight + AppSpacing.xs)
            if dynamicTypeSize.isAccessibilitySize {
                // Five hour marks and two times don't fit under the band
                // at these sizes: the times become a line of text.
                sunTimesText
            } else {
                hourLabels
                sunLabels
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    // MARK: - layers

    private func stretches(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array(band.segments.enumerated()), id: \.offset) { _, segment in
                Rectangle()
                    .fill(Self.color(segment.phase))
                    .frame(width: max(CGFloat(segment.to - segment.from) * width, 0))
                    .offset(x: CGFloat(segment.from) * width)
            }
        }
    }

    private func moonLine(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(band.moonUp.enumerated()), id: \.offset) { _, up in
                Capsule()
                    .fill(AppColor.skyMoonLit)
                    .overlay(Capsule().strokeBorder(AppColor.outlineSubtle, lineWidth: 0.5))
                    .frame(width: max(CGFloat(up.upperBound - up.lowerBound) * width, 2), height: 4)
                    .offset(x: CGFloat(up.lowerBound) * width, y: moonLineY)
            }
        }
    }

    @ViewBuilder
    private func window(width: CGFloat) -> some View {
        if let window = band.window {
            let x = CGFloat(window.lowerBound) * width
            let w = max(CGFloat(window.upperBound - window.lowerBound) * width, 6)
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .strokeBorder(AppColor.textPrimary, lineWidth: 2)
                .frame(width: w, height: bandHeight + 8)
                .offset(x: x - 1, y: markerRow - 4)
        }
    }

    @ViewBuilder
    private func beginMarkers(width: CGFloat) -> some View {
        if let begin = band.begin {
            let x = CGFloat(begin) * width
            HStack(spacing: AppSpacing.xxs) {
                if markers.sunIsUp {
                    SunGlyph().frame(width: glyph, height: glyph)
                }
                if markers.moonIsUp {
                    MoonGlyph()
                        .frame(width: glyph, height: glyph)
                }
            }
            // Centred on the begin, inside the band's edges.
            .position(x: min(max(x, glyph), width - glyph), y: moonLineY + 2)
        }
    }

    private var hourLabels: some View {
        GeometryReader { geo in
            ForEach(Array(band.hourMarks.enumerated()), id: \.offset) { _, mark in
                Text(Self.hourLabel(mark.date, zone: band.zone))
                    .font(AppFont.caption2)
                    .foregroundStyle(AppColor.textSecondary)
                    // An axis label stays on one line; the scaled
                    // inset keeps it inside the card.
                    .fixedSize()
                    .position(x: Self.labelX(mark.at, width: geo.size.width, inset: hourInset), y: labelRow / 2)
            }
        }
        .frame(height: labelRow)
    }

    private var sunLabels: some View {
        GeometryReader { geo in
            ForEach([sunrise, sunset].compactMap { $0 }, id: \.text) { label in
                Text(label.text)
                    .font(AppFont.caption2.monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
                    // An axis label stays on one line; the scaled
                    // inset keeps it inside the card.
                    .fixedSize()
                    .position(x: Self.labelX(label.at, width: geo.size.width, inset: timeInset), y: labelRow / 2)
            }
        }
        .frame(height: labelRow)
    }

    private var sunTimesText: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            ForEach([sunset, sunrise].compactMap { $0 }.sorted { $0.at < $1.at }, id: \.text) { label in
                Text(label.text)
                    .font(AppFont.caption2.monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - helpers

    static func color(_ phase: LightBand.Phase) -> Color {
        switch phase {
        case .day: AppColor.skyDay
        case .civil: AppColor.skyCivil
        case .nautical: AppColor.skyNautical
        case .astronomical: AppColor.skyAstronomical
        case .night: AppColor.skyNight
        }
    }

    /// Kept inside the band so the outer labels don't get cut.
    private static func labelX(_ fraction: Double, width: CGFloat, inset: CGFloat) -> CGFloat {
        min(max(CGFloat(fraction) * width, inset), width - inset)
    }

    /// The hour in the device's clock: „6“ with a 24-hour clock, „6 AM“
    /// with a 12-hour one.
    /// In `zone`, the sample's: the axis matches its times, not the
    /// device's zone.
    static func hourLabel(_ date: Date, zone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        let twelve = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false
        if twelve {
            f.setLocalizedDateFormatFromTemplate("ha")
        } else {
            f.dateFormat = "H"
        }
        return f.string(from: date)
    }
}

/// The sun as a disk with a soft glow.
struct SunGlyph: View {
    var body: some View {
        ZStack {
            Circle().fill(AppColor.skySun.opacity(0.35)).scaleEffect(1.6)
            Circle().fill(AppColor.skySun)
        }
        .accessibilityHidden(true)
    }
}

/// The moon as a stylised crescent. Its phase is in the line under the
/// band („· 78 %“); a phase disk on the moon line looked like a slider.
struct MoonGlyph: View {
    var body: some View {
        Image(systemName: "moon.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(AppColor.skyMoonCrescent)
            .accessibilityHidden(true)
    }
}
