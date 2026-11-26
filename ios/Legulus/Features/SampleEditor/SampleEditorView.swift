import CoreLocation
import LegulusGeo
import SwiftUI
import UIKit

/// The sample editor (Phase 14c). Replaces the old `AddSampleView`
/// with a two-section layout inspired by the legacy app:
///
///   ┌─────────────────────────────────────────────┐
///   │  Code (editable)                            │
///   │  Notizen (editable)                         │
///   │  Foto-Strip                                 │
///   ├─────────────────────────────────────────────┤
///   │  STANDORT UND ZEIT                          │
///   │   GPS icon + system / coords + altitude     │
///   │   Gazetteer-Zeile, Peilung, MTB, Gelände    │
///   │   Datum, Uhrzeit, Sonne / Mond              │
///   ├─────────────────────────────────────────────┤
///   │  [ static map snippet with pin ]            │
///   └─────────────────────────────────────────────┘
///
/// The top stays editable; the bottom is read-only and follows the row
/// as a background fix lands, the sync round-trip enriches it or the
/// edit form („Bearbeiten“ → `SampleFormView`, Phase N) saves it.
/// Coordinate, time and place data are edited only in that form.
///
/// Saving (Phase E): no save button for a saved sample. The custom
/// back button saves and validates the id; going to the background
/// saves without dialogs. The navigation bar's back button is hidden
/// and `interactivePopDisabled()` switches off the swipe-back gestures
/// (hiding the button alone doesn't reliably do that on iOS 26), so
/// every way out goes through `finishEditing()`. `onDisappear` stays
/// as the last-resort save (pop-to-root, an unknown gesture).
struct SampleEditorView: View {
    /// Local id of the persisted sample, adopted on init.
    let sampleID: String
    /// The sample was just created instantly on the home screen.
    var isNew: Bool = false
    /// Running number of its suggested id (see `InstantSampleCreator`).
    var suggestedRunning: Int?

    @EnvironmentObject var container: AppContainer

    var body: some View {
        SampleEditorContent(
            sampleID: sampleID,
            isNew: isNew,
            suggestedRunning: suggestedRunning,
            store: container.store,
            photoStore: container.photos,
            fieldtripStore: container.fieldtrips,
            mutationsStore: container.mutations,
            sync: container.sync,
            placemarkStore: container.placemarksStore,
            featureStore: container.sampleFeatures,
            pendingFixes: container.pendingFixes
        )
    }
}

private struct SampleEditorContent: View {
    @StateObject private var viewModel: SampleEditorViewModel
    @EnvironmentObject private var container: AppContainer
    /// Coordinate display format; the view follows a settings change.
    @EnvironmentObject private var config: AppConfig
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingCamera = false
    /// Simulator stand-in for the camera.
    @State private var showingPicker = false
    /// Photo the delete confirmation is open for.
    @State private var photoToDelete: String?
    @FocusState private var notesFocused: Bool
    @FocusState private var codeFocused: Bool

    /// The edit form („Bearbeiten“) is pushed.
    @State private var showingForm = false
    /// „Bestimmen“ in the action bar opens a new determination.
    @State private var presentingNewDetermination = false
    /// Height of status and navigation bar: the map reaches up under
    /// them by this much.
    @State private var topBarInset: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    /// Height of the action bar's buttons: large enough for gloves.
    @ScaledMetric(relativeTo: .body) private var actionBarHeight: CGFloat = 56
    /// At AX sizes the buttons show icons only: more height buys nothing
    /// and would eat a quarter of the screen.
    private let actionBarMaxHeight: CGFloat = 80

    /// Photo thumbnail edge in the editor's strip.
    @ScaledMetric(relativeTo: .body) private var thumbSize: CGFloat = 72

