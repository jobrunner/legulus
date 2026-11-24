@testable import Legulus
import XCTest

/// Die Skala des Zoomrads: feine Striche teilen die Abschnitte zwischen
/// den Raststufen gleichmäßig, am Zeiger werden sie kürzer.
final class ZoomDialTests: XCTestCase {
    /// Jede Raststufe liegt genau auf einem feinen Strich.
    func testTickAngles_HitEveryMark() {
        let marks: [CGFloat] = [0, 0.7, 1.1]
        let ticks = ZoomDial.tickAngles(marks: marks, step: 0.1)
        for mark in marks {
            XCTAssertTrue(ticks.contains { abs($0 - mark) < 1e-9 }, "Raststufe \(mark) ohne Strich")
        }
        XCTAssertEqual(ticks.count, 12, "0…0,7 in 7 Teilen, 0,7…1,1 in 4 Teilen, plus Anfang")
    }

    func testTickAngles_EvenWithinASection() {
        let ticks = ZoomDial.tickAngles(marks: [0, 1], step: 0.3)
        // 1 / 0,3 ≈ 3,3 → 3 gleiche Teile.
        XCTAssertEqual(ticks.count, 4)
        XCTAssertEqual(ticks[1], 1.0 / 3, accuracy: 1e-9)
    }

    /// Unter dem Zeiger kein Strich, die direkten Nachbarn kurz, alle
    /// anderen voll.
    func testTickLength_ShortOnlyBesideThePointer() {
        let step: CGFloat = 0.04
        XCTAssertEqual(ZoomDial.tickLengthScale(distance: 0, step: step), 0)
        XCTAssertEqual(ZoomDial.tickLengthScale(distance: step * 0.4, step: step), 0)
        let neighbour = ZoomDial.tickLengthScale(distance: step, step: step)
        XCTAssertGreaterThan(neighbour, 0)
        XCTAssertLessThan(neighbour, 1)
        XCTAssertEqual(ZoomDial.tickLengthScale(distance: -step * 1.2, step: step), neighbour)
        XCTAssertEqual(ZoomDial.tickLengthScale(distance: step * 1.6, step: step), 1)
        XCTAssertEqual(ZoomDial.tickLengthScale(distance: step * 2, step: step), 1)
    }
}
