import AVFoundation

/// The light of the camera: automatic flash, no light, or the LED as a
/// steady light. One button cycles through the modes the device has.
enum CameraLight: CaseIterable, Equatable {
    case auto
    case off
    case torch

    /// The mode after this one, skipping what the device lacks. `.off`
    /// is always there.
    func next(hasFlash: Bool, hasTorch: Bool) -> Self {
        let available = Self.allCases.filter { mode in
            switch mode {
            case .auto: hasFlash
            case .off: true
            case .torch: hasTorch
            }
        }
        guard let index = available.firstIndex(of: self) else { return .off }
        return available[(index + 1) % available.count]
    }

    /// The flash mode of a shot. With the LED on there is no flash on top.
    var captureFlashMode: AVCaptureDevice.FlashMode {
        self == .auto ? .auto : .off
    }

    var label: String {
        switch self {
        case .auto: String(localized: "Licht: automatischer Blitz")
        case .off: String(localized: "Licht: aus")
        case .torch: String(localized: "Licht: LED-Dauerlicht")
        }
    }

    /// The LED shines only while the camera runs in sight: not in the
    /// background, not behind the photo picker, not after closing.
    static func torchShouldBeOn(_ light: Self, sceneActive: Bool, pickerOpen: Bool, running: Bool) -> Bool {
        light == .torch && sceneActive && !pickerOpen && running
    }
}
