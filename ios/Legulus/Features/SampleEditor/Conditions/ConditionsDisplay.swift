import Foundation
import LegulusGeo

/// What the sample view shows of the sample's conditions: in „Wetter
/// und Klima“ the state, the weather and a compact summary; next to the
/// date sun and moon (by light phase); at the place the altitudinal
/// belt. Built from the sample's stored values and weather features;
/// pure, so the texts are tested without a view.
///
/// Values count only while they fit the sample (coordinate, height,
/// instant — `ConditionsRequest.fits`). An all-day sample shows day
/// values only: the hourly weather of 14:00 says little about a day.
struct ConditionsDisplay: Equatable {
    enum State: Equatable {
        /// No coordinate: nothing to ask Tempus with.
        case noCoordinate
        /// Coordinate there, but no usable height yet.
        case waitingForElevation
        /// Asked or about to be asked (the sync does it), no answer yet.
        case pending
        /// A sample from before Phase T that was never processed.
        case legacy
        case values
    }

    /// One labelled value; `spoken` is the VoiceOver text with the unit
    /// written out.
    typealias Pair = LabeledValue

    /// Where the sun stood at the sample's instant: day until the end of
    /// civil twilight (above -6°), twilight during nautical twilight
    /// (-6° to -12°), night from astronomical twilight on.
    enum LightPhase: Equatable {
        case day, twilight, night
    }

    var state: State
    /// The answer will be replaced (forecast data, or a provider was
    /// unavailable).
    var isProvisional = false
    /// Text for the WMO code, e.g. „Leichter Regen“.
    var weatherTitle: String?
    /// SF Symbol for the WMO code.
    var weatherSymbol: String?
    /// „18,4 °C“
    var temperature: String?
    var temperatureSpoken: String?
    /// The compact values of the section, in this order: wind, cloud
    /// cover, humidity (the hourly ones, not for an all-day sample),
    /// precipitation of the last 72 h, Köppen code.
    var summary: [Pair] = []
    /// „07:31“ in the sample's zone.
    var sunrise: String?
    var sunset: String?
    /// „Vollmond, 98 %“
    var moon: Pair?
    /// SF Symbol for the moon's phase.
    var moonSymbol: String?
    /// „submontan-kollin“; shown with the place.
    var altitudinalBelt: String?
    /// nil when neither sun times nor twilight are known.
    var lightPhase: LightPhase?
    /// „Keine Daten für diesen Zeitpunkt“ when a final answer of a
    /// sample with a time of day has no weather; „Keine Wetterdaten für
    /// diesen Tag“ when an all-day sample has no day values.
    var note: String?

    static let locale = Locale(identifier: "de_DE")

    /// No-break space between a number and its unit, so a value never
    /// wraps between the two („34,0 mm“).
    static let nbsp = "\u{00A0}"

    init(state: State) {
        self.state = state
    }

    /// - Parameter night: the sample's fieldtrip is a night fieldtrip
    ///   (decides the instant of an all-day sample).
    init(sample: LocalSample, night: Bool, features: [LocalSampleFeature]) {
        guard sample.latitude != nil, sample.longitude != nil else {
            self.init(state: .noCoordinate)
            return
        }
        let request = ConditionsRequest(sample, night: night)
        guard let conditions = sample.conditions, conditions.hasAnswer,
              let request, request.fits(conditions)
        else {
            if request == nil {
                self.init(state: .waitingForElevation)
            } else if sample.conditions == nil, !(sample.backendId ?? "").isEmpty, sample.syncStatus == .synced {
                // On the server and never processed there.
                self.init(state: .legacy)
            } else {
                self.init(state: .pending)
            }
            return
        }
        self.init(state: .values)
        // Features of another answer say nothing about these values.
        let features = conditions.holdsItsFeatures ? features : []
        isProvisional = conditions.status == .provisional
        let zone = TimeZone(identifier: sample.timezone) ?? .gmt

        var hasHourly = false
        if !sample.isAllDay {
            hasHourly = fillHourly(conditions, features: features)
        }
        add(&summary, "precipitation72", "Niederschlag 72\(Self.nbsp)h", conditions.number("precipitation_72h_mm"),
            digits: 1, unit: "mm", spokenUnit: "Millimeter", spokenLabel: "Niederschlag der letzten 72 Stunden")
        if let koppen = conditions.text("climate_koppen_code") {
            summary.append(Pair(id: "koppen", label: "Köppen", value: koppen, spoken: "Köppen-Klima \(koppen)"))
        }
        altitudinalBelt = conditions.text("climate_altitudinal_belt")
        fillSky(conditions, zone: zone)
        lightPhase = sample.isAllDay
            ? (night ? .night : .day)
            : Self.lightPhase(at: request.instant, conditions: conditions, features: features)
        // A final answer without what this kind of sample shows as
        // weather: its hourly values (the code's text counts), or the
        // day values of an all-day sample.
        if conditions.status == .final {
            if sample.isAllDay {
                if !Self.hasDayValues(conditions) { note = "Keine Wetterdaten für diesen Tag" }
            } else if weatherTitle == nil, temperature == nil, !hasHourly {
                note = "Keine Daten für diesen Zeitpunkt"
            }
        }
    }

