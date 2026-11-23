import SwiftUI

/// Capsule behind a short status or tag: the sample's sync state and
/// fieldtrip under its code, the Köppen code next to the weather.
///
/// `fill` is the capsule's colour: `surfaceCard` on the grouped
/// backdrop, `surfaceGrouped` inside a card. With Increase Contrast the
/// capsule gets an outline, so it doesn't melt into its surroundings.
struct AppChipStyle: ViewModifier {
    var fill: Color = AppColor.surfaceCard

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(fill, in: Capsule())
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(AppColor.outlineSubtle)
                }
            }
    }
}

extension View {
    /// See `AppChipStyle`.
    func appChipStyle(fill: Color = AppColor.surfaceCard) -> some View {
        modifier(AppChipStyle(fill: fill))
    }
}

private struct AppChipPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                SyncStatusBadge(status: .synced, compact: false).appChipStyle()
                Label("Sammeltag 22.11.2026", systemImage: "map")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .appChipStyle()
            }
            AppCard {
                Text("Köppen Cfb")
                    .font(AppFont.footnote)
                    .appChipStyle(fill: AppColor.surfaceGrouped)
            }
        }
        .padding()
        .background(AppColor.surfaceGrouped)
    }
}

#Preview("Default") {
    AppChipPreview()
}

#Preview("AX5") {
    AppChipPreview()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dark") {
    AppChipPreview()
        .preferredColorScheme(.dark)
}
