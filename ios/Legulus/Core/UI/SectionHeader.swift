import SwiftUI

/// Small-caps section label used throughout the app — e.g.
/// "STANDORT UND ZEIT" in the sample editor, "RECENTLY SAMPLE" in
/// the home header.
///
/// Carries the `.isHeader` accessibility trait so VoiceOver can jump
/// between sections.
///
/// The title is a `LocalizedStringKey`, so it lands in the string
/// catalog (literals and interpolations like „Fotos · \(count)“ alike).
struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(AppFont.sectionHeading)
            .textCase(.uppercase)
            .foregroundStyle(AppColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Default") {
    VStack(alignment: .leading, spacing: AppSpacing.lg) {
        SectionHeader(title: "Standort und Zeit")
        SectionHeader(title: "Notizen")
        SectionHeader(title: "Active Collector")
    }
    .padding()
}
