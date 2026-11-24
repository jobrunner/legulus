import AVFoundation
import CoreLocation
import ImageIO
@testable import Legulus
import XCTest

/// Die Teile der Kamera, die sich ohne Gerät prüfen lassen.
final class CameraSessionLogicTests: XCTestCase {
    /// Das virtuelle Mehrfach-Kameragerät zuerst: nur damit wechseln
    /// Zoom und Nahbereich (Makro) von selbst die Linse.
    func testPreferredDeviceTypes_VirtualDevicesFirst() {
        XCTAssertEqual(CameraSession.preferredDeviceTypes, [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ])
    }

    func testClampedZoom() {
        XCTAssertEqual(CameraSession.clampedZoom(0.2, min: 1, max: 15), 1)
        XCTAssertEqual(CameraSession.clampedZoom(3, min: 1, max: 15), 3)
        XCTAssertEqual(CameraSession.clampedZoom(20, min: 1, max: 15), 10, "nie über 10-fach")
        XCTAssertEqual(CameraSession.clampedZoom(8, min: 1, max: 5), 5)
        XCTAssertEqual(CameraSession.clampedZoom(.nan, min: 1, max: 5), 1)
    }

    func testPhotoSettings_AreJPEG() {
        let settings = CameraSession.photoSettings(flash: .off, supportedFlash: [.off], location: nil)
        XCTAssertEqual(settings.format?[AVVideoCodecKey] as? String, AVVideoCodecType.jpeg.rawValue)
    }

    func testPhotoSettings_FlashOnlyWhenSupported() {
        XCTAssertEqual(CameraSession.photoSettings(flash: .auto, supportedFlash: [.off, .auto, .on], location: nil).flashMode, .auto)
        XCTAssertEqual(CameraSession.photoSettings(flash: .auto, supportedFlash: [.off], location: nil).flashMode, .off)
        XCTAssertEqual(CameraSession.photoSettings(flash: .off, supportedFlash: [.off, .auto], location: nil).flashMode, .off)
    }

