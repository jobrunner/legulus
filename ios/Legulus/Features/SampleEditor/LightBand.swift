import Foundation

/// Sun and moon events around a sample's instant (Tempus' sun and moon
/// features). Tempus computes them for the UTC day of the instant, so a
/// time may lie a day off the local band; `LightBand` shifts it into
/// place.
struct SkyEvents: Equatable {
    var astronomicalDawn: Date?
    var nauticalDawn: Date?
    var civilDawn: Date?
    var sunrise: Date?
    var sunset: Date?
    var civilDusk: Date?
    var nauticalDusk: Date?
    var astronomicalDusk: Date?
    var moonrise: Date?
    var moonset: Date?
}

/// The 24 hours around a sample as a band of light phases: by day from
/// midnight to midnight, at night from noon to noon so the night lies in
/// the middle. Positions are fractions of the band (0 … 1). Pure, so the
/// geometry is tested without a view.
struct LightBand: Equatable {
    /// Brightest to darkest: sun above the horizon, then above -6°, -12°,
    /// -18°, below.
    enum Phase: Equatable, CaseIterable {
        case day, civil, nautical, astronomical, night
    }

    struct Segment: Equatable {
        let phase: Phase
        let from: Double
        let to: Double
    }

    /// Where the band begins (local noon or midnight) and ends, one
    /// calendar day later: 23 or 25 hours on a clock change.
    let start: Date
    let end: Date
    /// The sample's zone; the band's hours are its wall clock.
    let zone: TimeZone
    let nightCentered: Bool
    /// Left to right, neighbours of the same phase merged; empty without
    /// any sun times.
    let segments: [Segment]
    /// Stretches with the moon above the horizon.
    let moonUp: [ClosedRange<Double>]
    /// The sample's begin; nil for an all-day sample.
    let begin: Double?
    /// The sample's window; nil without end or for an all-day sample.
    let window: ClosedRange<Double>?

    private static let day: TimeInterval = 86400

    init(begin: Date, end: Date?, isAllDay: Bool, events: SkyEvents, zone: TimeZone, nightCentered: Bool) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = calendar.startOfDay(for: begin)
        let start: Date
        if nightCentered {
            // Built with the calendar: midnight + 12 h is 11:00 or 13:00
            // on a clock change.
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: midnight)
                ?? midnight.addingTimeInterval(12 * 3600)
            start = begin >= noon
                ? noon
                : calendar.date(byAdding: .day, value: -1, to: noon) ?? noon.addingTimeInterval(-Self.day)
        } else {
            start = midnight
        }
        let end24 = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(Self.day)
        self.start = start
        self.end = end24
        self.zone = zone
        self.nightCentered = nightCentered
        let length = end24.timeIntervalSince(start)
        func fraction(_ d: Date) -> Double {
            min(max(d.timeIntervalSince(start) / length, 0), 1)
        }

        let levels: [(Phase, Date?, Date?)] = [
            (.day, events.sunrise, events.sunset),
            (.civil, events.civilDawn, events.civilDusk),
            (.nautical, events.nauticalDawn, events.nauticalDusk),
            (.astronomical, events.astronomicalDawn, events.astronomicalDusk)
        ]
        let sunTimes = levels.flatMap { [$0.1, $0.2] }.compactMap { $0 }
        if sunTimes.isEmpty {
            segments = []
        } else {
            /// A level without times while a brighter one has them: the sun
            /// never sinks below it that day (e.g. no astronomical dusk in
            /// high summer up north). Otherwise it never reaches it.
            func covers(_ index: Int, _ m: Date) -> Bool {
                let (_, from, to) = levels[index]
                if let from, let to { return Self.isWithin(m, from, to) }
                return levels[..<index].contains { $0.1 != nil && $0.2 != nil }
            }
            func phase(at m: Date) -> Phase {
                for (index, level) in levels.enumerated() where covers(index, m) {
                    return level.0
                }
                return .night
            }
            segments = Self.runs(start: start, end: end24, events: sunTimes, classify: phase)
                .map { Segment(phase: $0.value, from: fraction($0.from), to: fraction($0.to)) }
        }

        if let rise = events.moonrise, let set = events.moonset {
            moonUp = Self.runs(start: start, end: end24, events: [rise, set]) { Self.isWithin($0, rise, set) }
                .filter(\.value)
                .map { fraction($0.from) ... fraction($0.to) }
        } else {
            moonUp = []
        }

        if isAllDay {
            self.begin = nil
            window = nil
        } else {
            self.begin = fraction(begin)
            window = end.flatMap { $0 > begin ? fraction(begin) ... fraction($0) : nil }
        }
    }

    /// The moment at `fraction` of the band.
    func date(at fraction: Double) -> Date {
        start.addingTimeInterval(fraction * end.timeIntervalSince(start))
    }

    /// Every six hours of the wall clock from the start, with their
    /// position: 0, 6, 12, 18, 24 (or 12 … 12 at night). On a clock
    /// change they are not evenly spaced.
    var hourMarks: [(date: Date, at: Double)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let base = calendar.dateComponents([.year, .month, .day, .hour], from: start)
        let length = end.timeIntervalSince(start)
        return (0 ... 4).compactMap { step in
            var c = base
            c.hour = (base.hour ?? 0) + 6 * step
            guard let date = calendar.date(from: c) else { return nil }
            return (date, min(max(date.timeIntervalSince(start) / length, 0), 1))
        }
    }

    /// `m` inside `from … to` (to on the next day when before from), or
    /// that interval a day earlier or later.
    private static func isWithin(_ m: Date, _ from: Date, _ to: Date) -> Bool {
        let to = to < from ? to.addingTimeInterval(day) : to
        return [-day, 0, day].contains { m >= from + $0 && m <= to + $0 }
    }

    /// Stretches of equal classification between the event times
    /// (shifted a day either way into the band), neighbours merged.
    private static func runs<Value: Equatable>(
        start: Date, end: Date, events: [Date], classify: (Date) -> Value
    ) -> [(value: Value, from: Date, to: Date)] {
        var cuts = Set<Date>()
        for event in events {
            for shift in [-day, 0, day] {
                let t = event.addingTimeInterval(shift)
                if t > start, t < end { cuts.insert(t) }
            }
        }
        let bounds = [start] + cuts.sorted() + [end]
        var result: [(value: Value, from: Date, to: Date)] = []
        for (from, to) in zip(bounds, bounds.dropFirst()) {
            let value = classify(from.addingTimeInterval(to.timeIntervalSince(from) / 2))
            if let last = result.last, last.value == value {
                result[result.count - 1].to = to
            } else {
                result.append((value, from, to))
            }
        }
        return result
    }

    /// German 16-point compass direction for an azimuth from north,
    /// clockwise.
    static func compass(_ azimuth: Double) -> String {
        let names = ["N", "NNO", "NO", "ONO", "O", "OSO", "SO", "SSO", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((azimuth.truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
        return names[(index + 16) % 16]
    }
}
