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
    /// What „provisional“ means here, for the weather line: until when
    /// the model data may still change, or that something is missing.
    var provisionalNote: String?
    /// Text for the WMO code, e.g. „Leichter Regen“.
    var weatherTitle: String?
    /// SF Symbol for the WMO code.
    var weatherSymbol: String?
    /// „18°C“
    var temperature: String?
    var temperatureSpoken: String?
    /// The tiles of the section, in this order: wind, cloud cover,
    /// humidity (the hourly ones, not for an all-day sample),
    /// precipitation of the last 72 h.
    var tiles: [WeatherTile] = []
    /// Köppen-Geiger climate code, e.g. „Cfb“.
    var koppen: String?
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
        switch Self.provisionalReason(conditions) {
        case let .young(finalFrom):
            provisionalNote = String(localized: "Wetterwerte vorläufig bis \(Self.dayMonth(finalFrom, zone: zone))")
        case .incomplete:
            provisionalNote = String(localized: "Unvollständig, wird nachgeholt")
        case nil:
            break
        }

        var hasHourly = false
        if !sample.isAllDay {
            hasHourly = fillHourly(conditions, features: features)
        }
        if let rain = conditions.number("precipitation_72h_mm") {
            let value = Self.number(rain, digits: 1)
            tiles.append(WeatherTile(
                id: "precipitation72", value: value, unit: "mm", caption: String(localized: "72\(Self.nbsp)h"), word: nil,
                spoken: String(localized: "Niederschlag der letzten 72 Stunden \(value) Millimeter")
            ))
        }
        koppen = conditions.text("climate_koppen_code")
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
                if !Self.hasDayValues(conditions) { note = String(localized: "Keine Wetterdaten für diesen Tag") }
            } else if weatherTitle == nil, temperature == nil, !hasHourly {
                note = String(localized: "Keine Daten für diesen Zeitpunkt")
            }
        }
        // Day values the card doesn't show live on the detail page, which
        // needs the features; until they are there, the card would stand
        // empty without saying why.
        if note == nil, tiles.isEmpty, weatherTitle == nil, temperature == nil, features.isEmpty,
           Self.hasDayValues(conditions)
        {
            note = String(localized: "Weitere Tageswerte erscheinen unter „Details“, sobald die Daten abgeglichen sind.")
        }
    }

    /// Nothing at all to show besides the state.
    var isEmpty: Bool {
        temperature == nil && weatherTitle == nil && tiles.isEmpty && koppen == nil && sunrise == nil && sunset == nil
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
                items.append(SkyItem(
                    id: "sunrise",
                    symbol: "sunrise",
                    value: sunrise,
                    spoken: String(localized: "Sonnenaufgang \(sunrise) Uhr")
                ))
            }
            if let sunset {
                items.append(SkyItem(
                    id: "sunset",
                    symbol: "sunset",
                    value: sunset,
                    spoken: String(localized: "Sonnenuntergang \(sunset) Uhr")
                ))
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
            // Whole degrees, written together: „16°C“; the details keep
            // the decimal.
            temperature = Self.number(t, digits: 0) + "°C"
            temperatureSpoken = String(localized: "\(Self.number(t, digits: 0)) Grad Celsius")
        }
        let before = tiles.count
        if let wind = c.number("weather_wind_speed_kmh") {
            // The force of the speed as shown, so word and number agree.
            let force = WeatherWording.beaufort(kmh: wind.rounded())
            let speed = Self.number(wind, digits: 0)
            tiles.append(WeatherTile(
                id: "wind", value: speed, unit: "km/h", caption: String(localized: "Wind"), word: force,
                spoken: String(localized: "Wind \(force), \(speed) Kilometer pro Stunde")
            ))
        }
        if let clouds = c.number("weather_cloud_cover_pct") {
            let value = Self.number(clouds, digits: 0)
            tiles.append(WeatherTile(
                id: "clouds", value: value, unit: "%", caption: String(localized: "Wolken"), word: nil,
                spoken: String(localized: "Bewölkung \(value) Prozent")
            ))
        }
        let feeling = c.number("weather_dew_point_c").map { WeatherWording.humidityFeeling(dewPointC: $0) }
        let percent = c.number("weather_humidity_pct").map { Self.number($0, digits: 0) }
        if let value = percent ?? feeling {
            let spoken = [feeling, percent.map { String(localized: "\($0) Prozent") }].compactMap { $0 }.joined(separator: ", ")
            // Without a percentage the feeling itself is the value.
            tiles.append(WeatherTile(
                id: "humidity", value: value, unit: percent == nil ? nil : "%", caption: String(localized: "Feuchte"),
                word: percent == nil ? nil : feeling, spoken: String(localized: "Luftfeuchte \(spoken)")
            ))
        }
        return tiles.count > before || c.number("weather_precipitation_mm") != nil
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
            var spoken = String(localized: "Mond: \(phase)")
            if let illumination {
                value += ", " + illumination + Self.nbsp + "%"
                spoken += ", " + String(localized: "\(illumination) Prozent beleuchtet")
            }
            moon = Pair(id: "moon", label: String(localized: "Mond"), value: value, spoken: spoken)
        } else if let illumination {
            // The percentage alone, when Tempus sent no phase text.
            moon = Pair(
                id: "moon", label: String(localized: "Mond"),
                value: illumination + Self.nbsp + "% " + String(localized: "beleuchtet"),
                spoken: String(localized: "Mond: \(illumination) Prozent beleuchtet")
            )
        }
        if moon != nil { moonSymbol = Self.moonSymbol(phase: phase) }
        sunrise = c.date("sunrise").map { Self.time($0, zone: zone) }
        sunset = c.date("sunset").map { Self.time($0, zone: zone) }
    }

    // MARK: - provisional

    /// Why an answer is provisional. Only the weather is: sun, moon and
    /// climate are computed or climatological and don't change.
    enum ProvisionalReason: Equatable {
        /// The instant was younger than `ConditionsQuery.finalAfter` when
        /// fetched: the weather comes from model data that is still being
        /// revised; final from the given date (the backend's job asks again).
        case young(finalFrom: Date)
        /// A provider was unavailable: values are missing and asked again.
        case incomplete
    }

    static func provisionalReason(_ c: SampleConditions) -> ProvisionalReason? {
        guard c.status == .provisional else { return nil }
        if let instant = c.queriedFor, let fetchedAt = c.fetchedAt,
           !ConditionsQuery.isFinalAge(instant: instant, fetchedAt: fetchedAt)
        {
            return .young(finalFrom: instant.addingTimeInterval(ConditionsQuery.finalAfter))
        }
        return .incomplete
    }

    /// „24.05.“ in `zone`.
    static func dayMonth(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = "dd.MM."
        return f.string(from: date)
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
        case 0: String(localized: "Klar")
        case 1, 2: String(localized: "Leicht bewölkt")
        case 3: String(localized: "Bedeckt")
        case 45, 48: String(localized: "Nebel")
        case 51 ... 57: String(localized: "Nieselregen")
        case 61 ... 67, 80 ... 82: String(localized: "Regen")
        case 71 ... 77, 85, 86: String(localized: "Schnee")
        case 95 ... 99: String(localized: "Gewitter")
        default: String(localized: "Wettercode \(code)")
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

/// One tile of „Wetter und Klima“: a value large, its unit, a caption
/// and, where there is one, a word („leichte Brise“, „schwül“).
/// `spoken` is the VoiceOver text with the unit written out.
struct WeatherTile: Equatable, Identifiable {
    let id: String
    let value: String
    let unit: String?
    let caption: String
    let word: String?
    let spoken: String
}
