@testable import LegulusGeo
import XCTest

/// Same inputs and expectations as
/// `tabularius/internal/conditions/instant_test.go`: app and backend
/// must ask Tempus for the same instant.
final class ConditionsQueryTests: XCTestCase {
    private func time(_ s: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(f.date(from: s))
    }

    func testInstant() throws {
        let cases: [(name: String, begin: String, zone: String, allDay: Bool, night: Bool, want: String)] = [
            ("timed sample keeps its begin", "2026-07-01T09:07:30Z", "Europe/Berlin", false, false, "2026-07-01T09:07:30Z"),
            ("all-day summer is 14:00 local", "2026-06-30T22:00:00Z", "Europe/Berlin", true, false, "2026-07-01T12:00:00Z"),
            ("all-day winter is 14:00 local", "2026-01-14T23:00:00Z", "Europe/Berlin", true, false, "2026-01-15T13:00:00Z"),
            ("all-day night trip is 22:00 local", "2026-06-30T22:00:00Z", "Europe/Berlin", true, true, "2026-07-01T20:00:00Z"),
            ("all-day on the DST switch day", "2026-03-28T23:00:00Z", "Europe/Berlin", true, false, "2026-03-29T12:00:00Z"),
            ("all-day far from UTC stays on the local day", "2026-11-16T11:00:00Z", "Pacific/Auckland", true, false, "2026-11-17T01:00:00Z"),
            ("unknown zone falls back to UTC", "2026-07-01T00:00:00Z", "Nicht/Da", true, false, "2026-07-01T14:00:00Z"),
            ("empty zone falls back to UTC", "2026-07-01T00:00:00Z", "", true, true, "2026-07-01T22:00:00Z"),
            ("night without all-day keeps the begin", "2026-07-01T09:07:30Z", "Europe/Berlin", false, true, "2026-07-01T09:07:30Z")
        ]
        for c in cases {
            let got = try ConditionsQuery.instant(
                begin: time(c.begin), timezone: c.zone, isAllDay: c.allDay, night: c.night
            )
            XCTAssertEqual(got, try time(c.want), c.name)
        }
    }

    func testInstant_TruncatesToSeconds() throws {
        let begin = try time("2026-07-01T09:07:30Z").addingTimeInterval(0.75)
        let got = ConditionsQuery.instant(begin: begin, timezone: "Europe/Berlin", isAllDay: false, night: false)
        XCTAssertEqual(got, try time("2026-07-01T09:07:30Z"))
    }

    func testSameInstant() throws {
        let a = try time("2026-07-01T09:07:30Z")
        XCTAssertTrue(ConditionsQuery.sameInstant(a, a.addingTimeInterval(0.4)))
        XCTAssertFalse(ConditionsQuery.sameInstant(a, a.addingTimeInterval(1)))
        XCTAssertFalse(ConditionsQuery.sameInstant(a, nil))
        XCTAssertFalse(ConditionsQuery.sameInstant(nil, nil))
    }

    func testIsFinalAge() throws {
        let instant = try time("2026-07-01T12:00:00Z")
        XCTAssertTrue(ConditionsQuery.isFinalAge(instant: instant, fetchedAt: instant.addingTimeInterval(120 * 3600)))
        XCTAssertFalse(ConditionsQuery.isFinalAge(instant: instant, fetchedAt: instant.addingTimeInterval(119 * 3600 + 59 * 60)))
        XCTAssertFalse(ConditionsQuery.isFinalAge(instant: instant, fetchedAt: instant.addingTimeInterval(-3600)))
    }

    /// Tempus requires the height and tells whole metres apart. Without
    /// a source the sample has none (a stored 0 is no height then).
    func testElevationMetres() {
        XCTAssertEqual(ConditionsQuery.elevationMetres(519.6, hasSource: true), 520)
        XCTAssertEqual(ConditionsQuery.elevationMetres(0, hasSource: true), 0)
        XCTAssertEqual(ConditionsQuery.elevationMetres(-500, hasSource: true), -500)
        XCTAssertEqual(ConditionsQuery.elevationMetres(9000, hasSource: true), 9000)
        XCTAssertNil(ConditionsQuery.elevationMetres(520, hasSource: false))
        XCTAssertNil(ConditionsQuery.elevationMetres(nil, hasSource: true))
        XCTAssertNil(ConditionsQuery.elevationMetres(-501, hasSource: true))
        XCTAssertNil(ConditionsQuery.elevationMetres(9001, hasSource: true))
    }
}
