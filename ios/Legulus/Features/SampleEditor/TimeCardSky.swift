import Foundation

/// What the „Zeit“ card shows of the sky (variant T2): the light band,
/// sunrise and sunset under it, the lines about sun and moon and the
/// summary for VoiceOver. Without sun times (polar day or night) only the
/// lines; nil without Tempus values or when there is nothing to show.
struct TimeCardSky: Equatable {
    let band: LightBand
    let markers: SkyMarkers
    let sunrise: Label?
    let sunset: Label?
    /// „Sonne 18° hoch, S“, „Mond unter dem Horizont · Aufgang 13:20“.
    let facts: [String]
    let accessibilityText: String

    /// False without sun times (polar day or night): no band, the lines
    /// about sun and moon still show.
    var showsBand: Bool {
        !band.segments.isEmpty
    }

    struct Label: Equatable {
        let text: String
        /// Position on the band, 0 … 1.
        let at: Double
    }

    init?(display: ConditionsDisplay, begin: Date, end: Date?, isAllDay: Bool,
          zone: TimeZone, locale: Locale = .autoupdatingCurrent)
    {
        guard display.state == .values else { return nil }
        // Twilight and night put the night in the middle of the band.
        let nightCentered = display.lightPhase.map { $0 != .day } ?? false
        let band = LightBand(begin: begin, end: end, isAllDay: isAllDay, events: display.skyEvents,
                             zone: zone, nightCentered: nightCentered)
        self.band = band
        // By day the moon is left out, at night the sun; twilight
        // shows both.
        markers = SkyMarkers(sunIsUp: display.sunIsUp && display.showsSun,
                             moonIsUp: display.moonIsUp && display.showsMoon,
                             showsMoon: display.showsMoon)
        facts = [display.showsSun ? display.sunFact : nil, display.showsMoon ? display.moonFact : nil]
            .compactMap { $0 }
        guard !band.segments.isEmpty || !facts.isEmpty else { return nil }

        // Sunrise and sunset are the edges of the day stretches inside
        // the band.
        func clock(_ fraction: Double) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = zone
            f.setLocalizedDateFormatFromTemplate("jmm")
            return f.string(from: band.date(at: fraction))
        }
        let days = band.segments.filter { $0.phase == .day }
        let rise = days.map(\.from).first { $0 > 0 }
        let set = days.map(\.to).first { $0 < 1 }
        sunrise = rise.map { Label(text: "↑ " + clock($0), at: $0) }
        sunset = set.map { Label(text: "↓ " + clock($0), at: $0) }

        var spoken: [String] = []
        if let begin = band.begin, let phase = band.segments.first(where: { $0.from <= begin && begin <= $0.to })?.phase {
            spoken.append(Self.spoken(phase))
        }
        if let rise { spoken.append(String(localized: "Sonnenaufgang \(clock(rise))")) }
        if let set { spoken.append(String(localized: "Sonnenuntergang \(clock(set))")) }
        accessibilityText = spoken.joined(separator: ", ")
    }

    private static func spoken(_ phase: LightBand.Phase) -> String {
        switch phase {
        case .day: String(localized: "Probe am Tag")
        case .civil: String(localized: "Probe in der bürgerlichen Dämmerung")
        case .nautical: String(localized: "Probe in der nautischen Dämmerung")
        case .astronomical: String(localized: "Probe in der astronomischen Dämmerung")
        case .night: String(localized: "Probe in der Nacht")
        }
    }
}
