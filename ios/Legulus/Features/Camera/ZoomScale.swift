import AVFoundation
import Foundation

/// The zoom of the camera as the user sees it: lens buttons and the
/// zoom dial show factors relative to the main lens, like the system
/// camera („0,5“, „1×“, „3×“). The device works in its own factors, where
/// 1 is the widest lens of a virtual camera.
///
/// Only optical zoom: the scale ends at the longest lens, there is no
/// digital zoom beyond it. Between the lenses the dial snaps in at
/// `snapDisplayFactors`.
struct ZoomScale: Equatable {
    /// Factors (relative to the main lens) the zoom snaps in at.
    static let snapDisplayFactors: [CGFloat] = [0.5, 1, 2, 3]
    /// How close (in dial position, 0…1) a factor must come to snap in.
    static let snapDistance: CGFloat = 0.035

    /// Device factor of the main lens.
    let mainFactor: CGFloat
    let minFactor: CGFloat
    let maxFactor: CGFloat
    /// One button per lens, as device factors.
    let lensStops: [CGFloat]

    init(deviceType: AVCaptureDevice.DeviceType, switchOverFactors: [CGFloat], minFactor: CGFloat, maxFactor: CGFloat) {
        mainFactor = CameraSession.initialZoom(deviceType: deviceType, switchOverFactors: switchOverFactors)
        self.minFactor = minFactor
        // The longest lens; without switch-over factors the main lens.
        let longest = max(switchOverFactors.max() ?? mainFactor, mainFactor)
        let upper = max(minFactor, min(maxFactor, longest))
        self.maxFactor = upper
        lensStops = [minFactor] + switchOverFactors.filter { $0 > minFactor && $0 <= upper }
    }

    /// A single physical lens of the fixed stages: no lens buttons, and
    /// `mainFactor` is where its picture matches the main lens (the
    /// cropped ultra-wide in Macro).
    init(mainFactor: CGFloat, minFactor: CGFloat, maxFactor: CGFloat) {
        self.mainFactor = mainFactor
        self.minFactor = minFactor
        // Up to the main-lens framing; beyond it would be digital.
        self.maxFactor = max(minFactor, min(maxFactor, mainFactor))
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
        let value = number(display, locale: locale)
        return display < 1 ? value : "\(value)×"
    }

    /// The bare number, one decimal at most: the lens labels on the dial.
    static func number(_ display: CGFloat, locale: Locale = .current) -> String {
        Double(display).formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale))
    }

    /// The factor for VoiceOver: „1,4-fach“.
    static func spokenText(_ display: CGFloat, locale: Locale = .current) -> String {
        String(localized: "\(number(display, locale: locale))-fach")
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

    /// The snap factors that lie on this scale, as device factors.
    var snapStops: [CGFloat] {
        Self.snapDisplayFactors.map(deviceFactor(display:))
            .filter { $0 >= minFactor - Self.tolerance && $0 <= maxFactor + Self.tolerance }
    }

    /// The factor with snapping: a snap stop when close enough, else as is.
    func snapped(_ deviceFactor: CGFloat) -> CGFloat {
        let position = dialPosition(deviceFactor)
        let nearest = snapStops.min { abs(dialPosition($0) - position) < abs(dialPosition($1) - position) }
        guard let nearest, abs(dialPosition(nearest) - position) <= Self.snapDistance else { return deviceFactor }
        return nearest
    }

    /// One VoiceOver step: to the next snap stop up or down.
    func step(_ deviceFactor: CGFloat, up: Bool) -> CGFloat {
        let next = up
            ? snapStops.first { $0 > deviceFactor + Self.tolerance }
            : snapStops.last { $0 < deviceFactor - Self.tolerance }
        return min(max(next ?? deviceFactor, minFactor), maxFactor)
    }

    /// Factors closer than this count as the same lens.
    private static let tolerance: CGFloat = 0.01
}