    init(
        sampleID: String,
        isNew: Bool,
        suggestedRunning: Int?,
        store: LocalSampleStore,
        photoStore: LocalPhotoStore,
        fieldtripStore: LocalFieldtripStore,
        mutationsStore: PendingMutationsStore,
        sync: SyncRunner,
        placemarkStore: LocalPlacemarkStore,
        featureStore: LocalSampleFeatureStore,
        pendingFixes: PendingFixService
    ) {
        _viewModel = StateObject(wrappedValue: SampleEditorViewModel(
            sampleID: sampleID,
            isNew: isNew,
            suggestedRunning: suggestedRunning,
            store: store,
            photoStore: photoStore,
            fieldtripStore: fieldtripStore,
            mutationsStore: mutationsStore,
            sync: sync,
            placemarkStore: placemarkStore,
            featureStore: featureStore,
            pendingFixes: pendingFixes
        ))
    }

    /// Horizontal content inset, the same on both sides. The former
    /// iOS-26 extra 16 pt on the left (render shift after the push) is
    /// gone: the shift no longer shows, the extra inset did.
    private var leadingMargin: CGFloat {
        AppSpacing.lg
    }

    private var trailingMargin: CGFloat {
        AppSpacing.lg
    }

    /// Lines the notes field shows while empty; it grows from there
    /// without an upper bound. Counted in lines, so it scales with
    /// Dynamic Type.
    private let notesMinLines = 4

    /// Mindestgröße eines Tap-Targets (Apple HIG).
    private let minTapTarget: CGFloat = 44

