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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var isTopo = false
    @State private var showsAttribution = false

    /// The map doesn't grow with Dynamic Type: it is a picture, not text.
    static let height: CGFloat = 200
    /// Rendered for the widest phone; narrower screens crop the sides,
    /// the pin stays in the middle.
    private static let renderSize = CGSize(width: 430, height: height)
    private let minTapTarget: CGFloat = 44

    var body: some View {
        if let coordinate {
            MapSnippetImage(image: image, height: Self.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Karte des Probenorts")
                .accessibilityAddTraits(.isImage)
                .overlay(alignment: .bottom) { attribution }
                .task(id: renderKey(for: coordinate)) { await load(coordinate) }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var attribution: some View {
        if isTopo {
            HStack(alignment: .bottom, spacing: AppSpacing.sm) {
                if showsAttribution {
                    Text("Kartendaten © OpenStreetMap-Mitwirkende, SRTM · Kartendarstellung © OpenTopoMap (CC-BY-SA)")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textPrimary)
                        .padding(AppSpacing.sm)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(AppMotion.respecting(AppMotion.fast, reduceMotion: reduceMotion)) { showsAttribution.toggle() }
                } label: {
                    Image(systemName: showsAttribution ? "xmark.circle.fill" : "info.circle.fill")
                        .font(AppFont.headline)
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(AppSpacing.xs)
                        .background(.regularMaterial, in: Circle())
                        .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsAttribution ? "Kartenquellen ausblenden" : "Kartenquellen")
            }
            .padding(AppSpacing.xs)
        }
    }

    private var placeholder: some View {
        ZStack {
            AppColor.surfaceTertiary
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "map")
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(AppColor.textSecondary)
                    .accessibilityHidden(true)
                Text("Karte erscheint, sobald die Position bekannt ist.")
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
        // A missing map never blocks the sample: the gradient stays.
        guard let result = await TopoMapRenderer.image(
            at: coordinate, size: Self.renderSize, dark: colorScheme == .dark
        ) else { return }
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
