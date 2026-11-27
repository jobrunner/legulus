import AVFoundation
import SwiftUI
import UIKit

/// The live picture of a capture session, filling its frame edge to
/// edge (the sides of the 4:3 photo reach beyond the screen). Reports
/// taps and long presses as device points (for focus) and pinches as
/// magnification.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: (CGPoint) -> Void
    /// Device point for the camera and view point for the mark on screen.
    var onLongPress: (_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void
    var onPinchChanged: (CGFloat) -> Void
    var onPinchEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed))
        longPress.minimumPressDuration = Self.longPressDuration
        // A long press is no tap as well.
        tap.require(toFail: longPress)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched)))
        // VoiceOver sees the SwiftUI element around it (`CameraView`),
        // which carries label and actions.
        view.isAccessibilityElement = false
        return view
    }

    /// Hold time that locks the focus, as long as the system camera's.
    private static let longPressDuration: TimeInterval = 0.5

    func updateUIView(_: PreviewView, context: Context) {
        context.coordinator.parent = self
    }

    final class PreviewView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }

    final class Coordinator: NSObject {
        var parent: CameraPreview

        init(_ parent: CameraPreview) {
            self.parent = parent
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewView else { return }
            let point = view.previewLayer.captureDevicePointConverted(fromLayerPoint: recognizer.location(in: view))
            parent.onTap(point)
        }

        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view as? PreviewView else { return }
            let location = recognizer.location(in: view)
            parent.onLongPress(view.previewLayer.captureDevicePointConverted(fromLayerPoint: location), location)
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .changed:
                parent.onPinchChanged(recognizer.scale)
            case .ended, .cancelled, .failed:
                parent.onPinchEnded()
            default:
                break
            }
        }
    }
}