    /// JPEG quality of the Simulator stand-in (the real camera hands out
    /// its own file and is never re-encoded).
    private let simulatorJPEGQuality: CGFloat = 0.92

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: AppSpacing.md) {
                    // Edge to edge: cancels the contentMargins with the
                    // same negative padding; up under the bars, too.
                    SampleMapHeader(coordinate: viewModel.coordinate, topInset: topBarInset)
                        .padding(.leading, -leadingMargin)
                        .padding(.trailing, -trailingMargin)
                    codeBand
                    AppCard { placeCard }
                    AppCard { timeCard }
                    if let conditions = viewModel.conditionsDisplay {
                        AppCard { ConditionsSection(display: conditions, detail: viewModel.conditionsDetail) }
                    }
                    AppCard { notesCard }
                        .id(Self.notesAnchor)
                    AppCard { photoSection }
                    if viewModel.isExistingSample {
                        SampleDeterminationsSection(
                            localSampleID: viewModel.savedSample?.id ?? "",
                            backendSampleID: viewModel.savedSample?.backendId,
                            presentingNew: $presentingNewDetermination
                        )
                    }
                }
                .padding(.bottom, AppSpacing.lg)
            }
            // The map lies under the notch and the navigation bar.
            .ignoresSafeArea(edges: .top)
            // The field actions stay in thumb reach while scrolling; while
            // typing the keyboard needs the room.
            .safeAreaInset(edge: .bottom) {
                if !notesFocused, !codeFocused {
                    actionBar(proxy)
                }
            }
        }
        // The bars' height, read outside the scroll view: inside, the top
        // safe area is already given up and reads 0.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topBarInset = $0 }
        // contentMargins greift VOR dem iOS-26-CALayer-Shift und ist
        // unsere einzige Stellschraube auf der ScrollView-Ebene.
        .contentMargins(.leading, leadingMargin, for: .scrollContent)
        .contentMargins(.trailing, trailingMargin, for: .scrollContent)
        // Dragging the content down past the keyboard closes it: the
        // iPhone keyboard has no dismiss key and Return adds a line in
        // the notes.
        .scrollDismissesKeyboard(.interactively)
        .background(AppColor.surfaceGrouped)
        .navigationTitle(viewModel.isExistingSample && !viewModel.isNew ? "Probe" : "Neue Probe")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(BarOverMap())
        // Our own back button saves first. The swipe-back is switched
        // off explicitly so it can't bypass the id validation.
        .navigationBarBackButtonHidden(true)
        .interactivePopDisabled()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: goBack) {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "chevron.backward")
                            .accessibilityHidden(true)
                        Text("Zurück")
                    }
                    .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Zurück")
            }
            // Exactly one trailing item: with more, iOS 26 folds them
            // into a „…“ menu. The star sits in the code band, the camera in
            // the action bar.
            if viewModel.isExistingSample {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openForm) {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Bearbeiten")
                    .accessibilityHint("Öffnet Koordinate, Zeit und Ortsdaten zum Bearbeiten.")
                }
            }
        }
        .task {
            viewModel.refreshDerivedFields()
            viewModel.observeRow()
        }
        .onChange(of: scenePhase) { _, phase in
            // Save without dialogs; an empty/taken id stays in the
            // field until the user goes back.
            if phase == .background { viewModel.saveEdits() }
        }
        .onDisappear {
            // Last resort: every regular way out went through
            // `finishEditing()` already.
            if !viewModel.finished { viewModel.saveEdits() }
        }
        .refreshable { viewModel.refreshDerivedFields() }
        .onChange(of: viewModel.code) { _, _ in viewModel.recheckCode() }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView(
                onPhoto: { try viewModel.addCapturedPhoto($0) },
                onDone: { showingCamera = false }
            )
        }
        // Simulator: no camera, the system picker stands in so the photo
        // path stays testable end to end.
        .sheet(isPresented: $showingPicker) {
            CameraPicker { image in
                if let data = image?.jpegData(compressionQuality: simulatorJPEGQuality) {
                    do {
                        try viewModel.addCapturedPhoto(data)
                    } catch {
                        Log.ui.error("picked photo not stored: \(error.localizedDescription, privacy: .public)")
                    }
                }
                showingPicker = false
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Foto löschen?", isPresented: deletePromptBinding, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let id = photoToDelete { viewModel.deletePhoto(id: id) }
                photoToDelete = nil
            }
            Button("Abbrechen", role: .cancel) { photoToDelete = nil }
        } message: {
            Text("Das Foto wird vom Gerät und, falls schon hochgeladen, vom Server entfernt.")
        }
        .alert(
            "Die Sample-ID darf nicht leer sein und muss eindeutig sein.",
            isPresented: promptBinding(.emptyID)
        ) {
            TextField("Sample-ID", text: $viewModel.promptedID)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Speichern") {
                if viewModel.submitPromptedID() { dismiss() }
            }
            Button("Sample löschen", role: .destructive) {
                if viewModel.deleteNewSample() { dismiss() }
            }
        } message: {
            if let reason = viewModel.promptReason {
                Text(reason)
            }
        }
        .alert(
            "Diese Sample-ID ist bereits vergeben.",
            isPresented: promptBinding(.duplicate)
        ) {
            Button("Korrigieren", role: .cancel) {
                viewModel.correctID()
                codeFocused = true
            }
            Button("Bisherige ID behalten") {
                if viewModel.keepPreviousID() { dismiss() }
            }
        }
        .navigationDestination(isPresented: $showingForm) {
            if let id = viewModel.savedSample?.id {
                SampleFormView(sampleID: id)
            }
        }
    }

    // MARK: - leaving

    /// „Bearbeiten“: saves code and notes first (the form works on the
    /// row), then pushes the form.
    private func openForm() {
        notesFocused = false
        codeFocused = false
        viewModel.saveEdits()
        showingForm = true
    }

    private func goBack() {
        notesFocused = false
        codeFocused = false
        if viewModel.finishEditing() { dismiss() }
    }

    /// Alert binding for one id dialog; closing it clears the state.
    private func promptBinding(_ prompt: SampleEditorViewModel.IDPrompt) -> Binding<Bool> {
        Binding(
            get: { viewModel.idPrompt == prompt },
            set: { presented in
                if !presented, viewModel.idPrompt == prompt { viewModel.idPrompt = nil }
            }
        )
    }

    // MARK: - code band and cards

    private static let notesAnchor = "notes"

    /// The sample code right under the map, large and editable, with the
    /// star and the sample's status.
    private var codeBand: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                TextField("Code", text: $viewModel.code)
                    .font(AppFont.codeTitle)
                    // Last resort for long codes at AX sizes; the star
                    // already moved below to give the code the width.
                    .minimumScaleFactor(0.6)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($codeFocused)
                    .accessibilityLabel("Sample-Code")
                    .accessibilityHint(
                        "Vorschlag nach deinem ID-Format. Anpassbar oder leer lassbar, falls du eine andere Nummer auf dem Röhrchen hast."
                    )
                if !dynamicTypeSize.isAccessibilitySize, viewModel.isExistingSample, let sample = viewModel.savedSample {
                    markButton(marked: sample.marked)
                }
            }
            statusChips

            if let codeError = viewModel.codeValidationError {
                Text(codeError)
                    .font(AppFont.footnote)
                    .foregroundStyle(AppColor.danger)
                    .accessibilityLabel("Fehler im Code-Feld: \(codeError)")
            }

            // The server appended a conflict suffix to the sent ID.
            if viewModel.savedSample?.hasIdConflict == true {
                IdConflictHint()
            }

            // Up here, not at the end of the page: „Zurück“ that does
            // nothing must show its reason where the eye is.
            if let saveError = viewModel.saveError {
                Text(saveError)
                    .font(AppFont.footnote)
                    .foregroundStyle(AppColor.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.xs)
    }

    /// Sync state and fieldtrip side by side; below each other when
    /// they don't fit (large type).
    @ViewBuilder
    private var statusChips: some View {
        if let sample = viewModel.savedSample {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.sm) { chips(sample) }
                VStack(alignment: .leading, spacing: AppSpacing.xs) { chips(sample) }
            }
        }
    }

    @ViewBuilder
    private func chips(_ sample: LocalSample) -> some View {
        // At AX sizes the star leaves the code's line and leads here.
        if dynamicTypeSize.isAccessibilitySize, viewModel.isExistingSample {
            markButton(marked: sample.marked)
        }
        SyncStatusBadge(status: sample.syncStatus, compact: false)
            .appChipStyle()
        if let fieldtrip = viewModel.savedFieldtrip {
            Label(fieldtrip.title, systemImage: fieldtrip.nightFieldtrip ? "moon.stars" : "map")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .appChipStyle()
                .accessibilityLabel("Exkursion \(fieldtrip.title)")
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            SectionHeader(title: "Notizen")
            // Vertical TextField without an upper line limit: grows
            // with the text and never scrolls itself, so the outer
            // ScrollView stays the only scroll area (a TextEditor
            // with maxHeight nested a second scroll view in it).
            TextField("optional", text: $viewModel.notes, axis: .vertical)
                .lineLimit(notesMinLines...)
                .focused($notesFocused)
                .accessibilityLabel("Notizen zur Probe")
        }
    }

    private var placeCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            // The place name heads the card once there is one; until then
            // the generic title does.
            if viewModel.isExistingSample, viewModel.placeHeading != nil {
                placeHeading
            } else {
                SectionHeader(title: "Ort")
            }
            locationRow
            if viewModel.isExistingSample {
                placeSection
            }
        }
    }

    private var timeCard: some View {
        SampleTimeCard(texts: dateTexts, sky: timeCardSky, zoneLabel: timezoneLabelText)
    }

    // MARK: - action bar

    /// Notiz · Foto · Bestimmen in thumb reach. At accessibility sizes
    /// the buttons show their icon only; the label stays for VoiceOver.
    private func actionBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: AppSpacing.sm) {
            actionButton("Notiz", systemImage: "square.and.pencil", prominent: false) {
                notesFocused = true
                withAnimation(AppMotion.respecting(AppMotion.base, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(Self.notesAnchor, anchor: .center)
                }
            }
            actionButton("Foto", systemImage: "camera.fill", prominent: true, action: openCamera)
            if viewModel.isExistingSample {
                let canDetermine = viewModel.savedSample?.backendId != nil
                actionButton("Bestimmen", systemImage: "magnifyingglass", prominent: false) {
                    notesFocused = false
                    codeFocused = false
                    presentingNewDetermination = true
                }
                .disabled(!canDetermine)
                .modifier(DisabledHint(isDisabled: !canDetermine, hint: "Erst nach dem Sync möglich."))
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .background(.bar)
    }

    private func actionButton(
        _ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: systemImage)
                } else {
                    VStack(spacing: AppSpacing.xxs) {
                        Image(systemName: systemImage)
                        Text(title).font(AppFont.captionEmphasized)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: min(actionBarHeight, actionBarMaxHeight))
            .foregroundStyle(prominent ? AppColor.brandOnPrimary : AppColor.brandPrimaryText)
            .background(
                prominent ? AppColor.brandPrimary : AppColor.brandTint,
                in: RoundedRectangle(cornerRadius: AppRadius.lg)
            )
            // The light tint fades with Increase Contrast: an outline
            // keeps the button's edge.
            .overlay {
                if contrast == .increased, !prominent {
                    RoundedRectangle(cornerRadius: AppRadius.lg).strokeBorder(AppColor.brandPrimaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionBarButtonStyle())
        .accessibilityLabel(title)
    }

    /// The star: filled when marked, so the state shows in the shape
    /// and not only in the colour.
    private func markButton(marked: Bool) -> some View {
        Button {
            viewModel.toggleMarked(
                endpoint: container.config.endpointURL,
                auth: container.auth
            )
        } label: {
            Image(systemName: marked ? "star.fill" : "star")
                .font(AppFont.sectionTitle)
                .foregroundStyle(marked ? .yellow : .secondary)
                .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(marked ? "Markierung entfernen" : "Probe markieren")
    }

    /// „Fotos“ with the strip, or a hint where the camera is.
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            SectionHeader(title: viewModel.savedPhotos.isEmpty ? "Fotos" : "Fotos · \(viewModel.savedPhotos.count)")
            if viewModel.savedPhotos.isEmpty {
                Text("Noch keine Fotos. „Foto“ in der Leiste unten nimmt eins auf.")
                    .font(AppFont.footnote)
                    .foregroundStyle(AppColor.textSecondary)
            } else {
                photoStrip
            }
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(Array(viewModel.savedPhotos.enumerated()), id: \.element.id) { index, photo in
                    SavedPhotoThumbnail(
                        relativePath: photo.localPath,
                        size: thumbSize,
                        label: "Foto \(index + 1) von \(viewModel.savedPhotos.count)"
                    )
                    // Deleting is offered twice, never by a hidden
                    // gesture alone: context menu and VoiceOver action.
                    .contextMenu {
                        Button(role: .destructive) {
                            photoToDelete = photo.id
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                    .accessibilityAction(named: "Löschen") { photoToDelete = photo.id }
                }
            }
        }
    }

    private var deletePromptBinding: Binding<Bool> {
        Binding(
            get: { photoToDelete != nil },
            set: { presented in
                if !presented { photoToDelete = nil }
            }
        )
    }

    /// The series camera; without a camera (Simulator) the system picker.
    private func openCamera() {
        notesFocused = false
        codeFocused = false
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showingCamera = true
        } else {
            showingPicker = true
        }
    }

    // MARK: - place and time

    /// „Würzburg“, below it the broader units, the bearing and island,
    /// mountain range, mountain: „Unterfranken, Bayern, DE · 2,3km SW
    /// Randersacker · Insel La Palma“. The full hierarchy stays in the
    /// form under „Bearbeiten“.
    @ViewBuilder
    private var placeHeading: some View {
        let heading = viewModel.placeHeading
        let context = heading?.context.joined(separator: ", ") ?? ""
        let landscape = viewModel.placeLandscape.map { "\($0.displayTerm) \($0.value)" }
        let subline = ([context, viewModel.placeBearing ?? ""] + landscape)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if heading != nil || !subline.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                if let heading {
                    Text(heading.title)
                        .font(AppFont.headline)
                        .accessibilityAddTraits(.isHeader)
                }
                if !subline.isEmpty {
                    Text(subline)
                        .font(AppFont.subhead)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// Coordinate and altitude as two small chips side by side, one
    /// below the other when they don't fit. Nobody reads the digits in
    /// the field; the chips say „fixed, ready to copy“.
    private var locationRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppSpacing.md) {
                coordinateChip
                altitudeChip
            }
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                coordinateChip
                altitudeChip
            }
        }
    }

    /// A map pin, the coordinate (grid systems with their name in
    /// front: „MGRS 32U NA …“) and the horizontal accuracy. A tap copies
    /// it (see `ClipboardText`). Without coordinate the chip shows the
    /// GPS state instead (locating, denied, failed).
    @ViewBuilder
    private var coordinateChip: some View {
        if let display = coordinateDisplay, let clipboard = coordinateClipboardText {
            CopyableValueChip(
                clipboardText: clipboard,
                accessibilityLabel: coordinateA11yLabel(display),
                announcement: "Koordinate kopiert"
            ) {
                Image(systemName: "mappin")
                    .foregroundStyle(AppColor.brandPrimaryText)
                    .accessibilityHidden(true)
            } content: {
                withAccuracy(gridLabel + Text(display.text), viewModel.accuracyM)
            }
        } else {
            // Nothing to copy yet: no chip, only the state.
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                GPSStatusIcon(status: locationIconStatus, font: AppFont.caption)
                Text(coordinateText)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .font(AppFont.caption.monospacedDigit())
            .accessibilityElement(children: .combine)
        }
    }

    /// „MGRS “ in the secondary color, empty for degree formats.
    private var gridLabel: Text {
        guard let name = PlaceDisplay.gridSystemLabel(config.coordinateDisplayFormat) else { return Text(verbatim: "") }
        return Text(verbatim: name + " ").foregroundStyle(AppColor.textSecondary)
    }

    /// Altitude with its accuracy, shown only (nobody pastes it), so no
    /// chip: the tinted surface marks what can be tapped.
    private var altitudeChip: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            Image(systemName: "mountain.2")
                .foregroundStyle(AppColor.textSecondary)
            if viewModel.altitudeM != nil {
                withAccuracy(Text(altitudeText), viewModel.savedSample?.verticalAccuracy)
            } else {
                Text(altitudeText)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .font(AppFont.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.altitudeM.map(altitudeA11yLabel) ?? "Höhe unbekannt")
    }

    /// „276 m ±3 m“ with the accuracy in the secondary color.
    private func withAccuracy(_ value: Text, _ accuracy: Double?) -> Text {
        guard let accuracy else { return value }
        return value + Text(String(format: " ±%.0fm", accuracy)).foregroundStyle(AppColor.textSecondary)
    }

    /// Place data of a saved sample: status hints, exposure, MTB and
    /// altitudinal belt, and the actions that
    /// stay here (accept/dismiss a suggestion, resend a failed push).
    /// Editing goes through „Bearbeiten“.
    private var placeSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if viewModel.canResend {
                resendBanner
            }
            if viewModel.hasSuggestion {
                suggestionBanner
            }
            placeStatusLine
            placeSummary
            if let error = viewModel.placeActionError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AppColor.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppSpacing.sm)
    }

    @ViewBuilder
    private var placeStatusLine: some View {
        if let sample = viewModel.savedSample {
            if sample.latitude == nil || sample.longitude == nil {
                Label("Ohne Koordinate – unter „Bearbeiten“ eine Koordinate setzen, damit Ortsangaben ermittelt werden.",
                      systemImage: "mappin.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                enterPlaceButton("Koordinate eingeben")
            } else if viewModel.placeHeading == nil {
                switch sample.locationStatus {
                case .pending:
                    Label("Ortsangaben werden ermittelt – spätestens nach dem nächsten Sync.",
                          systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .backendService:
                    Label("Keine Ortsangaben für diese Koordinate (z. B. auf dem Meer).",
                          systemImage: "water.waves")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    enterPlaceButton("Ortsangaben eingeben")
                case .inherited, .manual:
                    EmptyView()
                }
            }
            if sample.locationStatus == .manual {
                Label("Ortsangaben von Hand gesetzt", systemImage: "hand.point.up.left")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if sample.locationStatus == .inherited {
                Label("Ortsangaben von der vorigen Probe des Tages übernommen", systemImage: "arrow.turn.down.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Opens the edit form where coordinate and place data are set by
    /// hand; `.large` reaches the 44 pt tap target.
    private func enterPlaceButton(_ title: LocalizedStringKey) -> some View {
        Button(action: openForm) {
            Label(title, systemImage: "square.and.pencil")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(AppColor.brandPrimary)
    }

    private var suggestionBanner: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("Neue Ortsangaben verfügbar", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            if let name = viewModel.suggestionName {
                Text("Vorschlag: \(name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.md) {
                    suggestionButtons
                }
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    suggestionButtons
                }
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    @ViewBuilder
    private var suggestionButtons: some View {
        // `.large` bordered buttons reach the 44 pt tap target (a frame
        // outside the button style only grows the layout box).
        Button("Übernehmen") { viewModel.acceptSuggestion() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(AppColor.brandPrimary)
            .accessibilityHint("Ersetzt deine Ortsangaben durch die neu ermittelten.")
        Button("Verwerfen") { viewModel.dismissSuggestion() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Behält deine Ortsangaben und blendet den Vorschlag aus.")
    }

    private var resendBanner: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("Sync fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColor.syncFailed)
            if let error = viewModel.savedSample?.syncError, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.resendFailed()
            } label: {
                Label("Erneut senden", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Überträgt die lokal gespeicherte Probe erneut an den Server.")
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// Aspect and slope as one line, then MTB and altitudinal belt.
    @ViewBuilder
    private var placeSummary: some View {
        let details = placeDetails
        if viewModel.placeExposure != nil || !details.isEmpty {
            // Looked at rarely: the small type of the coordinate, set
            // tight. One line each: „6225/2 Würzburg Süd“ breaks in half
            // a column.
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                if let exposure = viewModel.placeExposure {
                    Text(exposure)
                }
                ForEach(details) { item in
                    (Text(item.label + " ").foregroundStyle(AppColor.textSecondary) + Text(item.value))
                        .accessibilityLabel(item.spoken)
                }
            }
            .font(AppFont.caption.monospacedDigit())
        }
    }

    /// Altitudinal belt and MTB.
    private var placeDetails: [LabeledValue] {
        var items: [LabeledValue] = []
        if let belt = altitudinalBelt {
            let label = String(localized: "Höhenstufe")
            items.append(LabeledValue(id: "belt", label: label, value: belt, spoken: "\(label) \(belt)"))
        }
        if let mtb = viewModel.mtbValue {
            let spoken = String(localized: "Messtischblatt \(mtb)")
            items.append(LabeledValue(id: "mtb", label: String(localized: "MTB"), value: mtb, spoken: spoken))
        }
        return items
    }

    /// From the conditions; only while they fit the sample.
    private var altitudinalBelt: String? {
        guard let display = viewModel.conditionsDisplay, display.state == .values else { return nil }
        return display.altitudinalBelt
    }

    /// The light band of the „Zeit“ card; nil without Tempus values or
    /// for a new, unsaved sample.
    private var timeCardSky: TimeCardSky? {
        guard viewModel.isExistingSample, let display = viewModel.conditionsDisplay else { return nil }
        return TimeCardSky(display: display, begin: viewModel.beginDate, end: viewModel.endDate,
                           isAllDay: viewModel.isAllDay, zone: viewModel.timeZone)
    }

    // MARK: - derived view state

    /// Once the sample is saved we stop showing the "locating" icon
    /// — the persisted coordinate is authoritative even if the GPS
    /// stream is still chattering in the background.
    private var locationIconStatus: LocationProvider.Status {
        if viewModel.isExistingSample, let coord = viewModel.coordinate {
            return .fixed(CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        }
        if hasNoCoordinate {
            return .failed("Ohne Koordinate")
        }
        return viewModel.locationStatus
    }

    /// A saved sample without coordinate that nobody is locating for
    /// (legacy row, or `PendingFixService` gave up).
    private var hasNoCoordinate: Bool {
        viewModel.isExistingSample && viewModel.coordinate == nil
            && viewModel.locationStatus != .locating
    }

    private var coordinateText: String {
        if hasNoCoordinate { return "Ohne Koordinate" }
        guard let c = viewModel.coordinate else {
            switch viewModel.locationStatus {
            case .denied: return "GPS gesperrt"
            case .failed: return "GPS-Fehler"
            default: return "Suche Position …"
            }
        }
        return coordinateDisplay?.text ?? String(format: "%.6f %.6f", locale: .current, c.latitude, c.longitude)
    }

    /// The coordinate in the format chosen in the settings, with the
    /// format's name for the caption; nil without coordinate.
    private var coordinateDisplay: (text: String, caption: String)? {
        guard let c = viewModel.coordinate else { return nil }
        return PlaceDisplay.coordinate(latitude: c.latitude, longitude: c.longitude,
                                       format: config.coordinateDisplayFormat)
    }

    /// The coordinate for the clipboard; nil without coordinate.
    private var coordinateClipboardText: String? {
        guard let c = viewModel.coordinate else { return nil }
        return ClipboardText.coordinate(lat: c.latitude, lon: c.longitude,
                                        format: config.coordinateDisplayFormat)
    }

    private var altitudeText: String {
        if let alt = viewModel.altitudeM { return String(format: "%.0fm", alt) }
        return "—"
    }

    /// Date or range of days and the time window, in the sample's zone
    /// and the device's region. A new, unsaved sample shows today in the
    /// device zone (the zone it will be created in) and no window.
    private var dateTexts: SampleDateTexts {
        if viewModel.isExistingSample {
            return SampleDateTexts(
                begin: viewModel.beginDate, end: viewModel.endDate,
                isAllDay: viewModel.isAllDay, zone: viewModel.timeZone
            )
        }
        return SampleDateTexts(begin: Date(), end: nil, isAllDay: true, zone: .current)
    }

    /// „Atlantic/Canary (WET)“ — Kürzel gilt zum Beginn-Zeitpunkt.
    private var timezoneLabelText: String? {
        guard viewModel.isExistingSample else { return nil }
        return SampleTime.timezoneLabel(viewModel.timeZone, at: viewModel.beginDate)
    }

    // MARK: - A11y labels

    private func coordinateA11yLabel(_ display: (text: String, caption: String)) -> String {
        var parts = ["Koordinate \(display.text), \(display.caption)"]
        if let acc = viewModel.accuracyM {
            parts.append(String(format: "Genauigkeit etwa %.0f Meter", acc))
        }
        return parts.joined(separator: ", ")
    }

    private func altitudeA11yLabel(_ altitude: Double) -> String {
        var parts = [String(format: "Höhe %.0f Meter", altitude)]
        if let acc = viewModel.savedSample?.verticalAccuracy {
            parts.append(String(format: "Fehler etwa %.0f Meter", acc))
        }
        return parts.joined(separator: ", ")
    }
}

/// A square preview of a stored photo. The picture is downsampled while
/// decoding (`PhotoStorage.thumbnail`), so a strip of full-resolution
/// photos stays light.
private struct SavedPhotoThumbnail: View {
    let relativePath: String
    let size: CGFloat
    let label: String

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(AppColor.surfaceSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
        .task(id: relativePath) { await load() }
    }

    private func load() async {
        let path = relativePath
        let pixels = size * displayScale
        image = await Task.detached(priority: .userInitiated) {
            PhotoStorage.thumbnail(relativePath: path, maxPixel: pixels)
        }.value
    }
}

#Preview {
    let container = AppContainer()
    return NavigationStack {
        SampleEditorView(sampleID: "preview")
    }
    .environmentObject(container)
    .environmentObject(container.config)
}

/// Plain button that shows its disabled state: `.plain` with explicit
/// colours would otherwise look the same enabled or not.
private struct ActionBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// An accessibility hint that only applies while the control is
/// disabled (the reason it can't be used).
private struct DisabledHint: ViewModifier {
    let isDisabled: Bool
    let hint: String

    func body(content: Content) -> some View {
        if isDisabled {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

/// Before iOS 26 the navigation bar's items have no glass of their own:
/// over the map they need the bar's blur to stay readable. iOS 26 draws
/// its glass buttons on the map directly.
private struct BarOverMap: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
