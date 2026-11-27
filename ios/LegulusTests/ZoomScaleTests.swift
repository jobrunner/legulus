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
        XCTAssertEqual(triple.maxFactor, 6, "nur echter Zoom: bis zum Teleobjektiv")
    }

    func testText_German() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(ZoomScale.text(0.5, locale: german), "0,5")
        XCTAssertEqual(ZoomScale.text(1, locale: german), "1×")
        XCTAssertEqual(ZoomScale.text(1.4, locale: german), "1,4×")
        XCTAssertEqual(ZoomScale.text(3, locale: german), "3×")
    }

    func testDialRoundTrip() {
        for factor: CGFloat in [1, 2, 3.7, 6] {
            XCTAssertEqual(triple.deviceFactor(dialPosition: triple.dialPosition(factor)), factor, accuracy: 0.001)
        }
        XCTAssertEqual(triple.dialPosition(1), 0)
        XCTAssertEqual(triple.dialPosition(6), 1)
        XCTAssertEqual(triple.deviceFactor(dialPosition: -1), 1)
        XCTAssertEqual(triple.deviceFactor(dialPosition: 2), 6)
    }

    /// VoiceOver springt von Raststufe zu Raststufe.
    func testStep() {
        XCTAssertEqual(triple.step(1, up: true), 2)
        XCTAssertEqual(triple.step(2, up: true), 4)
        XCTAssertEqual(triple.step(2.4, up: true), 4)
        XCTAssertEqual(triple.step(4, up: true), 6)
        XCTAssertEqual(triple.step(6, up: true), 6)
        XCTAssertEqual(triple.step(3, up: false), 2)
        XCTAssertEqual(triple.step(1, up: false), 1)
    }

    /// Raststufen 0,5 / 1 / 2 / 3 als Gerätefaktoren.
    func testSnapStops_Triple() {
        XCTAssertEqual(triple.snapStops, [1, 2, 4, 6])
    }

    /// Mit 5×-Tele liegt das Teleobjektiv jenseits der festen Raststufen;
    /// es muss trotzdem eine Raststufe sein, sonst erreicht VoiceOver es nicht.
    func testSnapStops_IncludeLensesBeyondFixedStops() {
        let fiveX = ZoomScale(deviceType: .builtInTripleCamera, switchOverFactors: [2, 10], minFactor: 1, maxFactor: 20)
        XCTAssertEqual(fiveX.snapStops, [1, 2, 4, 6, 10])
        XCTAssertEqual(fiveX.step(6, up: true), 10)
    }

    func testSnap() {
        XCTAssertEqual(triple.snapped(2.05), 2, "nah an 1× rastet ein")
        XCTAssertEqual(triple.snapped(5), 5, "zwischen 2× und 3× frei")
        XCTAssertEqual(triple.snapped(4.1), 4, "2× rastet ein")
        XCTAssertEqual(triple.snapped(5.9), 6)
    }

    /// Ohne Tele endet der Zoom am Hauptobjektiv.
    func testOpticalMax_DualWide() {
        let dualWide = ZoomScale(deviceType: .builtInDualWideCamera, switchOverFactors: [2], minFactor: 1, maxFactor: 12)
        XCTAssertEqual(dualWide.maxFactor, 2)
        XCTAssertEqual(dualWide.snapStops, [1, 2])
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
        XCTAssertEqual(macro.maxFactor, 2, "Makro bis zum Hauptausschnitt, kein Digitalzoom darüber")
        XCTAssertEqual(ZoomScale(mainFactor: 1, minFactor: 1, maxFactor: 5).maxFactor, 1, "Fokus fest: kein Zoom")
    }

    func testSpokenText_German() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(ZoomScale.spokenText(1.4, locale: german), "1,4-fach")
        XCTAssertEqual(ZoomScale.spokenText(0.5, locale: german), "0,5-fach")
    }

    /// Am Rad tragen die Objektive nur die Zahl, das „×“ hat der aktuelle Wert.
    func testNumber_German() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(ZoomScale.number(0.5, locale: german), "0,5")
        XCTAssertEqual(ZoomScale.number(3, locale: german), "3")
        XCTAssertEqual(ZoomScale.number(1.44, locale: german), "1,4")
    }
}
