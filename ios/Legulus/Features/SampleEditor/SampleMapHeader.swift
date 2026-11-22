import CoreLocation
import SwiftUI
import UIKit

/// The map at the top of the sample view, edge to edge: OpenTopoMap
/// around the sample's coordinate with the pin in the middle (see
/// `TopoMapRenderer`), the Apple map when the tiles can't be loaded, a
/// placeholder without coordinate.
///
/// The topographic map carries its attribution behind an ⓘ button, as
/// the OpenStreetMap attribution guidelines allow on small screens: a
/// tap shows the sources over the map's lower edge.
struct SampleMapHeader: View {
    let coordinate: CLLocationCoordinate2D?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var isTopo = false
    @State private var showsAttribution = false
    /// Neither the tiles nor the Apple map could be had: the placeholder
    /// says so instead of an endless spinner.
    @State private var failed = false
    /// The coordinate the current image shows (without the colour
    /// scheme): a new one drops the old picture and its pin.
    @State private var shownCoordinateKey: String?

    /// The map doesn't grow with Dynamic Type: it is a picture, not text.
    static let height: CGFloat = 200
    /// Rendered for the widest phone; narrower screens crop the sides,
    /// the pin stays in the middle.
    private static let renderSize = CGSize(width: 430, height: height)
    private let minTapTarget: CGFloat = 44
    /// Width the sources popover asks for; it wraps below that.
    @ScaledMetric(relativeTo: .footnote) private var popoverWidth: CGFloat = 280

    var body: some View {
        if let coordinate {
            Group {
                if failed, image == nil {
                    placeholder("Karte ist offline nicht verfügbar.")
                } else {
                    MapSnippetImage(image: image, height: Self.height)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Karte des Probenorts")
                        .accessibilityAddTraits(.isImage)
                        .overlay(alignment: .bottom) { attribution }
                }
            }
            .task(id: renderKey(for: coordinate)) { await load(coordinate) }
        } else {
            placeholder("Karte erscheint, sobald die Position bekannt ist.")
        }
    }

    /// The ⓘ button; the sources open in a popover, which wraps at any
    /// text size instead of being cut by the map's frame.
    @ViewBuilder
    private var attribution: some View {
        if isTopo {
            HStack {
                Spacer(minLength: 0)
                Button {
                    showsAttribution = true
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(AppFont.headline)
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(AppSpacing.xs)
                        .background(.regularMaterial, in: Circle())
                        .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kartenquellen")
                .popover(isPresented: $showsAttribution) {
                    Text("Kartendaten © OpenStreetMap-Mitwirkende, SRTM · Kartendarstellung © OpenTopoMap (CC-BY-SA)")
                        .font(AppFont.footnote)
                        // Lets the popover grow with the text instead of
                        // truncating it at large sizes (wanted here).
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(AppSpacing.lg)
                        .frame(idealWidth: popoverWidth)
                        .presentationCompactAdaptation(.popover)
                }
            }
            .padding(AppSpacing.xs)
        }
    }

    private func placeholder(_ text: String) -> some View {
        ZStack {
            AppColor.surfaceTertiary
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "map")
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(AppColor.textSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(AppFont.footnote)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xl)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
    }

    /// Five decimals ≈ 1 m: stable while nothing moves the pin.
    private func renderKey(for coord: CLLocationCoordinate2D) -> String {
        String(format: "%.5f|%.5f|%d", coord.latitude, coord.longitude, colorScheme == .dark ? 1 : 0)
    }

    private func load(_ coordinate: CLLocationCoordinate2D) async {
        let coordinateKey = String(format: "%.5f|%.5f", coordinate.latitude, coordinate.longitude)
        if coordinateKey != shownCoordinateKey {
            image = nil
            isTopo = false
            showsAttribution = false
            shownCoordinateKey = coordinateKey
        }
        failed = false
        // A missing map never blocks the sample.
        let result = await TopoMapRenderer.image(
            at: coordinate, size: Self.renderSize, scale: displayScale, dark: colorScheme == .dark
        )
        if Task.isCancelled { return }
        guard let result else {
            failed = true
            return
        }
        image = result.image
        isTopo = result.isTopo
    }
}

/// The snapshot (or the loading gradient) in the snippet's frame. A
/// view of its own so the layout is testable without rendering a map.
struct MapSnippetImage: View {
    let image: UIImage?
    let height: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(.systemGray5), Color(.systemGray6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                ProgressView()
            }
        }
        .frame(height: height)
        // `minWidth: 0`: the filled image is wider than a narrow screen
        // (369 pt at this height, 320 pt with Display Zoom). Without it
        // the frame can't go below the image and widens the editor.
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
    }
}