    /// Nothing at all to show besides the state.
    var isEmpty: Bool {
        temperature == nil && weatherTitle == nil && summary.isEmpty && sunrise == nil && sunset == nil
            && moon == nil && altitudinalBelt == nil
    }

    /// Sun times belong to the day and to twilight; unknown phase shows
    /// what there is.
    var showsSun: Bool {
        lightPhase != .night
    }

    /// The moon belongs to the night and to twilight.
    var showsMoon: Bool {
        lightPhase != .day
    }

    /// One entry next to the date: an SF Symbol and its value.
    struct SkyItem: Equatable, Identifiable {
        let id: String
        let symbol: String
        let value: String
        let spoken: String
    }

    /// Sunrise and sunset by day, the moon by night, all of it in
    /// twilight.
    var skyItems: [SkyItem] {
        var items: [SkyItem] = []
        if showsSun {
            if let sunrise {
                items.append(SkyItem(id: "sunrise", symbol: "sunrise", value: sunrise, spoken: "Sonnenaufgang \(sunrise) Uhr"))
            }
            if let sunset {
                items.append(SkyItem(id: "sunset", symbol: "sunset", value: sunset, spoken: "Sonnenuntergang \(sunset) Uhr"))
            }
        }
        if showsMoon, let moon {
            items.append(SkyItem(id: "moon", symbol: moonSymbol ?? "moon", value: moon.value, spoken: moon.spoken))
        }
        return items
    }

    // MARK: - sections

    /// Weather line, wind, cloud cover, humidity. Returns whether any
    /// hourly value was there.
    private mutating func fillHourly(_ c: SampleConditions, features: [LocalSampleFeature]) -> Bool {
        if let code = c.number("weather_code") {
            weatherSymbol = Self.symbol(wmoCode: Int(code))
            weatherTitle = Self.weatherDescription(in: features) ?? Self.title(wmoCode: Int(code))
        }
        if let t = c.number("weather_temperature_c") {
            temperature = Self.number(t, digits: 1) + Self.nbsp + "°C"
            temperatureSpoken = Self.number(t, digits: 1) + " Grad Celsius"
        }
        let before = summary.count
        if let wind = c.number("weather_wind_speed_kmh") {
            let force = WeatherWording.beaufort(kmh: wind)
            let speed = Self.number(wind, digits: 0)
            summary.append(Pair(
                id: "wind", label: "Wind", value: "\(force) (\(speed)\(Self.nbsp)km/h)",
                spoken: "Wind \(force), \(speed) Kilometer pro Stunde"
            ))
        }
        add(&summary, "clouds", "Bewölkung", c.number("weather_cloud_cover_pct"), digits: 0, unit: "%",
            spokenUnit: "Prozent")
        let feeling = c.number("weather_dew_point_c").map { WeatherWording.humidityFeeling(dewPointC: $0) }
        let percent = c.number("weather_humidity_pct").map { Self.number($0, digits: 0) }
        if feeling != nil || percent != nil {
            let value = [feeling, percent.map { "(\($0)\(Self.nbsp)%)" }].compactMap { $0 }.joined(separator: " ")
            let spoken = [feeling, percent.map { "\($0) Prozent" }].compactMap { $0 }.joined(separator: ", ")
            // Without a feeling the bare percentage needs no brackets.
            summary.append(Pair(
                id: "humidity", label: "Luftfeuchte",
                value: feeling == nil ? (percent ?? "") + Self.nbsp + "%" : value,
                spoken: "Luftfeuchte \(spoken)"
            ))
        }
        return summary.count > before || c.number("weather_precipitation_mm") != nil
    }

