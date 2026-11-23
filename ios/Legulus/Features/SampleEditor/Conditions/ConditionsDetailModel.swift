import Foundation
import LegulusGeo

/// Everything Tempus delivered for a sample, for the detail page: the
/// stored weather features grouped by subject, each with its source.
/// It reads the features, not the sample columns, so values the compact
/// area does not show (twilight, growing degree days, the 19 BIO
/// variables …) appear too. Properties this app does not know are
/// listed under their own name.
struct ConditionsDetailModel: Equatable {
    struct Group: Equatable, Identifiable {
        let id: String
        let title: String
        let rows: [LabeledValue]
        /// Attribution texts of the group's features, without duplicates.
        let attribution: String?
        let licenseName: String?
        let licenseURL: URL?
    }

    var groups: [Group] = []
    /// The instant Tempus was asked for, in the sample's zone.
    var queriedFor: String?
    var fetchedAt: String?
    /// „Werte für 520 m über dem Meer“ — temperature and dew point are
    /// corrected to the height the query was made with.
    var elevationNote: String?
    var isProvisional = false
    /// Explains what is provisional and until when (see
    /// `ConditionsDisplay.ProvisionalReason`); nil for a final answer.
    var provisionalNote: String?

    /// Subjects in display order with the feature kinds they hold.
    private static let subjects: [(id: String, title: String, kinds: [String])] = [
        ("weather", "Wetter", ["weather", "dewpoint"]),
        ("aggregate", "Vortage und Tagessummen", ["aggregate"]),
        ("climate", "Klima", ["bioclim"]),
        ("sun", "Sonne", ["sun"]),
        ("moon", "Mond", ["moon"])
    ]

    /// Not values of their own.
    private static let skipped: Set<String> = ["kind", "provider", "units", "basedOn"]

    /// German names of the properties we know, by dotted path. The
    /// order here is the order on the page; unknown ones follow sorted.
    private static let names: [(path: String, label: String)] = [
        ("observedAt", "Zeitpunkt"),
        ("weatherCodeDescription", "Wetter"),
        ("weatherCode", "WMO-Code"),
        ("temperature2m", "Temperatur"),
        ("relativeHumidity2m", "Luftfeuchte"),
        ("dewPoint2m", "Taupunkt"),
        ("comfort", "Empfinden"),
        ("precipitation", "Niederschlag"),
        ("windSpeed10m", "Wind"),
        ("windBeaufort", "Windstärke (Beaufort)"),
        ("windBeaufortDescription", "Windstärke"),
        ("cloudCover", "Bewölkung"),
        ("isDay", "Tag"),
        ("precipitation.last24h", "Niederschlag 24 h"),
        ("precipitation.last72h", "Niederschlag 72 h"),
        ("precipitation.last120h", "Niederschlag 120 h"),
        ("temperatureDay.min", "Tagesminimum"),
        ("temperatureDay.max", "Tagesmaximum"),
        ("temperatureDay.mean", "Tagesmittel"),
        ("growingDegreeDays.base5", "Wärmesumme (Basis 5 °C)"),
        ("growingDegreeDays.base10", "Wärmesumme (Basis 10 °C)"),
        ("growingDegreeDays.since", "Wärmesumme seit"),
        ("arrheniusThermalTime.value", "Thermische Zeit (Arrhenius)"),
        ("koppen.code", "Köppen-Geiger"),
        ("koppen.de", "Klimatyp"),
        ("altitudinalBelt.belt", "Höhenstufe"),
        ("altitudinalBelt.thermotype.de", "Thermotyp"),
        ("altitudinalBelt.macrobioclimate.de", "Makrobioklima"),
        ("referencePeriod", "Referenzperiode"),
        ("sunrise", "Sonnenaufgang"),
        ("sunset", "Sonnenuntergang"),
        ("solarNoon", "Sonnenhöchststand"),
        ("dayLengthMinutes", "Tageslänge"),
        ("lightPhase", "Lichtphase"),
        ("twilight.civil.dawn", "Bürgerliche Dämmerung, Beginn"),
        ("twilight.civil.dusk", "Bürgerliche Dämmerung, Ende"),
        ("twilight.nautical.dawn", "Nautische Dämmerung, Beginn"),
        ("twilight.nautical.dusk", "Nautische Dämmerung, Ende"),
        ("twilight.astronomical.dawn", "Astronomische Dämmerung, Beginn"),
        ("twilight.astronomical.dusk", "Astronomische Dämmerung, Ende"),
        ("elevationDeg", "Höhe über dem Horizont"),
        ("azimuthDeg", "Azimut"),
        ("phase", "Mondphase"),
        ("illuminationPct", "Beleuchtet"),
        ("ageDays", "Mondalter"),
        ("moonrise", "Mondaufgang"),
        ("moonset", "Monduntergang"),
        ("distanceKm", "Entfernung")
    ]

