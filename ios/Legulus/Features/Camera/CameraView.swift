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

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorSchemeContrast) private var contrast

    /// How often the position is refreshed while the camera is open;
    /// below `LocationThreshold.staleness`.
    private let fixRefreshInterval: Duration = .seconds(10)

    @ScaledMetric(relativeTo: .body) private var shutterSize: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var lastPhotoSize: CGFloat = 56
    /// Width of the shutter's ring.
    private let ringWidth: CGFloat = 4
    /// Mindestgröße eines Tap-Targets (Apple HIG).
    private let minTapTarget: CGFloat = 44
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
    }

    @ViewBuilder
    private var content: some View {
        switch camera.state {
        case .idle, .running, .switching:
            ZStack {
                preview
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                        .background(alignment: .top) { scrim(from: .top) }
                    Spacer(minLength: 0)
                    errorBanner
                    bottomBar
                        .background(alignment: .bottom) { scrim(from: .bottom) }
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
            onPinchChanged: { camera.zoom(by: $0) },
            onPinchEnded: { camera.zoomEnded() }
        )
        // Pinch and tap are gestures VoiceOver and Switch Control cannot
        // perform; the picture itself is the element that zooms and
        // focuses for them.
        .accessibilityElement()
        .accessibilityLabel("Kamerabild")
        .accessibilityHint("Wische nach oben oder unten zum Zoomen.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: camera.zoomIn()
            case .decrement: camera.zoomOut()
            @unknown default: break
            }
        }
        .accessibilityAction(named: "In der Bildmitte scharfstellen") { camera.focusCenter() }
    }

    private var topBar: some View {
        HStack(spacing: AppSpacing.md) {
            closeButton
            Spacer(minLength: AppSpacing.sm)
            if hasLightChoice {
                lightButton
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    private var closeButton: some View {
        Button(action: onDone) {
            Image(systemName: "xmark")
                .font(AppFont.sectionTitle)
                .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Schließen")
    }

    private var lightButton: some View {
        Button {
            camera.cycleLight()
        } label: {
            Image(systemName: lightSymbol)
                .font(AppFont.sectionTitle)
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

    private var bottomBar: some View {
        // Three equal columns keep the shutter in the middle.
        HStack(alignment: .center, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                lastPhotoBlock
                Spacer(minLength: 0)
                galleryButton
            }
            .frame(maxWidth: .infinity)
            shutter
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.lg)
    }

    private var galleryButton: some View {
        Button {
            pickerOpen = true
        } label: {
            Image(systemName: "photo.on.rectangle")
                .font(AppFont.sectionTitle)
                .foregroundStyle(.white)
                .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                .contentShape(Rectangle())
        }
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

    /// The last picture with the count of this session below it.
    private var lastPhotoBlock: some View {
        VStack(spacing: AppSpacing.xxs) {
            lastPhotoView
            Text(countText)
                .font(AppFont.footnote.monospacedDigit())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                // The shutter carries the count as its value.
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var lastPhotoView: some View {
        if let lastPhoto {
            Image(uiImage: lastPhoto)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: lastPhotoSize, height: lastPhotoSize)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .accessibilityLabel("Zuletzt aufgenommenes Foto")
        } else {
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(.white.opacity(0.6), lineWidth: placeholderLineWidth)
                .frame(width: lastPhotoSize, height: lastPhotoSize)
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
                errorMessage = String(localized: "\(result.failed) Fotos aus der Galerie nicht übernommen")
                AccessibilityNotification.Announcement("Fotos aus der Galerie nicht übernommen").post()
            } else if result.stored > 0 {
                AccessibilityNotification.Announcement("\(result.stored) Fotos übernommen, \(countText)").post()
            }
        }
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