    func testPhotoSettings_CarryThePositionOfTheShot() throws {
        let without = CameraSession.photoSettings(flash: .off, supportedFlash: [.off], location: nil)
        XCTAssertNil(without.metadata[kCGImagePropertyGPSDictionary as String])

        let location = CLLocation(latitude: -33.856784, longitude: 10.031340)
        let with = CameraSession.photoSettings(flash: .off, supportedFlash: [.off], location: location)
        let gps = try XCTUnwrap(with.metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef as String] as? String, "S")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitude as String] as? Double, 10.031340)
    }

    /// On the virtual devices factor 1 is the ultra-wide lens. The
    /// camera opens on the main lens, like the system camera.
    func testInitialZoom_StartsOnTheMainLens() {
        XCTAssertEqual(CameraSession.initialZoom(deviceType: .builtInTripleCamera, switchOverFactors: [2, 6]), 2)
        XCTAssertEqual(CameraSession.initialZoom(deviceType: .builtInDualWideCamera, switchOverFactors: [2]), 2)
        XCTAssertEqual(
            CameraSession.initialZoom(deviceType: .builtInDualCamera, switchOverFactors: [2]),
            1,
            "Weitwinkel + Tele: 1 ist die Hauptlinse"
        )
        XCTAssertEqual(CameraSession.initialZoom(deviceType: .builtInWideAngleCamera, switchOverFactors: []), 1)
        XCTAssertEqual(CameraSession.initialZoom(deviceType: .builtInTripleCamera, switchOverFactors: []), 1)
    }

    // MARK: - Licht

    func testLightCycle_AllAvailable() {
        XCTAssertEqual(CameraLight.auto.next(hasFlash: true, hasTorch: true), .off)
        XCTAssertEqual(CameraLight.off.next(hasFlash: true, hasTorch: true), .torch)
        XCTAssertEqual(CameraLight.torch.next(hasFlash: true, hasTorch: true), .auto)
    }

    func testLightCycle_SkipsMissing() {
        XCTAssertEqual(CameraLight.off.next(hasFlash: true, hasTorch: false), .auto)
        XCTAssertEqual(CameraLight.auto.next(hasFlash: false, hasTorch: true), .off)
        XCTAssertEqual(CameraLight.torch.next(hasFlash: false, hasTorch: true), .off)
        XCTAssertEqual(CameraLight.off.next(hasFlash: false, hasTorch: false), .off)
    }

    func testLight_CaptureFlashMode() {
        XCTAssertEqual(CameraLight.auto.captureFlashMode, .auto)
        XCTAssertEqual(CameraLight.off.captureFlashMode, .off)
        XCTAssertEqual(CameraLight.torch.captureFlashMode, .off, "LED leuchtet schon, kein Blitz dazu")
    }

    func testLight_Labels() {
        XCTAssertEqual(CameraLight.auto.label, "Licht: automatischer Blitz")
        XCTAssertEqual(CameraLight.off.label, "Licht: aus")
        XCTAssertEqual(CameraLight.torch.label, "Licht: LED-Dauerlicht")
    }

    /// Die LED leuchtet nur, solange die Kamera sichtbar läuft: nicht im
    /// Hintergrund, nicht hinter dem Galerie-Picker, nicht nach dem Schließen.
    func testTorchOnlyWhileVisibleAndRunning() {
        XCTAssertTrue(CameraLight.torchShouldBeOn(.torch, sceneActive: true, pickerOpen: false, running: true))
        XCTAssertFalse(CameraLight.torchShouldBeOn(.torch, sceneActive: false, pickerOpen: false, running: true))
        XCTAssertFalse(CameraLight.torchShouldBeOn(.torch, sceneActive: true, pickerOpen: true, running: true))
        XCTAssertFalse(CameraLight.torchShouldBeOn(.torch, sceneActive: true, pickerOpen: false, running: false))
        XCTAssertFalse(CameraLight.torchShouldBeOn(.auto, sceneActive: true, pickerOpen: false, running: true))
    }

    // MARK: - Fokus-Stufen

    func testFocusCycle() {
        XCTAssertEqual(FocusStage.auto.next(macroAvailable: true), .fixed)
        XCTAssertEqual(FocusStage.fixed.next(macroAvailable: true), .macro)
        XCTAssertEqual(FocusStage.macro.next(macroAvailable: true), .auto)
        XCTAssertEqual(FocusStage.fixed.next(macroAvailable: false), .auto)
    }

    func testFocusStage_PhysicalLens() {
        XCTAssertNil(FocusStage.auto.physicalLens)
        XCTAssertEqual(FocusStage.fixed.physicalLens, .builtInWideAngleCamera)
        XCTAssertEqual(FocusStage.macro.physicalLens, .builtInUltraWideCamera)
    }

    func testFocusStage_Labels() {
        XCTAssertEqual(FocusStage.auto.label, "Fokus: automatisch")
        XCTAssertEqual(FocusStage.fixed.label, "Fokus fest")
        XCTAssertEqual(FocusStage.macro.label, "Makro")
    }

    func testSupportsMacro() {
        XCTAssertTrue(FocusStage.supportsMacro(minimumFocusDistanceMM: 20, customLensPosition: true))
        XCTAssertTrue(FocusStage.supportsMacro(minimumFocusDistanceMM: 50, customLensPosition: true))
        XCTAssertFalse(FocusStage.supportsMacro(minimumFocusDistanceMM: 51, customLensPosition: true))
        XCTAssertFalse(FocusStage.supportsMacro(minimumFocusDistanceMM: -1, customLensPosition: true), "-1 = unbekannt / Fixfokus")
        XCTAssertFalse(FocusStage.supportsMacro(minimumFocusDistanceMM: 20, customLensPosition: false))
    }

    /// Ein versehentliches Tippen verstellt den eingestellten Halm nicht.
    func testTapKeepsFocusInFixedStages() {
        XCTAssertEqual(FocusStage.auto.tapAction, .focusAndExpose)
        XCTAssertEqual(FocusStage.fixed.tapAction, .exposeOnly)
        XCTAssertEqual(FocusStage.macro.tapAction, .exposeOnly)
    }

    func testNoCaptureWhileSwitching() {
        XCTAssertTrue(CameraSession.canCapture(state: .running, isCapturing: false))
        XCTAssertFalse(CameraSession.canCapture(state: .switching, isCapturing: false))
        XCTAssertFalse(CameraSession.canCapture(state: .running, isCapturing: true))
        XCTAssertFalse(CameraSession.canCapture(state: .idle, isCapturing: false))
    }

    func testFocusValueText() {
        XCTAssertEqual(FocusStage.focusValueText(lensPosition: 0), "ganz nah")
        XCTAssertEqual(FocusStage.focusValueText(lensPosition: 0.3), "nah")
        XCTAssertEqual(FocusStage.focusValueText(lensPosition: 0.5), "mittel")
        XCTAssertEqual(FocusStage.focusValueText(lensPosition: 1), "fern")
    }

    // MARK: - Korrekturen aus dem Review

    /// Langer Druck: `isAdjustingFocus` wird erst einen Moment nach dem
    /// Setzen von `.autoFocus` wahr. Vorher gilt der Fokus nicht als fertig.
    func testFocusSettled_WaitsForTheLensToStart() {
        XCTAssertFalse(CameraSession.focusSettled(sawAdjusting: false, isAdjusting: false, elapsed: 0.02))
        XCTAssertFalse(CameraSession.focusSettled(sawAdjusting: true, isAdjusting: true, elapsed: 0.5))
        XCTAssertTrue(CameraSession.focusSettled(sawAdjusting: true, isAdjusting: false, elapsed: 0.3))
        XCTAssertTrue(CameraSession.focusSettled(sawAdjusting: false, isAdjusting: false, elapsed: 0.5), "Linse stand schon richtig")
        XCTAssertTrue(CameraSession.focusSettled(sawAdjusting: true, isAdjusting: true, elapsed: 2.1), "Zeitlimit")
    }

    /// Auf Geräten mit nur einem Objektiv ist die Auto-Kamera schon das
    /// Hauptobjektiv: Fokus fest geht ohne Tausch.
    func testSwitchPlan() {
        let both: Set<AVCaptureDevice.DeviceType> = [.builtInWideAngleCamera, .builtInUltraWideCamera]
        XCTAssertEqual(
            CameraSession.switchPlan(to: .fixed, autoDeviceType: .builtInTripleCamera, autoSupportsCustomLens: false, lenses: both),
            .swap(.builtInWideAngleCamera)
        )
        XCTAssertEqual(
            CameraSession.switchPlan(to: .auto, autoDeviceType: .builtInTripleCamera, autoSupportsCustomLens: false, lenses: both),
            .swap(nil)
        )
        XCTAssertEqual(
            CameraSession.switchPlan(
                to: .fixed,
                autoDeviceType: .builtInWideAngleCamera,
                autoSupportsCustomLens: true,
                lenses: [.builtInWideAngleCamera]
            ),
            .stay
        )
        XCTAssertEqual(
            CameraSession.switchPlan(
                to: .auto,
                autoDeviceType: .builtInWideAngleCamera,
                autoSupportsCustomLens: true,
                lenses: [.builtInWideAngleCamera]
            ),
            .stay
        )
        XCTAssertEqual(
            CameraSession.switchPlan(
                to: .fixed,
                autoDeviceType: .builtInWideAngleCamera,
                autoSupportsCustomLens: false,
                lenses: [.builtInWideAngleCamera]
            ),
            .impossible
        )
        XCTAssertEqual(
            CameraSession.switchPlan(
                to: .macro,
                autoDeviceType: .builtInDualCamera,
                autoSupportsCustomLens: false,
                lenses: [.builtInWideAngleCamera]
            ),
            .impossible
        )
    }

    /// Langer Druck aus Auto: der Bildausschnitt bleibt beim Tausch gleich.
    func testCarriedZoom() {
        // 3× auf der Dreifachkamera (Gerätefaktor 6, Haupt 2) → Weitwinkel 3.
        XCTAssertEqual(CameraSession.carriedZoom(autoZoom: 6, autoMain: 2, targetMain: 1, min: 1, max: 15), 3)
        // 0,5× (Gerätefaktor 1) → Ultraweit mit Haupt bei 2: 1.
        XCTAssertEqual(CameraSession.carriedZoom(autoZoom: 1, autoMain: 2, targetMain: 2, min: 1, max: 15), 1)
        XCTAssertEqual(CameraSession.carriedZoom(autoZoom: 2, autoMain: 2, targetMain: 1, min: 1, max: 15), 1)
        XCTAssertEqual(CameraSession.carriedZoom(autoZoom: 1, autoMain: 2, targetMain: 1, min: 1, max: 15), 1, "geklemmt")
    }
}
