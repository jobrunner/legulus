import AVFoundation
import CoreLocation
import ImageIO

/// The capture session behind `CameraView`: rear camera, still photos as
/// JPEG files, one after the other without closing.
///
/// The photo is handed out as the bytes of
/// `AVCapturePhoto.fileDataRepresentation()` — the file as the camera
/// wrote it, with all EXIF data. Nothing here decodes, resizes or
/// re-encodes it. The camera does not know where it is; the position of
/// the shot comes from `locationProvider` and travels in the capture
/// settings (see `PhotoGPSMetadata`).
///
/// The AVFoundation objects live in `CameraCore` and are used on its
/// queue only; the published state changes on the main actor.
@MainActor
final class CameraSession: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        /// The user denied or cannot grant camera access.
        case unauthorized
        /// No camera (Simulator).
        case unavailable
        case running
        /// The session swaps the lens; the picture is black for a moment.
        case switching
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isCapturing = false
    @Published private(set) var light: CameraLight = .auto
    /// What the device offers; known once the session runs.
    @Published private(set) var hasFlash = false
    @Published private(set) var hasTorch = false
    @Published private(set) var focusStage: FocusStage = .auto
    /// The device has an ultra-wide lens that focuses close.
    @Published private(set) var macroAvailable = false
    /// Lens position of the fixed stages, 0 (near) … 1 (far).
    @Published private(set) var lensPosition: Float = 0
    /// Current zoom in device factors, and the scale to show it with.
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var zoomScale = ZoomScale(mainFactor: 1, minFactor: 1, maxFactor: 1)

    /// Called on the main actor with the file data of each photo.
    var onPhoto: ((Data) -> Void)?
    /// Called on the main actor when a capture failed.
    var onCaptureError: ((String) -> Void)?
    /// The position for the GPS block of the next shot; nil leaves the
    /// block out. Never waited for.
    var locationProvider: (() -> CLLocation?)?

    /// The capture session, for the preview layer.
    var session: AVCaptureSession {
        core.session
    }

    private let core = CameraCore()

    /// Upper bound of the pinch zoom; beyond it the picture is digital
    /// mush on every device.
    nonisolated static let maxZoom: CGFloat = 10

    /// Device types in order of preference. The virtual multi-camera
    /// devices come first: only they switch lenses by themselves when
    /// zooming or focusing close (macro).
    nonisolated static let preferredDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
    ]

    nonisolated static func clampedZoom(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        guard value.isFinite else { return minimum }
        return Swift.min(Swift.max(value, minimum), Swift.min(maximum, maxZoom))
    }

    /// Settings for one shot: JPEG, the flash mode only when the device
    /// supports it, and the GPS block when a position is known.
    nonisolated static func photoSettings(
        flash: AVCaptureDevice.FlashMode,
        supportedFlash: [AVCaptureDevice.FlashMode],
        location: CLLocation?
    ) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = supportedFlash.contains(flash) ? flash : .off
        if let location {
            settings.metadata = [kCGImagePropertyGPSDictionary as String: PhotoGPSMetadata.dictionary(for: location)]
        }
        return settings
    }

    nonisolated static func canCapture(state: State, isCapturing: Bool) -> Bool {
        state == .running && !isCapturing
    }

    /// Factor of one VoiceOver step between two lenses.
    nonisolated static let zoomStep: CGFloat = 1.5

    /// The zoom factor the camera opens with. On the virtual devices
    /// that start with the ultra-wide lens, factor 1 is that lens; the
    /// first switch-over factor is the main lens.
    nonisolated static func initialZoom(deviceType: AVCaptureDevice.DeviceType, switchOverFactors: [CGFloat]) -> CGFloat {
        guard [.builtInTripleCamera, .builtInDualWideCamera].contains(deviceType),
              let main = switchOverFactors.first
        else { return 1 }
        return main
    }

    // MARK: - lifecycle

    /// Asks for camera access if needed, configures the session once and
    /// starts it.
    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .unauthorized
                return
            }
        default:
            state = .unauthorized
            return
        }
        let core = core
        let (newState, flash, torch, macro) = await withCheckedContinuation { continuation in
            core.queue.async {
                let state = core.configureAndRun()
                continuation.resume(returning: (state, core.hasFlash, core.hasTorch, core.macroAvailable))
            }
        }
        hasFlash = flash
        hasTorch = torch
        macroAvailable = macro
        if !flash, light == .auto { light = .off }
        state = newState
        await refreshZoom()
    }

    func stop() {
        let core = core
        core.queue.async {
            core.setTorch(false)
            core.stop()
        }
        if state == .running { state = .idle }
    }

    /// Holds the picture while something covers the camera (photo
    /// picker); `state` stays as it is.
    func pause() {
        let core = core
        core.queue.async {
            core.setTorch(false)
            core.stop()
        }
    }

    func resume() {
        guard state == .running else { return }
        let core = core
        core.queue.async { core.resume() }
    }

    // MARK: - light

    func cycleLight() {
        light = light.next(hasFlash: hasFlash, hasTorch: hasTorch)
    }

    /// Switches the LED on or off for the current light and situation.
    func updateTorch(sceneActive: Bool, pickerOpen: Bool) {
        let on = CameraLight.torchShouldBeOn(light, sceneActive: sceneActive, pickerOpen: pickerOpen, running: state == .running)
        let core = core
        core.queue.async { core.setTorch(on) }
    }

    // MARK: - capture

    /// Takes one photo. Ignored while the previous one is still being
    /// captured, and never waits for a position.
    func capture() {
        guard Self.canCapture(state: state, isCapturing: isCapturing) else { return }
        isCapturing = true
        let core = core
        let flash = light.captureFlashMode
        let location = locationProvider?()
        core.queue.async { [weak self] in
            guard let self else { return }
            core.capture(flash: flash, location: location, delegate: self)
        }
    }

    // MARK: - focus and zoom

    /// A tap on the preview, in device coordinates (0…1, as
    /// `AVCaptureVideoPreviewLayer.captureDevicePointConverted` returns
    /// them). In Auto it sets focus and exposure there; in the fixed
    /// stages only the exposure, so the focus set by hand stays.
    func tap(at devicePoint: CGPoint) {
        let core = core
        switch focusStage.tapAction {
        case .focusAndExpose: core.queue.async { core.focus(at: devicePoint) }
        case .exposeOnly: core.queue.async { core.expose(at: devicePoint) }
        }
    }

    /// The next stage of the flower button. The picture is black while
    /// the session swaps the lens.
    func cycleFocusStage() async {
        await switchStage(to: focusStage.next(macroAvailable: macroAvailable))
    }

    /// Long press: focus once at the point and hold it there. From Auto
    /// the camera first moves to the physical lens that is active, so
    /// the slider can fine-tune afterwards.
    func lockFocus(at devicePoint: CGPoint) async {
        guard state == .running else { return }
        if focusStage == .auto {
            let core = core
            let activeIsUltraWide = await withCheckedContinuation { continuation in
                core.queue.async { continuation.resume(returning: core.activeLensIsUltraWide) }
            }
            await switchStage(to: activeIsUltraWide && macroAvailable ? .macro : .fixed)
            guard focusStage != .auto else { return }
        }
        let core = core
        let position = await withCheckedContinuation { continuation in
            core.queue.async {
                core.focusOnce(at: devicePoint) { continuation.resume(returning: $0) }
            }
        }
        if let position { lensPosition = position }
    }

    /// Moves the focus of a fixed stage; ignored in Auto.
    func setLensPosition(_ value: Float) {
        guard focusStage != .auto else { return }
        let clamped = min(max(value, 0), 1)
        lensPosition = clamped
        let core = core
        core.queue.async { core.setLensPosition(clamped) }
    }

    private func switchStage(to stage: FocusStage) async {
        guard state == .running, stage != focusStage else { return }
        state = .switching
        let core = core
        let switched = await withCheckedContinuation { continuation in
            core.queue.async { continuation.resume(returning: core.switchInput(to: stage)) }
        }
        if switched {
            focusStage = stage
            lensPosition = 0
            await refreshZoom()
        } else {
            Log.ui.error("camera: lens switch failed")
            onCaptureError?(String(localized: "Das Objektiv ließ sich nicht wechseln."))
        }
        state = .running
    }

    /// Pinch: `factor` is the gesture's magnification since it began.
    func zoom(by factor: CGFloat) {
        let core = core
        core.queue.async { core.zoom(by: factor) }
        Task { await refreshZoom() }
    }

    func zoomEnded() {
        let core = core
        core.queue.async { core.zoomEnded() }
        Task { await refreshZoom() }
    }

    /// Lens buttons, dial and VoiceOver: straight to a device factor.
    func setZoom(_ deviceFactor: CGFloat) {
        zoomFactor = min(max(deviceFactor, zoomScale.minFactor), zoomScale.maxFactor)
        let core = core
        core.queue.async { core.setZoom(deviceFactor) }
    }

    private func refreshZoom() async {
        let core = core
        let (factor, scale) = await withCheckedContinuation { continuation in
            core.queue.async { continuation.resume(returning: (core.zoomFactor, core.zoomScale)) }
        }
        zoomFactor = factor
        zoomScale = scale
    }
}

