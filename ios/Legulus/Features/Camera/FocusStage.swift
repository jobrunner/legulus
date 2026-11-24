import AVFoundation

/// The stages of the flower button. Auto lets the camera focus by
/// itself; „Fokus fest“ holds the focus on the main lens at a chosen
/// distance (a blade of grass before a busy background); „Makro“ holds
/// it on the ultra-wide lens down to about 2 cm (flower details, feeding
/// marks, beetles of a few millimetres).
///
/// A freely chosen lens position needs a physical lens, so the fixed
/// stages run on one and Auto on the virtual multi-camera.
enum FocusStage: Equatable {
    case auto
    case fixed
    case macro

    enum TapAction: Equatable {
        case focusAndExpose
        /// The focus stays where it was set; only the exposure follows.
        case exposeOnly
    }

    /// Closest focus distance, in millimetres, that still counts as
    /// macro. Ultra-wide lenses with a fixed focus report more or -1.
    static let macroMaxFocusDistanceMM = 50

    /// The stage after this one; without a close-focusing ultra-wide
    /// lens there is no macro stage.
    func next(macroAvailable: Bool) -> Self {
        switch self {
        case .auto: .fixed
        case .fixed: macroAvailable ? .macro : .auto
        case .macro: .auto
        }
    }

    /// The lens a fixed stage runs on; nil for the virtual camera.
    var physicalLens: AVCaptureDevice.DeviceType? {
        switch self {
        case .auto: nil
        case .fixed: .builtInWideAngleCamera
        case .macro: .builtInUltraWideCamera
        }
    }

    var label: String {
        switch self {
        case .auto: String(localized: "Fokus: automatisch")
        case .fixed: String(localized: "Fokus fest")
        case .macro: String(localized: "Makro")
        }
    }

    var tapAction: TapAction {
        self == .auto ? .focusAndExpose : .exposeOnly
    }

    static func supportsMacro(minimumFocusDistanceMM: Int, customLensPosition: Bool) -> Bool {
        customLensPosition && minimumFocusDistanceMM >= 0 && minimumFocusDistanceMM <= macroMaxFocusDistanceMM
    }

    /// The focus slider for VoiceOver, in words: the lens position is no
    /// distance in metres.
    static func focusValueText(lensPosition: Float) -> String {
        switch lensPosition {
        case ..<0.2: String(localized: "ganz nah")
        case ..<0.45: String(localized: "nah")
        case ..<0.7: String(localized: "mittel")
        default: String(localized: "fern")
        }
    }
}
