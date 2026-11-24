import AVFoundation
import CoreLocation
import PhotosUI
import SwiftUI
import UIKit

/// Full-screen camera for a series of voucher photos. The picture fills
/// the screen, the controls lie on top of it. It stays open after every
/// shot: shutter, the last picture with the count of this session, a
/// close button out of the way at the top left. There is no „use photo“
/// step.
///
/// `onPhoto` receives the camera's JPEG file for each shot and stores
/// it; when it throws (disk full, …) the camera shows the error and
/// does not count the shot, so no photo is lost silently.
struct CameraView: View {
    let onPhoto: (Data) throws -> Void
    let onDone: () -> Void

    @StateObject private var camera = CameraSession()
    /// Locates while the camera is open, for the GPS block of the
    /// photos. The shutter never waits for it.
    @StateObject private var location = LocationProvider()

    @State private var count = 0
    @State private var lastPhoto: UIImage?
    @State private var errorMessage: String?
    /// The last fix of this session; survives the provider going back
    /// to „locating“ for the next one.
    @State private var lastFix = FixBox()
    /// The photo picker covers the camera; the LED goes off meanwhile.
    @State private var pickerOpen = false
    @State private var pickedItems: [PhotosPickerItem] = []
    /// Where the last long press locked the focus, while its mark shows.
    @State private var focusMark: CGPoint?
    /// The focus at the mark is held; until then the mark has no text.
    @State private var focusLocked = false
    /// The zoom dial shows while zooming and a moment after.
    @State private var dialVisible = false
    @State private var dialToken = UUID()
    /// Dial position when the current drag over the zoom control began.
    @State private var zoomDragStart: CGFloat?
    @State private var zoomControlWidth: CGFloat = 1

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How often the position is refreshed while the camera is open;
    /// below `LocationThreshold.staleness`.
    private let fixRefreshInterval: Duration = .seconds(10)

