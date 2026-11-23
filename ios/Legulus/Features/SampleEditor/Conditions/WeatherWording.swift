import Foundation

/// Words for weather values that read better than the bare number:
/// the Beaufort force of the wind and how humid the air feels.
enum WeatherWording {
    /// Lower bounds of Beaufort forces 1 … 12 in m/s (WMO); a value on a
    /// bound belongs to the higher force.
    private static let beaufortBoundsMS: [Double] = [0.3, 1.6, 3.4, 5.5, 8.0, 10.8, 13.9, 17.2, 20.8, 24.5, 28.5, 32.7]

    /// Beaufort force 0 … 12 in the terms of the DWD.
    private static let beaufortNames: [String] = [
        String(localized: "Windstille"),
        String(localized: "leiser Zug"),
        String(localized: "leichte Brise"),
        String(localized: "schwache Brise"),
        String(localized: "mäßige Brise"),
        String(localized: "frische Brise"),
        String(localized: "starker Wind"),
        String(localized: "steifer Wind"),
        String(localized: "stürmischer Wind"),
        String(localized: "Sturm"),
        String(localized: "schwerer Sturm"),
        String(localized: "orkanartiger Sturm"),
        String(localized: "Orkan")
    ]

    /// „leichte Brise“ for 8 km/h.
    static func beaufort(kmh: Double) -> String {
        let ms = kmh / 3.6
        // 102.6 / 3.6 comes out a hair below 28.5: a value on a bound
        // must not slip a force down through floating point.
        let force = beaufortBoundsMS.count(where: { ms >= $0 - 1e-9 })
        return beaufortNames[force]
    }

    /// How humid the air feels, from the dew point in °C. The DWD has no
    /// graded scale (only „schwül“ from a dew point of about 17 °C); these
    /// steps follow the usual dew point comfort scales. A value on a
    /// bound belongs to the higher step.
    static func humidityFeeling(dewPointC: Double) -> String {
        switch dewPointC {
        case ..<10: String(localized: "trocken")
        case ..<13: String(localized: "angenehm")
        case ..<16: String(localized: "leicht feucht")
        case ..<18: String(localized: "feucht")
        case ..<21: String(localized: "schwül")
        case ..<24: String(localized: "sehr schwül")
        default: String(localized: "drückend")
        }
    }
}