/// The AVFoundation objects of `CameraSession`. Everything except
/// `session` (handed to the preview layer) and `queue` is touched on
/// `queue` only, which is what makes the unchecked `Sendable` hold.
private final class CameraCore: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "app.legulus.camera.session")

    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    /// The camera the session opens with (virtual multi-camera if the
    /// device has one); Auto runs on it.
    private var autoDevice: AVCaptureDevice?
    /// Physical rear lenses for the fixed stages.
    private var lenses: [AVCaptureDevice.DeviceType: AVCaptureDevice] = [:]
    private var input: AVCaptureDeviceInput?
    /// Zoom of Auto before a fixed stage, restored on the way back.
    private var autoZoom: CGFloat = 1
    private var stage: FocusStage = .auto
    private var subjectAreaObserver: NSObjectProtocol?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// Zoom factor when the current pinch began.
    private var zoomAtGestureStart: CGFloat = 1

    func configureAndRun() -> CameraSession.State {
        if device == nil {
            guard let camera = AVCaptureDevice.DiscoverySession(
                deviceTypes: CameraSession.preferredDeviceTypes, mediaType: .video, position: .back
            ).devices.first else { return .unavailable }
            guard let input = try? AVCaptureDeviceInput(device: camera) else {
                return .failed("Die Kamera lässt sich nicht öffnen.")
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return .failed("Die Kamera lässt sich nicht einrichten.")
            }
            session.addInput(input)
            session.addOutput(output)
            self.input = input
            autoDevice = camera
            let physical = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera], mediaType: .video, position: .back
            ).devices
            lenses = Dictionary(physical.map { ($0.deviceType, $0) }) { first, _ in first }
            // Open question of the design: does the virtual camera allow a
            // custom lens position? If yes, the lens swap is not needed.
            let custom = camera.isLockingFocusWithCustomLensPositionSupported
            Log.ui.info("camera: \(camera.deviceType.rawValue, privacy: .public) custom lens position \(custom, privacy: .public)")
            // Standard photo resolution of the device; the 48-MP mode
            // (maxPhotoDimensions) stays off on purpose.
            output.maxPhotoQualityPrioritization = .balanced
            session.commitConfiguration()
            device = camera
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            let initial = CameraSession.initialZoom(
                deviceType: camera.deviceType,
                switchOverFactors: camera.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            )
            if initial != camera.videoZoomFactor, (try? camera.lockForConfiguration()) != nil {
                camera.videoZoomFactor = CameraSession.clampedZoom(
                    initial, min: camera.minAvailableVideoZoomFactor, max: camera.maxAvailableVideoZoomFactor
                )
                camera.unlockForConfiguration()
            }
            zoomAtGestureStart = camera.videoZoomFactor
            applyAutoFocus(camera)
            observeSubjectArea(of: camera)
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning ? .running : .failed("Die Kamera startet nicht.")
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func resume() {
        if !session.isRunning { session.startRunning() }
    }

    var macroAvailable: Bool {
        guard let ultraWide = lenses[.builtInUltraWideCamera] else { return false }
        return FocusStage.supportsMacro(
            minimumFocusDistanceMM: ultraWide.minimumFocusDistance,
            customLensPosition: ultraWide.isLockingFocusWithCustomLensPositionSupported
        )
    }

    var activeLensIsUltraWide: Bool {
        device?.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera
    }

    /// Swaps the session's input for the lens of `stage` and sets zoom
    /// and focus for it. Torch state goes with the old device; the view
    /// switches it on again from its state change.
    func switchInput(to stage: FocusStage) -> Bool {
        guard let autoDevice, let current = input else { return false }
        let target = stage.physicalLens.flatMap { lenses[$0] } ?? autoDevice
        if stage != .auto, target == autoDevice { return false }
        guard let newInput = try? AVCaptureDeviceInput(device: target) else { return false }
        if device == autoDevice { autoZoom = autoDevice.videoZoomFactor }
        setTorch(false)
        session.beginConfiguration()
        session.removeInput(current)
        guard session.canAddInput(newInput) else {
            session.addInput(current)
            session.commitConfiguration()
            return false
        }
        session.addInput(newInput)
        session.commitConfiguration()
        input = newInput
        device = target
        self.stage = stage
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: target, previewLayer: nil)
        observeSubjectArea(of: target)
        guard (try? target.lockForConfiguration()) != nil else { return true }
        let zoom: CGFloat = switch stage {
        case .auto: autoZoom
        case .macro: macroMainFactor
        case .fixed: 1
        }
        target.videoZoomFactor = CameraSession.clampedZoom(
            zoom, min: target.minAvailableVideoZoomFactor, max: target.maxAvailableVideoZoomFactor
        )
        zoomAtGestureStart = target.videoZoomFactor
        target.unlockForConfiguration()
        if stage == .auto {
            applyAutoFocus(target)
        } else {
            setLensPosition(0)
            expose(at: CGPoint(x: 0.5, y: 0.5))
        }
        return true
    }

    /// The ultra-wide picture cropped to about the main lens: the first
    /// switch-over factor of the virtual camera is that ratio.
    private var macroMainFactor: CGFloat {
        autoDevice?.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 2
    }

    var zoomFactor: CGFloat {
        device?.videoZoomFactor ?? 1
    }

    var zoomScale: ZoomScale {
        guard let device else { return ZoomScale(mainFactor: 1, minFactor: 1, maxFactor: 1) }
        let low = device.minAvailableVideoZoomFactor
        let high = device.maxAvailableVideoZoomFactor
        switch stage {
        case .auto:
            return ZoomScale(
                deviceType: device.deviceType,
                switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) },
                minFactor: low,
                maxFactor: high
            )
        case .fixed: return ZoomScale(mainFactor: 1, minFactor: low, maxFactor: high)
        case .macro: return ZoomScale(mainFactor: macroMainFactor, minFactor: low, maxFactor: high)
        }
    }

    func setZoom(_ deviceFactor: CGFloat) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = CameraSession.clampedZoom(
            deviceFactor, min: device.minAvailableVideoZoomFactor, max: device.maxAvailableVideoZoomFactor
        )
        zoomAtGestureStart = device.videoZoomFactor
        device.unlockForConfiguration()
    }

    /// Focus and exposure follow the picture by themselves.
    private func applyAutoFocus(_ camera: AVCaptureDevice) {
        guard (try? camera.lockForConfiguration()) != nil else { return }
        defer { camera.unlockForConfiguration() }
        if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        camera.isSubjectAreaChangeMonitoringEnabled = true
    }

    /// After a clear change of the scene, Auto goes back to the centre.
    private func observeSubjectArea(of camera: AVCaptureDevice) {
        if let subjectAreaObserver { NotificationCenter.default.removeObserver(subjectAreaObserver) }
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: camera, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async {
                guard self.device == self.autoDevice, let device = self.device else { return }
                self.applyAutoFocus(device)
            }
        }
    }

    func setLensPosition(_ value: Float) {
        guard let device, device.isLockingFocusWithCustomLensPositionSupported,
              (try? device.lockForConfiguration()) != nil
        else { return }
        device.setFocusModeLocked(lensPosition: value)
        device.unlockForConfiguration()
    }

    func expose(at devicePoint: CGPoint) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .continuousAutoExposure
        }
    }

    /// Focuses once at the point, waits until the lens has settled (at
    /// most `focusTimeout`) and locks it there. Hands out the lens
    /// position, nil when the device cannot focus at a point.
    func focusOnce(at devicePoint: CGPoint, completion: @escaping (Float?) -> Void) {
        guard let device, device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus),
              (try? device.lockForConfiguration()) != nil
        else {
            completion(nil)
            return
        }
        device.focusPointOfInterest = devicePoint
        device.focusMode = .autoFocus
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
        let deadline = DispatchTime.now() + Self.focusTimeout
        waitForFocus(device, until: deadline, completion: completion)
    }

    /// Longest wait for the lens after a long press.
    private static let focusTimeout: DispatchTimeInterval = .seconds(2)
    private static let focusPollInterval: DispatchTimeInterval = .milliseconds(50)

    private func waitForFocus(_ device: AVCaptureDevice, until deadline: DispatchTime, completion: @escaping (Float?) -> Void) {
        if device.isAdjustingFocus, DispatchTime.now() < deadline {
            queue.asyncAfter(deadline: .now() + Self.focusPollInterval) { [weak self] in
                self?.waitForFocus(device, until: deadline, completion: completion)
            }
            return
        }
        let position = device.lensPosition
        setLensPosition(position)
        completion(position)
    }

    var hasFlash: Bool {
        output.supportedFlashModes.contains(.auto)
    }

    var hasTorch: Bool {
        device.map { $0.hasTorch && $0.isTorchModeSupported(.on) } ?? false
    }

    func setTorch(_ on: Bool) {
        guard hasTorch, let device, device.torchMode != (on ? .on : .off),
              (try? device.lockForConfiguration()) != nil
        else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func capture(flash: AVCaptureDevice.FlashMode, location: CLLocation?, delegate: AVCapturePhotoCaptureDelegate) {
        let settings = CameraSession.photoSettings(
            flash: flash, supportedFlash: output.supportedFlashModes, location: location
        )
        settings.photoQualityPrioritization = .balanced
        // Portrait and landscape end up in the file as held.
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle)
        {
            connection.videoRotationAngle = angle
        }
        output.capturePhoto(with: settings, delegate: delegate)
    }

    func focus(at devicePoint: CGPoint) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        // Keeps following the subject at the point; a clear change of the
        // scene brings it back to the centre (`observeSubjectArea`).
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .continuousAutoExposure
        }
    }

    func zoom(by factor: CGFloat) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = CameraSession.clampedZoom(
            zoomAtGestureStart * factor,
            min: device.minAvailableVideoZoomFactor,
            max: device.maxAvailableVideoZoomFactor
        )
        device.unlockForConfiguration()
    }

    func zoomEnded() {
        zoomAtGestureStart = device?.videoZoomFactor ?? 1
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let message = error?.localizedDescription
        Task { @MainActor in
            self.isCapturing = false
            if let data {
                self.onPhoto?(data)
            } else {
                Log.ui.error("camera capture failed: \(message ?? "no data", privacy: .public)")
                self.onCaptureError?("Das Foto konnte nicht aufgenommen werden.")
            }
        }
    }
}