    @ScaledMetric(relativeTo: .body) private var shutterSize: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var lastPhotoSize: CGFloat = 44
    /// The ringed „Fertig“ button, as large as the thumbnail and at least
    /// a tap target.
    @ScaledMetric(relativeTo: .body) private var finishSize: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var focusMarkSize: CGFloat = 72
    /// How long the zoom dial stays after the last touch.
    private let dialDuration: Duration = .milliseconds(1500)
    /// Part of the whole dial one width of the zoom control covers: the
    /// whole optical range lies within half the width, one thumb stroke.
    private let zoomDragSpan: CGFloat = 2
    /// Factors closer than this count as the same lens.
    private let lensTolerance: CGFloat = 0.01
    /// How long the mark of a long press stays on screen.
    private let focusMarkDuration: Duration = .milliseconds(1500)
    /// Width of the shutter's ring.
    private let ringWidth: CGFloat = 4
    /// Mindestgröße eines Tap-Targets (Apple HIG).
    private let minTapTarget: CGFloat = 44
    /// Fine ring around the „Fertig“ button.
    private let hairline: CGFloat = 1
    /// Line of the empty frame before the first photo.
    private let placeholderLineWidth: CGFloat = 1.5
    /// Pixel size of the preview of the last photo.
    private let lastPhotoPixels: CGFloat = 240

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .task {
            camera.onPhoto = store
            camera.onCaptureError = { errorMessage = $0 }
            camera.locationProvider = { [lastFix] in
                // Only a fix that is still fresh: a series can last
                // minutes and metres. Without one the photo carries no
                // GPS rather than the place the series began at.
                guard let fix = lastFix.location, LocationThreshold.accepts(fix) else { return nil }
                return fix
            }
            location.requestFix()
            await camera.start()
            // The provider stops after each fix; keep asking while the
            // camera is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: fixRefreshInterval)
                if Task.isCancelled { break }
                location.requestFix()
            }
        }
        .onChange(of: location.status) { _, status in
            if case let .fixed(fix) = status { lastFix.location = fix }
        }
        .onChange(of: camera.light) { _, _ in updateTorch() }
        .onChange(of: camera.state) { _, _ in updateTorch() }
        .onChange(of: scenePhase) { _, _ in updateTorch() }
        .onChange(of: pickerOpen) { _, open in
            if open { camera.pause() } else { camera.resume() }
            updateTorch()
        }
        .photosPicker(isPresented: $pickerOpen, selection: $pickedItems, matching: .images)
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            pickedItems = []
            importFromGallery(items)
        }
        .onDisappear { camera.stop() }
        .accessibilityAddTraits(.isModal)
        // Haptics for every control: modes and snap stops tick, the shutter
        // and the gallery knock, a held focus and errors report.
        .sensoryFeedback(.selection, trigger: camera.light)
        .sensoryFeedback(.selection, trigger: camera.focusStage)
        .sensoryFeedback(.selection, trigger: currentSnap) { _, snap in snap != nil }
        .sensoryFeedback(.selection, trigger: focusValueBucket)
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.isCapturing) { _, capturing in capturing }
        .sensoryFeedback(.impact(weight: .light), trigger: pickerOpen) { _, open in open }
        .sensoryFeedback(.success, trigger: focusLocked) { _, locked in locked }
        .sensoryFeedback(.error, trigger: errorMessage) { _, message in message != nil }
    }

    @ViewBuilder
    private var content: some View {
        switch camera.state {
        case .idle, .running, .switching:
            ZStack {
                preview
                    .overlay(alignment: .topLeading) { focusMarkView }
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                        .background(alignment: .top) { scrim(from: .top) }
                    Spacer(minLength: 0)
                    errorBanner
                    if camera.focusStage != .auto {
                        focusSlider
                    }
                    VStack(spacing: 0) {
                        zoomControl
                        bottomBar
                    }
                    .background(alignment: .bottom) {
                        if dialVisible {
                            dialBackdrop
                        } else {
                            scrim(from: .bottom)
                        }
                    }
                }
            }
        case .unauthorized:
            notice(
                "Legulus darf die Kamera nicht benutzen.",
                detail: "Erlaube den Zugriff in den Einstellungen, um Belegfotos aufzunehmen.",
                settingsButton: true
            )
        case .unavailable:
            notice("Auf diesem Gerät gibt es keine Kamera.", detail: nil, settingsButton: false)
        case let .failed(message):
            notice(message, detail: nil, settingsButton: false)
        }
    }

    private var preview: some View {
        CameraPreview(
            session: camera.session,
            onTap: { camera.tap(at: $0) },
            onLongPress: { devicePoint, viewPoint in lockFocus(at: devicePoint, mark: viewPoint) },
            onPinchChanged: { magnification in
                camera.zoom(by: magnification)
                keepDial()
            },
            onPinchEnded: {
                camera.zoomEnded()
                keepDial()
            }
        )
        // The picture says nothing to VoiceOver; zoom and focus have
        // their own controls (zoom control, flower button and slider).
        .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack(spacing: AppSpacing.md) {
            Spacer(minLength: AppSpacing.sm)
            focusButton
            if hasLightChoice {
                lightButton
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    private var focusButton: some View {
        Button {
            Task {
                await camera.cycleFocusStage()
                AccessibilityNotification.Announcement(camera.focusStage.label).post()
            }
        } label: {
            focusSymbol
                .font(AppFont.sectionTitle)
                .foregroundStyle(camera.focusStage == .auto ? Color.white : AppColor.cameraActive)
                .modifier(upright)
                .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                .contentShape(Rectangle())
        }
        // Not mid-shot: the lens swap would cut the capture off.
        .disabled(camera.state != .running || camera.isCapturing)
        .accessibilityLabel("Fokus")
        .accessibilityValue(camera.focusStage.label)
        .accessibilityHint("Wechselt zur nächsten Stufe")
    }

    /// The flower in three shapes, so the stage reads without colour:
    /// plain, with a lock, filled in a circle. The button carries label
    /// and value.
    @ViewBuilder
    private var focusSymbol: some View {
        switch camera.focusStage {
        case .auto:
            Image(systemName: "camera.macro")
                .accessibilityHidden(true)
        case .fixed:
            Image(systemName: "camera.macro")
                .accessibilityHidden(true)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(AppFont.caption2)
                        .accessibilityHidden(true)
                }
        case .macro:
            Image(systemName: "camera.macro.circle.fill")
                .accessibilityHidden(true)
        }
    }

    /// Distance of the locked focus, near to far, in the fixed stages.
    private var focusSlider: some View {
        HStack(spacing: AppSpacing.sm) {
            Text("Nah")
                .modifier(upright)
                .accessibilityHidden(true)
            Slider(
                value: Binding(get: { camera.lensPosition }, set: { camera.setLensPosition($0) }),
                in: 0 ... 1
            )
            .tint(.white)
            .accessibilityLabel("Schärfe-Entfernung")
            .accessibilityValue(FocusStage.focusValueText(lensPosition: camera.lensPosition))
            Text("Fern")
                .modifier(upright)
                .accessibilityHidden(true)
        }
        .font(AppFont.footnote)
        .foregroundStyle(.white)
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.sm)
    }

    /// Lens buttons, or the dial while zooming. For VoiceOver one
    /// adjustable element „Zoom“: swipe up and down to step.
    private var zoomControl: some View {
        Group {
            if dialVisible {
                ZoomDial(
                    scale: camera.zoomScale,
                    factor: camera.zoomFactor,
                    drawsDisc: false,
                    uprightRotation: .degrees(camera.controlRotation)
                )
                .animation(AppMotion.respecting(AppMotion.fast, reduceMotion: reduceMotion), value: camera.zoomFactor)
                .transition(.opacity)
            } else {
                lensButtons
                    .padding(.horizontal, AppSpacing.lg)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { zoomControlWidth = max($0, 1) }
        // On the container, which stays while buttons and dial swap: a
        // drag that starts on the buttons goes on on the dial.
        .simultaneousGesture(zoomDrag)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoom")
        .accessibilityValue(ZoomScale.spokenText(camera.zoomScale.displayFactor(camera.zoomFactor)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: camera.setZoom(camera.zoomScale.step(camera.zoomFactor, up: true))
            case .decrement: camera.setZoom(camera.zoomScale.step(camera.zoomFactor, up: false))
            @unknown default: break
            }
        }
    }

    /// One button per lens; the active one shows the current factor. In
    /// the fixed stages there is one lens, so only the factor shows.
    private var lensButtons: some View {
        HStack(spacing: AppSpacing.sm) {
            let scale = camera.zoomScale
            let active = scale.lensStops.last { $0 <= camera.zoomFactor + lensTolerance }
            if scale.lensStops.isEmpty {
                lensLabel(ZoomScale.text(scale.displayFactor(camera.zoomFactor)), active: true)
            }
            ForEach(scale.lensStops, id: \.self) { stop in
                Button {
                    camera.setZoom(stop)
                } label: {
                    let isActive = stop == active
                    lensLabel(
                        ZoomScale.text(scale.displayFactor(isActive ? camera.zoomFactor : stop)),
                        active: isActive
                    )
                }
            }
        }
    }

    /// Sideways drag turns the dial; to the left towards higher factors.
    /// The minimum distance leaves taps to the lens buttons.
    private var zoomDrag: some Gesture {
        DragGesture(minimumDistance: AppSpacing.sm)
            .onChanged { value in
                let start = zoomDragStart ?? camera.zoomScale.dialPosition(camera.zoomFactor)
                if zoomDragStart == nil { zoomDragStart = start }
                let position = start - value.translation.width / zoomControlWidth * zoomDragSpan
                camera.setZoom(camera.zoomScale.deviceFactor(dialPosition: position))
                keepDial()
            }
            .onEnded { _ in
                zoomDragStart = nil
                keepDial()
            }
    }

    private func lensLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(AppFont.footnote.monospacedDigit().weight(active ? .semibold : .regular))
            .foregroundStyle(active ? AppColor.cameraActive : .white)
            .modifier(upright)
            .frame(minWidth: minTapTarget, minHeight: minTapTarget)
            .background(AppColor.cameraScrim, in: Circle())
            .contentShape(Circle())
    }

    /// While the dial is open, its disc runs down to the screen edge as
    /// one shape, so the controls below sit on the same shade as the dial.
    private var dialBackdrop: some View {
        DialArch()
            .fill(AppColor.cameraScrim)
            .ignoresSafeArea(edges: .bottom)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// Shows the dial and hides it again after a pause without zooming.
    private func keepDial() {
        let token = UUID()
        dialToken = token
        if !dialVisible {
            withAnimation(AppMotion.respecting(AppMotion.fast, reduceMotion: reduceMotion)) { dialVisible = true }
        }
        Task {
            try? await Task.sleep(for: dialDuration)
            guard dialToken == token else { return }
            withAnimation(AppMotion.respecting(AppMotion.base, reduceMotion: reduceMotion)) { dialVisible = false }
        }
    }

    @ViewBuilder
    private var focusMarkView: some View {
        if let focusMark {
            VStack(spacing: AppSpacing.xxs) {
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .strokeBorder(AppColor.cameraActive, lineWidth: placeholderLineWidth)
                    .frame(width: focusMarkSize, height: focusMarkSize)
                Text("Fokus fest")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.cameraActive)
                    .opacity(focusLocked ? 1 : 0)
            }
            .modifier(upright)
            .position(focusMark)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    private func lockFocus(at devicePoint: CGPoint, mark: CGPoint) {
        focusLocked = false
        withAnimation(AppMotion.respecting(AppMotion.fast, reduceMotion: reduceMotion)) { focusMark = mark }
        Task {
            if await camera.lockFocus(at: devicePoint) {
                focusLocked = true
                AccessibilityNotification.Announcement("Fokus fest").post()
                try? await Task.sleep(for: focusMarkDuration)
            }
            withAnimation(AppMotion.respecting(AppMotion.fast, reduceMotion: reduceMotion)) {
                if focusMark == mark { focusMark = nil }
            }
        }
    }

    private var lightButton: some View {
        Button {
            camera.cycleLight()
        } label: {
            Image(systemName: lightSymbol)
                .font(AppFont.sectionTitle)
                .foregroundStyle(camera.light == .off ? Color.white : AppColor.cameraActive)
                .modifier(upright)
                .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(camera.light.label)
        .accessibilityHint("Wechselt zum nächsten Modus")
    }

    /// Without flash and LED there is only „off“: nothing to choose.
    private var hasLightChoice: Bool {
        camera.hasFlash || camera.hasTorch
    }

    /// Shade from the edge towards the middle behind a bar of controls.
    private func scrim(from edge: VerticalEdge) -> some View {
        let shade = contrast == .increased ? AppColor.cameraScrimStrong : AppColor.cameraScrim
        return LinearGradient(
            colors: [shade, .clear],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
        .accessibilityHidden(true)
    }

    private var lightSymbol: String {
        switch camera.light {
        case .auto: "bolt.badge.automatic.fill"
        case .off: "bolt.slash.fill"
        case .torch: "flashlight.on.fill"
        }
    }

    private var doneButton: some View {
        Button("Fertig", action: onDone)
            .font(AppFont.bodyEmphasized)
            .frame(minWidth: minTapTarget, minHeight: minTapTarget)
            .contentShape(Rectangle())
    }

    /// Last photo and gallery on the left, the shutter in the middle of
    /// the screen, „Fertig“ on the right, where the thumb ends a series.
    private var bottomBar: some View {
        ZStack {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                lastPhotoView
                    .modifier(upright)
                galleryButton
                // Keeps the sides off the shutter.
                Spacer(minLength: shutterSize + AppSpacing.md * 2)
                finishButton
            }
            shutter
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.lg)
    }

    /// Ends the series: the photos are stored already, nothing is thrown
    /// away. A yellow checkmark in a translucent circle like the lens
    /// buttons, with a fine ring as anchor; it turns with the phone like
    /// the other controls.
    private var finishButton: some View {
        Button {
            // The view goes away at once; a trigger-based feedback would
            // not fire any more.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDone()
        } label: {
            finishCheckmark
                .modifier(upright)
                .foregroundStyle(AppColor.cameraActive)
                .frame(width: finishSize, height: finishSize)
                .background(AppColor.cameraScrim, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: hairline))
                .contentShape(Circle())
        }
    }

    private var finishCheckmark: some View {
        Image(systemName: "checkmark")
            .font(AppFont.headline.weight(.bold))
            .accessibilityLabel("Fertig")
    }

    /// Turns numbers and icons upright to the horizon in landscape; the
    /// layout itself stays in portrait, as in the system camera.
    private var upright: UprightToHorizon {
        UprightToHorizon(degrees: camera.controlRotation, reduceMotion: reduceMotion)
    }

    private var galleryButton: some View {
        Button {
            pickerOpen = true
        } label: {
            Image(systemName: "photo.on.rectangle")
                .font(AppFont.sectionTitle)
                .foregroundStyle(.white)
                .modifier(upright)
                .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                .contentShape(Rectangle())
        }
        .disabled(camera.isCapturing)
        .accessibilityLabel("Foto aus der Galerie")
    }

    private var shutter: some View {
        Button {
            camera.capture()
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: ringWidth)
                Circle().fill(.white).padding(ringWidth + AppSpacing.xxs)
            }
            .frame(width: shutterSize, height: shutterSize)
            .opacity(camera.isCapturing ? 0.4 : 1)
            .contentShape(Circle())
        }
        .disabled(!CameraSession.canCapture(state: camera.state, isCapturing: camera.isCapturing))
        .accessibilityLabel("Foto aufnehmen")
        .accessibilityValue(countText)
    }

    /// The last picture with the count of this session inside it.
    private var lastPhotoView: some View {
        ZStack(alignment: .bottomTrailing) {
            if let lastPhoto {
                Image(uiImage: lastPhoto)
                    .resizable()
                    .scaledToFill()
                    .frame(width: lastPhotoSize, height: lastPhotoSize)
                    .clipShape(Circle())
                    .accessibilityLabel("Zuletzt aufgenommenes Foto")
            } else {
                Circle()
                    .strokeBorder(.white.opacity(0.6), lineWidth: placeholderLineWidth)
                    .frame(width: lastPhotoSize, height: lastPhotoSize)
                    .accessibilityHidden(true)
            }
            Text(count, format: .number)
                .font(AppFont.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, AppSpacing.xs)
                .background(AppColor.cameraScrimStrong, in: Capsule())
                // On the rim of the round thumbnail, like a badge.
                .offset(x: AppSpacing.xs, y: AppSpacing.xxs)
                // The shutter carries the count as its value.
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.footnote)
                .foregroundStyle(.white)
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.danger, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(AppSpacing.lg)
        }
    }

    private func notice(_ title: String, detail: String?, settingsButton: Bool) -> some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "camera.fill")
                .font(AppFont.screenTitle)
                .accessibilityHidden(true)
            Text(title)
                .font(AppFont.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(AppFont.body)
                    .multilineTextAlignment(.center)
            }
            if settingsButton {
                Button("Einstellungen öffnen") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            doneButton
        }
        .foregroundStyle(.white)
        .padding(AppSpacing.xl)
    }

    private var countText: String {
        count == 1 ? String(localized: "1 Foto") : String(localized: "\(count) Fotos")
    }

    /// Takes the picked photos over in the background; the shutter stays
    /// usable meanwhile.
    private func importFromGallery(_ items: [PhotosPickerItem]) {
        let loaders: [() async throws -> Data?] = items.map { item in
            { try await item.loadTransferable(type: Data.self) }
        }
        Task {
            let result = await CameraGalleryImport.run(
                loaders,
                prepare: { await PhotoImportFormat.prepared($0) },
                store: { try onPhoto($0) }
            )
            if result.stored > 0, let last = result.last {
                count += result.stored
                lastPhoto = PhotoStorage.thumbnail(data: last, maxPixel: lastPhotoPixels)
                errorMessage = nil
            }
            if result.failed > 0 {
                errorMessage = result.failed == 1
                    ? String(localized: "1 Foto aus der Galerie nicht übernommen")
                    : String(localized: "\(result.failed) Fotos aus der Galerie nicht übernommen")
                AccessibilityNotification.Announcement("Fotos aus der Galerie nicht übernommen").post()
            } else if result.stored > 0 {
                let taken = result.stored == 1
                    ? String(localized: "1 Foto übernommen")
                    : String(localized: "\(result.stored) Fotos übernommen")
                AccessibilityNotification.Announcement("\(taken), \(countText)").post()
            }
        }
    }

    /// The snap stop the zoom sits on, nil between them.
    private var currentSnap: CGFloat? {
        camera.zoomScale.snapStops.first { abs($0 - camera.zoomFactor) < lensTolerance }
    }

    /// The focus slider in words; ticks when the words change.
    private var focusValueBucket: String {
        FocusStage.focusValueText(lensPosition: camera.lensPosition)
    }

    private func updateTorch() {
        camera.updateTorch(sceneActive: scenePhase == .active, pickerOpen: pickerOpen)
    }

    /// Hands the photo to `onPhoto`; counts and shows it only when it
    /// was stored.
    private func store(_ data: Data) {
        do {
            try onPhoto(data)
        } catch {
            Log.ui.error("camera photo not stored: \(error.localizedDescription, privacy: .public)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Das Foto konnte nicht gespeichert werden."
            AccessibilityNotification.Announcement("Foto nicht gespeichert").post()
            return
        }
        errorMessage = nil
        count += 1
        lastPhoto = PhotoStorage.thumbnail(data: data, maxPixel: lastPhotoPixels)
        AccessibilityNotification.Announcement("Foto \(count) aufgenommen").post()
    }
}

/// Turns a control by the given degrees, animated unless Reduce Motion
/// is on.
private struct UprightToHorizon: ViewModifier {
    let degrees: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(degrees))
            .animation(AppMotion.respecting(AppMotion.base, reduceMotion: reduceMotion), value: degrees)
    }
}

/// Holds the latest fix for the capture closure, which outlives the
/// view value that created it.
private final class FixBox {
    var location: CLLocation?
}

#Preview("Ohne Kamera") {
    CameraView(onPhoto: { _ in }, onDone: {})
}

#Preview("AX5") {
    CameraView(onPhoto: { _ in }, onDone: {})
        .dynamicTypeSize(.accessibility5)
}
