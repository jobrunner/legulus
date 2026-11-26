import SwiftUI
import UIKit

/// Ein Messwert als kleiner Chip, der sich per Tap in die
/// Zwischenablage kopieren lässt (Koordinate und Höhe in der
/// Sample-Ansicht). Gelesen wird der Wert selten; der Chip zeigt vor
/// allem, dass er feststeht und dass man damit arbeiten kann. Nach dem
/// Tap wird das Kopier-Symbol kurz zum Haken, VoiceOver bekommt eine
/// Ansage.
///
/// `clipboardText` ist der Text für die Zwischenablage und darf von
/// der Anzeige abweichen (siehe `ClipboardText`).
struct CopyableValueChip<Leading: View, Content: View>: View {
    let clipboardText: String
    let accessibilityLabel: String
    let announcement: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCopied = false
    @State private var copyCount = 0
    @State private var resetTask: Task<Void, Never>?

    /// So lange bleibt der Haken stehen.
    private let confirmationDuration: Duration = .milliseconds(1500)

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                leading()
                content()
                copySymbol
            }
            .valueChipStyle()
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: copyCount)
        .animation(AppMotion.respecting(AppMotion.fast, reduceMotion: reduceMotion), value: showsCopied)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Kopiert in die Zwischenablage")
        .onDisappear {
            // Der abgebrochene Timer setzt den Haken nicht mehr zurück;
            // ohne das stünde er nach der Rückkehr dauerhaft da.
            resetTask?.cancel()
            showsCopied = false
        }
    }

    /// Beide Symbole liegen übereinander und werden nur ein- und
    /// ausgeblendet, damit der Chip beim Tap nicht seine Breite ändert.
    private var copySymbol: some View {
        ZStack {
            Image(systemName: "doc.on.doc")
                .opacity(showsCopied ? 0 : 1)
            Image(systemName: "checkmark")
                .opacity(showsCopied ? 1 : 0)
        }
        .imageScale(.small)
        .foregroundStyle(AppColor.brandPrimaryText)
        .accessibilityHidden(true)
    }

    private func copy() {
        UIPasteboard.general.string = clipboardText
        copyCount += 1
        showsCopied = true
        AccessibilityNotification.Announcement(announcement).post()
        // Ein früher gestarteter Timer darf den neuen Haken nicht
        // vorzeitig ausblenden.
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: confirmationDuration)
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }
}

/// Form der Wert-Chips: kleine Ziffern mit fester Breite auf einer
/// getönten Fläche. Das Tap-Target ist trotzdem 44 pt hoch.
private struct ValueChipStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    /// Mindestgröße des Tap-Targets (Apple HIG).
    private let minTapTarget: CGFloat = 44

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
        content
            .font(AppFont.caption.monospacedDigit())
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(AppColor.surfaceGrouped, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(AppColor.outlineSubtle)
                }
            }
            .frame(minWidth: minTapTarget, minHeight: minTapTarget)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Siehe `CopyableValueChip`; auch für einen Chip ohne Wert
    /// („Suche Position …“), damit die Zeile gleich aussieht.
    func valueChipStyle() -> some View {
        modifier(ValueChipStyle())
    }
}

#Preview("Default") {
    CopyableValueChipPreview()
}

#Preview("AX5") {
    CopyableValueChipPreview()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Dark") {
    CopyableValueChipPreview()
        .preferredColorScheme(.dark)
}

private struct CopyableValueChipPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            CopyableValueChip(
                clipboardText: "32UNA6938014686",
                accessibilityLabel: "Koordinate 32U NA 69380 14686, MGRS",
                announcement: "Koordinate kopiert"
            ) {
                Image(systemName: "location.fill")
                    .foregroundStyle(AppColor.brandPrimaryText)
            } content: {
                Text(verbatim: "32U NA 69380 14686")
                    + Text(verbatim: " ±5 m").foregroundStyle(AppColor.textSecondary)
            }
            CopyableValueChip(
                clipboardText: "276m",
                accessibilityLabel: "Höhe 276 Meter",
                announcement: "Höhe kopiert"
            ) {
                Image(systemName: "mountain.2")
                    .foregroundStyle(AppColor.textSecondary)
            } content: {
                Text(verbatim: "276 m")
            }
        }
        .padding()
    }
}