    private static let nameByPath = Dictionary(uniqueKeysWithValues: names.map { ($0.path, $0.label) })
    private static let orderByPath = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1.path, $0) })

    init() {}

    /// - Parameter night: see `ConditionsDisplay`.
    init(sample: LocalSample, night: Bool, features: [LocalSampleFeature]) {
        // The page is the features: without the ones of this answer
        // (see `holdsItsFeatures`) there is nothing to show.
        guard let conditions = sample.conditions, conditions.hasAnswer, conditions.holdsItsFeatures,
              let request = ConditionsRequest(sample, night: night), request.fits(conditions)
        else { return }
        let zone = TimeZone(identifier: sample.timezone) ?? .gmt
        isProvisional = conditions.status == .provisional
        switch ConditionsDisplay.provisionalReason(conditions) {
        case let .young(finalFrom):
            let date = ConditionsDisplay.dayMonth(finalFrom, zone: zone)
            provisionalNote = String(localized: """
            Wetterwerte stammen aus Modelldaten, die bis fünf Tage nach dem Sammelzeitpunkt noch korrigiert werden; \
            endgültig ab \(date) Sonne, Mond und Klima sind endgültig.
            """)
        case .incomplete:
            provisionalNote = String(localized: "Ein Dienst war beim Abruf nicht erreichbar; fehlende Werte werden nachgeholt.")
        case nil:
            break
        }
        queriedFor = conditions.queriedFor.map { Self.dateTime($0, zone: zone) }
        fetchedAt = conditions.fetchedAt.map { Self.dateTime($0, zone: zone) }
        if let metres = conditions.inputs?.elevationMetres {
            elevationNote = String(localized: "Werte für \(metres) m über dem Meer")
        }
        for subject in Self.subjects {
            let own = subject.kinds.flatMap { kind in features.filter { $0.layer == kind } }
            guard !own.isEmpty else { continue }
            var rows: [(order: Int, path: String, row: LabeledValue)] = []
            for feature in own {
                guard let properties = Self.object(feature.propertiesJSON) else { continue }
                let units = properties["units"] as? [String: Any] ?? [:]
                for (path, value) in Self.flatten(properties) {
                    let unit = units[Self.unitKey(for: path)] as? String
                    guard let text = Self.text(value, unit: unit, zone: zone) else { continue }
                    let label = Self.nameByPath[path] ?? path
                    rows.append((
                        Self.orderByPath[path] ?? Int.max, path,
                        LabeledValue(
                            id: feature.layer + "." + path, label: label, value: text.shown,
                            spoken: "\(label): \(text.spoken)"
                        )
                    ))
                }
            }
            let license = own.compactMap { $0.licenseJSON.flatMap(Self.object) }.first
            groups.append(Group(
                id: subject.id,
                title: subject.title,
                rows: rows.sorted { ($0.order, $0.path) < ($1.order, $1.path) }.map(\.row),
                attribution: ConditionsDisplay.attribution(of: own, kinds: Set(subject.kinds)),
                licenseName: license?["name"] as? String,
                licenseURL: (license?["url"] as? String).flatMap(URL.init(string:))
            ))
        }
    }

    var isEmpty: Bool {
        groups.isEmpty
    }

    // MARK: - reading the features

    private static func object(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    private static let languages: Set<String> = ["de", "en"]

    /// Leaves of the property tree as (dotted path, value). A text in
    /// several languages is one value, the German one: an object of
    /// language keys only (`{"de": …, "en": …}`) is a leaf, and next to
    /// a `de` key the `en` key of the same object is left out.
    private static func flatten(_ object: [String: Any], prefix: String = "") -> [(String, Any)] {
        var leaves: [(String, Any)] = []
        let hasGerman = object["de"] is String
        for (key, value) in object {
            if prefix.isEmpty, skipped.contains(key) { continue }
            if hasGerman, key == "en" { continue }
            let path = prefix.isEmpty ? key : prefix + "." + key
            if let nested = value as? [String: Any] {
                if let german = nested["de"] as? String, Set(nested.keys).isSubset(of: languages) {
                    leaves.append((path, german))
                } else {
                    leaves.append(contentsOf: flatten(nested, prefix: path))
                }
            } else if let list = value as? [Any], list.contains(where: { $0 is [String: Any] }) {
                // A list of objects: one block of rows per element. A
                // list of plain values stays one row (see `text`).
                for (index, element) in list.enumerated() {
                    leaves.append(contentsOf: flatten(["\(index)": element], prefix: path))
                }
            } else {
                leaves.append((path, value))
            }
        }
        return leaves
    }

    /// German number with as many decimals as it has, two at most.
    private static func number(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = ConditionsDisplay.locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Where Tempus files the unit of a property when it is not under
    /// the property's own path: several values share one key
    /// (`precipitation`, `temperature`), and the BIO variables are
    /// listed by their short name. Explicit on purpose — inheriting
    /// the parent's unit would label a count such as
    /// `growingDegreeDays.days` as a temperature sum.
    private static let unitKeys: [String: String] = {
        var keys = [
            "precipitation.last24h": "precipitation",
            "precipitation.last72h": "precipitation",
            "precipitation.last120h": "precipitation",
            "temperatureDay.min": "temperature",
            "temperatureDay.max": "temperature",
            "temperatureDay.mean": "temperature",
            "growingDegreeDays.base5": "growingDegreeDays",
            "growingDegreeDays.base10": "growingDegreeDays",
            "arrheniusThermalTime.value": "arrheniusThermalTime"
        ]
        // WorldClim: BIO 1, 2, 5–11 are temperatures, 12–14 and 16–19
        // precipitation sums; 3, 4 and 15 have units of their own.
        for n in [1, 2, 5, 6, 7, 8, 9, 10, 11] {
            keys["bio.bio\(n)"] = "temperature"
        }
        for n in [12, 13, 14, 16, 17, 18, 19] {
            keys["bio.bio\(n)"] = "precipitation"
        }
        for n in [3, 4, 15] {
            keys["bio.bio\(n)"] = "bio\(n)"
        }
        return keys
    }()

    private static func unitKey(for path: String) -> String {
        unitKeys[path] ?? path
    }

    /// Units VoiceOver reads written out; any other unit is read as it
    /// is shown.
    private static let spokenUnits: [String: String] = [
        "°C": "Grad Celsius", "%": "Prozent", "mm": "Millimeter", "km/h": "Kilometer pro Stunde",
        "min": "Minuten", "km": "Kilometer", "d": "Tage", "°": "Grad", "°C·d": "Gradtage"
    ]

    /// A value as shown and as VoiceOver reads it.
    private typealias Rendered = (shown: String, spoken: String)

    private static func text(_ value: Any, unit: String?, zone: TimeZone) -> Rendered? {
        switch value {
        case is NSNull:
            return nil
        case let number as NSNumber:
            // JSON booleans arrive as NSNumber too.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                let text = number.boolValue ? "ja" : "nein"
                return (text, text)
            }
            let text = Self.number(number.doubleValue)
            guard let unit else { return (text, text) }
            return (text + ConditionsDisplay.nbsp + unit, text + " " + (spokenUnits[unit] ?? unit))
        case let string as String:
            if string.isEmpty { return nil }
            if let date = isoDate(string) {
                return (dateTime(date, zone: zone), dateTime(date, zone: zone, spoken: true))
            }
            if let day = calendarDate(string) { return (day, day) }
            return (string, string)
        case let array as [Any]:
            let parts = array.compactMap { text($0, unit: nil, zone: zone) }
            guard !parts.isEmpty else { return nil }
            return (parts.map(\.shown).joined(separator: ", "), parts.map(\.spoken).joined(separator: ", "))
        default:
            return nil
        }
    }

    /// An RFC 3339 timestamp: with „Z“ or an offset, with or without
    /// fractional seconds. A calendar date alone is none (see
    /// `calendarDate`).
    private static func isoDate(_ text: String) -> Date? {
        guard text.count >= 20, text.contains("T") else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// „2026-01-01“ as „01.01.2026“. A calendar date has no time and
    /// no zone: the parts are reordered, never converted.
    private static func calendarDate(_ text: String) -> String? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }

    /// „01.07.2026 14:00“ in `zone`; spoken „01.07.2026, 14:00 Uhr“.
    static func dateTime(_ date: Date, zone: TimeZone, spoken: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = ConditionsDisplay.locale
        f.timeZone = zone
        f.dateFormat = spoken ? "dd.MM.yyyy, HH:mm 'Uhr'" : "dd.MM.yyyy HH:mm"
        return f.string(from: date)
    }
}
