import AVFoundation
@testable import Legulus
import XCTest

/// Objektivknöpfe und Zoomrad: Faktoren relativ zum Hauptobjektiv,
/// Anzeige nach Locale, Abbildung aufs Rad.
final class ZoomScaleTests: XCTestCase {
    private let triple = ZoomScale(deviceType: .builtInTripleCamera, switchOverFactors: [2, 6], minFactor: 1, maxFactor: 15)

    func testLensStops_Triple() {
        XCTAssertEqual(triple.lensStops, [1, 2, 6])
    }

    func testDisplayRelativeToMain() {
        XCTAssertEqual(triple.displayFactor(1), 0.5)
        XCTAssertEqual(triple.displayFactor(2), 1)
        XCTAssertEqual(triple.displayFactor(6), 3)
        XCTAssertEqual(triple.deviceFactor(display: 3), 6)
        XCTAssertEqual(triple.maxFactor, 10, "nie über maxZoom")
    }

    func testText_German() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(ZoomScale.text(0.5, locale: german), "0,5")
        XCTAssertEqual(ZoomScale.text(1, locale: german), "1×")
        XCTAssertEqual(ZoomScale.text(1.4, locale: german), "1,4×")
        XCTAssertEqual(ZoomScale.text(3, locale: german), "3×")
    }

    func testDialRoundTrip() {
        for factor: CGFloat in [1, 2, 3.7, 10] {
            XCTAssertEqual(triple.deviceFactor(dialPosition: triple.dialPosition(factor)), factor, accuracy: 0.001)
        }
        XCTAssertEqual(triple.dialPosition(1), 0)
        XCTAssertEqual(triple.dialPosition(10), 1)
        XCTAssertEqual(triple.deviceFactor(dialPosition: -1), 1)
        XCTAssertEqual(triple.deviceFactor(dialPosition: 2), 10)
    }

    func testStep() {
        XCTAssertEqual(triple.step(1, up: true), 2)
        XCTAssertEqual(triple.step(2, up: true), 3, accuracy: 0.001)
        XCTAssertEqual(triple.step(6, up: false), 4, accuracy: 0.001)
        XCTAssertEqual(triple.step(1, up: false), 1)
        XCTAssertEqual(triple.step(9, up: true), 10, "geklemmt")
    }

    func testWideOnly() {
        let wide = ZoomScale(deviceType: .builtInWideAngleCamera, switchOverFactors: [], minFactor: 1, maxFactor: 8)
        XCTAssertEqual(wide.lensStops, [1])
        XCTAssertEqual(wide.displayFactor(1), 1)
    }

    /// Makro läuft auf dem Ultraweitwinkel, auf den Hauptausschnitt
    /// beschnitten: dort heißt der Faktor 1×, Knöpfe gibt es keine.
    func testFixedLensScale() {
        let macro = ZoomScale(mainFactor: 2, minFactor: 1, maxFactor: 20)
        XCTAssertEqual(macro.displayFactor(2), 1)
        XCTAssertEqual(macro.lensStops, [])
        XCTAssertEqual(macro.maxFactor, 10)
    }

    func testSpokenText_German() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(ZoomScale.spokenText(1.4, locale: german), "1,4-fach")
        XCTAssertEqual(ZoomScale.spokenText(0.5, locale: german), "0,5-fach")
    }
}
