import Foundation
import LegulusGeo

/// What the sample view shows in „Wetter und Klima“: the state, the
/// formatted values and their sources. Built from the sample's stored
/// values and weather features; pure, so the texts are tested without a
/// view.
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
    /// Hourly values: humidity, dew point, wind, cloud cover,
    /// precipitation. Empty for an all-day sample.
    var hourly: [Pair] = []
    /// Precipitation of the days before and the day's temperatures.
    var daily: [Pair] = []
    /// Moon, sunrise, sunset (in the sample's zone).
    var sky: [Pair] = []
    /// Köppen code and altitudinal belt.
    var climate: Pair?
    /// „Keine Daten für diesen Zeitpunkt“ when a final answer of a
    /// sample with a time of day has no weather.
    var note: String?
    /// The sources of what is shown, without duplicates.
    var attribution: String?

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
        var shownKinds: Set = ["sun", "moon", "aggregate", "bioclim"]

        if !sample.isAllDay {
            shownKinds.formUnion(["weather", "dewpoint"])
            fillHourly(conditions, features: features)
        }
        fillDaily(conditions)
        fillSky(conditions, zone: zone)
        fillClimate(conditions)
        if !sample.isAllDay, conditions.status == .final, temperature == nil, hourly.isEmpty {
            note = "Keine Daten für diesen Zeitpunkt"
        }
        attribution = Self.attribution(of: features, kinds: shownKinds)
    }

    /// Nothing at all to show besides the state.
    var isEmpty: Bool {
        temperature == nil && weatherTitle == nil && hourly.isEmpty && daily.isEmpty && sky.isEmpty && climate == nil
    }

    // MARK: - sections

    private mutating func fillHourly(_ c: SampleConditions, features: [LocalSampleFeature]) {
        if let code = c.number("weather_code") {
            weatherSymbol = Self.symbol(wmoCode: Int(code))
            weatherTitle = Self.weatherDescription(in: features) ?? Self.title(wmoCode: Int(code))
        }
        if let t = c.number("weather_temperature_c") {
            temperature = Self.number(t, digits: 1) + Self.nbsp + "°C"
            temperatureSpoken = Self.number(t, digits: 1) + " Grad Celsius"
        }
        add(&hourly, "humidity", "Luftfeuchte", c.number("weather_humidity_pct"), digits: 0, unit: "%", spokenUnit: "Prozent")
        add(&hourly, "dewpoint", "Taupunkt", c.number("weather_dew_point_c"), digits: 1, unit: "°C", spokenUnit: "Grad Celsius")
        add(&hourly, "wind", "Wind", c.number("weather_wind_speed_kmh"), digits: 0, unit: "km/h",
            spokenUnit: "Kilometer pro Stunde")
        add(&hourly, "clouds", "Bewölkung", c.number("weather_cloud_cover_pct"), digits: 0, unit: "%", spokenUnit: "Prozent")
        add(&hourly, "precipitation", "Niederschlag", c.number("weather_precipitation_mm"), digits: 1, unit: "mm",
            spokenUnit: "Millimeter")
    }

    private mutating func fillDaily(_ c: SampleConditions) {
        for (hours, field) in [(24, "precipitation_24h_mm"), (72, "precipitation_72h_mm"), (120, "precipitation_120h_mm")] {
            add(&daily, "precipitation\(hours)", "Niederschlag \(hours)\(Self.nbsp)h", c.number(field), digits: 1, unit: "mm",
                spokenUnit: "Millimeter", spokenLabel: "Niederschlag der letzten \(hours) Stunden")
        }
        if let min = c.number("day_temperature_min_c"), let max = c.number("day_temperature_max_c") {
            let range = Self.number(min, digits: 1) + " – " + Self.number(max, digits: 1)
            daily.append(Pair(
                id: "dayRange", label: "Tag", value: range + Self.nbsp + "°C",
                spoken: "Tagestemperatur \(Self.number(min, digits: 1)) bis \(Self.number(max, digits: 1)) Grad Celsius"
            ))
        }
        add(&daily, "dayMean", "Tagesmittel", c.number("day_temperature_mean_c"), digits: 1, unit: "°C",
            spokenUnit: "Grad Celsius")
    }

    private mutating func fillSky(_ c: SampleConditions, zone: TimeZone) {
        if let phase = c.text("moon_phase") {
            var value = phase
            var spoken = "Mond: \(phase)"
            if let pct = c.number("moon_illumination_pct") {
                value += ", " + Self.number(pct, digits: 0) + Self.nbsp + "%"
                spoken += ", \(Self.number(pct, digits: 0)) Prozent beleuchtet"
            }
            sky.append(Pair(id: "moon", label: "Mond", value: value, spoken: spoken))
        }
        for (id, label, field) in [("sunrise", "Sonnenaufgang", "sunrise"), ("sunset", "Sonnenuntergang", "sunset")] {
            guard let date = c.date(field) else { continue }
            let time = Self.time(date, zone: zone)
            sky.append(Pair(id: id, label: label, value: time, spoken: "\(label) \(time) Uhr"))
        }
    }

    private mutating func fillClimate(_ c: SampleConditions) {
        let parts = [c.text("climate_koppen_code"), c.text("climate_altitudinal_belt")].compactMap { $0 }
        guard !parts.isEmpty else { return }
        var spoken: [String] = []
        if let koppen = c.text("climate_koppen_code") { spoken.append("Köppen-Klima \(koppen)") }
        if let belt = c.text("climate_altitudinal_belt") { spoken.append("Höhenstufe \(belt)") }
        climate = Pair(
            id: "climate", label: "Klima", value: parts.joined(separator: " · "),
            spoken: spoken.joined(separator: ", ")
        )
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