    /// Whether the answer holds any value of the day (precipitation of
    /// the days before, day temperatures); the detail page shows them.
    private static func hasDayValues(_ c: SampleConditions) -> Bool {
        ["precipitation_24h_mm", "precipitation_72h_mm", "precipitation_120h_mm",
         "day_temperature_min_c", "day_temperature_max_c", "day_temperature_mean_c"]
            .contains { c.number($0) != nil }
    }

    private mutating func fillSky(_ c: SampleConditions, zone: TimeZone) {
        let illumination = c.number("moon_illumination_pct").map { Self.number($0, digits: 0) }
        let phase = c.text("moon_phase")
        if let phase {
            var value = phase
            var spoken = "Mond: \(phase)"
            if let illumination {
                value += ", " + illumination + Self.nbsp + "%"
                spoken += ", \(illumination) Prozent beleuchtet"
            }
            moon = Pair(id: "moon", label: "Mond", value: value, spoken: spoken)
        } else if let illumination {
            // The percentage alone, when Tempus sent no phase text.
            moon = Pair(
                id: "moon", label: "Mond", value: illumination + Self.nbsp + "% beleuchtet",
                spoken: "Mond: \(illumination) Prozent beleuchtet"
            )
        }
        if moon != nil { moonSymbol = Self.moonSymbol(phase: phase) }
        sunrise = c.date("sunrise").map { Self.time($0, zone: zone) }
        sunset = c.date("sunset").map { Self.time($0, zone: zone) }
    }

    private func add(
        _ pairs: inout [Pair], _ id: String, _ label: String, _ value: Double?,
        digits: Int, unit: String, spokenUnit: String, spokenLabel: String? = nil
    ) {
        guard let value else { return }
        let text = Self.number(value, digits: digits)
        pairs.append(Pair(
            id: id, label: label, value: text + Self.nbsp + unit,
            spoken: "\(spokenLabel ?? label) \(text) \(spokenUnit)"
        ))
    }

    // MARK: - light phase

    /// The light phase at `instant`. The sun's elevation of the stored
    /// sun feature is computed for exactly that instant and decides;
    /// without it the event times do.
    private static func lightPhase(
        at instant: Date, conditions c: SampleConditions, features: [LocalSampleFeature]
    ) -> LightPhase? {
        let sun = sunProperties(in: features)
        if let elevation = (sun?["elevationDeg"] as? NSNumber)?.doubleValue {
            return lightPhase(elevationDeg: elevation)
        }
        let twilight = twilightTimes(in: sun)
        return lightPhase(
            at: instant, sunrise: c.date("sunrise"), sunset: c.date("sunset"),
            civilDawn: twilight["civil.dawn"], civilDusk: twilight["civil.dusk"],
            nauticalDawn: twilight["nautical.dawn"], nauticalDusk: twilight["nautical.dusk"]
        )
    }

    /// Day above -6°, twilight down to -12°, night below.
    static func lightPhase(elevationDeg: Double) -> LightPhase {
        if elevationDeg > -6 { return .day }
        return elevationDeg > -12 ? .twilight : .night
    }

    /// Day between civil dawn and dusk, twilight between nautical and
    /// civil, night outside. A day without nautical times keeps the sun
    /// above -12° (summer far north): twilight, never night. Without
    /// twilight times, sunrise and sunset decide; without those, nil.
    ///
    /// Tempus computes the times for the UTC day of the instant, which
    /// far from Greenwich is not the local day: the intervals are also
    /// tried a day earlier and later.
    static func lightPhase(
        at t: Date, sunrise: Date?, sunset: Date?,
        civilDawn: Date?, civilDusk: Date?, nauticalDawn: Date?, nauticalDusk: Date?
    ) -> LightPhase? {
        if let civilDawn, let civilDusk {
            if t.isWithin(civilDawn, civilDusk) { return .day }
            guard let nauticalDawn, let nauticalDusk else { return .twilight }
            return t.isWithin(nauticalDawn, nauticalDusk) ? .twilight : .night
        }
        if let sunrise, let sunset {
            return t.isWithin(sunrise, sunset) ? .day : .night
        }
        return nil
    }

    private static let isoDate = ISO8601DateFormatter()
    private static let isoDateFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The properties of the stored `tempus:sun` feature.
    private static func sunProperties(in features: [LocalSampleFeature]) -> [String: Any]? {
        guard let feature = features.first(where: { $0.sourceID == FeatureScope.tempusPrefix + "sun" }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(feature.propertiesJSON.utf8)) as? [String: Any]
    }

