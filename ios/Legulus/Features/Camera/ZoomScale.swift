import AVFoundation
import Foundation

/// The zoom of the camera as the user sees it: lens buttons and the
/// zoom dial show factors relative to the main lens, like the system
/// camera („0,5“, „1×“, „3×“). The device works in its own factors, where
/// 1 is the widest lens of a virtual camera.
struct ZoomScale: Equatable {
    /// Device factor of the main lens.
    let mainFactor: CGFloat
    let minFactor: CGFloat
    let maxFactor: CGFloat
    /// One button per lens, as device factors.
    let lensStops: [CGFloat]

    init(deviceType: AVCaptureDevice.DeviceType, switchOverFactors: [CGFloat], minFactor: CGFloat, maxFactor: CGFloat) {
        mainFactor = CameraSession.initialZoom(deviceType: deviceType, switchOverFactors: switchOverFactors)
        self.minFactor = minFactor
        let upper = max(minFactor, min(maxFactor, CameraSession.maxZoom))
        self.maxFactor = upper
        lensStops = [minFactor] + switchOverFactors.filter { $0 > minFactor && $0 <= upper }
    }

    /// A single physical lens of the fixed stages: no lens buttons, and
    /// `mainFactor` is where its picture matches the main lens (the
    /// cropped ultra-wide in Macro).
    init(mainFactor: CGFloat, minFactor: CGFloat, maxFactor: CGFloat) {
        self.mainFactor = mainFactor
        self.minFactor = minFactor
        self.maxFactor = max(minFactor, min(maxFactor, CameraSession.maxZoom))
        lensStops = []
    }

    func displayFactor(_ deviceFactor: CGFloat) -> CGFloat {
        deviceFactor / mainFactor
    }

    func deviceFactor(display: CGFloat) -> CGFloat {
        display * mainFactor
    }

    /// „0,5“ below the main lens, „1×“, „1,4×“ from there on; one decimal
    /// at most, none for whole numbers.
    static func text(_ display: CGFloat, locale: Locale = .current) -> String {
        let number = Double(display).formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale))
        return display < 1 ? number : "\(number)×"
    }

    /// The factor for VoiceOver: „1,4-fach“.
    static func spokenText(_ display: CGFloat, locale: Locale = .current) -> String {
        let number = Double(display).formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale))
        return String(localized: "\(number)-fach")
    }

    /// Position on the dial, 0…1, logarithmic: every doubling is the same
    /// distance, as on the system camera's dial.
    func dialPosition(_ deviceFactor: CGFloat) -> CGFloat {
        guard maxFactor > minFactor else { return 0 }
        let clamped = min(max(deviceFactor, minFactor), maxFactor)
        return log(clamped / minFactor) / log(maxFactor / minFactor)
    }

    func deviceFactor(dialPosition: CGFloat) -> CGFloat {
        let position = min(max(dialPosition, 0), 1)
        return minFactor * pow(maxFactor / minFactor, position)
    }

    /// One VoiceOver step: to the next lens when it is at most double
    /// (half) away, else by `CameraSession.zoomStep`.
    func step(_ deviceFactor: CGFloat, up: Bool) -> CGFloat {
        let next: CGFloat
        if up {
            let stop = lensStops.first { $0 > deviceFactor + Self.tolerance }
            next = stop.map { $0 <= deviceFactor * 2 ? $0 : deviceFactor * CameraSession.zoomStep }
                ?? deviceFactor * CameraSession.zoomStep
        } else {
            let stop = lensStops.last { $0 < deviceFactor - Self.tolerance }
            next = stop.map { $0 >= deviceFactor / 2 ? $0 : deviceFactor / CameraSession.zoomStep }
                ?? deviceFactor / CameraSession.zoomStep
        }
        return min(max(next, minFactor), maxFactor)
    }

    /// Factors closer than this count as the same lens.
    private static let tolerance: CGFloat = 0.01
}