    /// „civil.dawn“ … „nautical.dusk“ of the sun feature's properties.
    private static func twilightTimes(in sun: [String: Any]?) -> [String: Date] {
        guard let twilight = sun?["twilight"] as? [String: Any] else { return [:] }
        let iso = isoDate, isoFractional = isoDateFractional
        var times: [String: Date] = [:]
        for kind in ["civil", "nautical"] {
            guard let pair = twilight[kind] as? [String: Any] else { continue }
            for edge in ["dawn", "dusk"] {
                guard let text = pair[edge] as? String,
                      let date = iso.date(from: text) ?? isoFractional.date(from: text)
                else { continue }
                times["\(kind).\(edge)"] = date
            }
        }
        return times
    }

    /// SF Symbol for Tempus' phase name (its eight German names); the
    /// plain moon without a known name.
    static func moonSymbol(phase: String?) -> String {
        switch phase?.lowercased() {
        case "neumond": "moonphase.new.moon"
        case "zunehmende sichel": "moonphase.waxing.crescent"
        case "erstes viertel": "moonphase.first.quarter"
        case "zunehmender mond": "moonphase.waxing.gibbous"
        case "vollmond": "moonphase.full.moon"
        case "abnehmender mond": "moonphase.waning.gibbous"
        case "letztes viertel": "moonphase.last.quarter"
        case "abnehmende sichel": "moonphase.waning.crescent"
        default: "moon"
        }
    }

    // MARK: - formatting

    /// German number with a fixed count of decimals („18,4“, „0,0“).
    static func number(_ value: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.usesGroupingSeparator = false
        // -0,0 reads like a measuring error.
        let rounded = (value * pow(10, Double(digits))).rounded() / pow(10, Double(digits))
        return f.string(from: NSNumber(value: rounded == 0 ? 0 : rounded)) ?? String(value)
    }

    /// „07:31“ in `zone`.
    static func time(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// `weatherCodeDescription.de` of the stored weather feature.
    private static func weatherDescription(in features: [LocalSampleFeature]) -> String? {
        guard let feature = features.first(where: { $0.sourceID == FeatureScope.tempusPrefix + "weather" }),
              let json = try? JSONSerialization.jsonObject(with: Data(feature.propertiesJSON.utf8)) as? [String: Any],
              let description = json["weatherCodeDescription"] as? [String: Any],
              let text = description["de"] as? String, !text.isEmpty
        else { return nil }
        return text
    }

    /// The `attribution` texts of the features whose values are shown,
    /// in the order of the features, without duplicates.
    static func attribution(of features: [LocalSampleFeature], kinds: Set<String>) -> String? {
        var seen: Set<String> = []
        var texts: [String] = []
        for feature in features where kinds.contains(feature.layer) {
            guard let raw = feature.licenseJSON,
                  let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let text = json["attribution"] as? String, !text.isEmpty, seen.insert(text).inserted
            else { continue }
            texts.append(text)
        }
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }

    /// SF Symbol for a WMO weather code (table 4677 as Tempus uses it).
    static func symbol(wmoCode code: Int) -> String {
        switch code {
        case 0: "sun.max"
        case 1, 2: "cloud.sun"
        case 3: "cloud"
        case 45, 48: "cloud.fog"
        case 51 ... 57: "cloud.drizzle"
        case 61 ... 67, 80 ... 82: "cloud.rain"
        case 71 ... 77, 85, 86: "cloud.snow"
        case 95 ... 99: "cloud.bolt.rain"
        default: "cloud"
        }
    }

    /// Fallback text when the feature carries no description.
    static func title(wmoCode code: Int) -> String {
        switch code {
        case 0: "Klar"
        case 1, 2: "Leicht bewölkt"
        case 3: "Bedeckt"
        case 45, 48: "Nebel"
        case 51 ... 57: "Nieselregen"
        case 61 ... 67, 80 ... 82: "Regen"
        case 71 ... 77, 85, 86: "Schnee"
        case 95 ... 99: "Gewitter"
        default: "Wettercode \(code)"
        }
    }
}

private extension Date {
    /// Within `start ... end`, or that interval a day earlier or later.
    func isWithin(_ start: Date, _ end: Date) -> Bool {
        let day: TimeInterval = 86400
        return [-day, 0, day].contains { self >= start + $0 && self <= end + $0 }
    }
}
