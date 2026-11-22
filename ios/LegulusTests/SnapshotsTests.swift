@testable import Legulus
import SnapshotTesting
import SwiftUI
import XCTest

/// Beispiel-Snapshot-Test als Smoketest für die Snapshot-Pipeline.
/// Konzept (siehe pointfree.co/swift-snapshot-testing):
///   - Erster Run: legt eine Referenz unter __Snapshots__/ an,
///     gilt als „record OK" → Test grün.
///   - Folgende Runs: vergleicht gerenderten View gegen Referenz; bei
///     Diff wird der Test rot und der Diff-PNG-Pfad gemeldet.
///
/// **Refresh** (z. B. nach absichtlichem UI-Change):
///   `isRecording = true` im Test setzen, einmal laufen lassen,
///   Flag wieder entfernen. ODER über Schema-Env-Var
///   `SNAPSHOT_TESTING_RECORD=true` global.
///
/// **Tests laufen auch ohne Snapshots**: beim ersten Run werden die
/// Bilder erzeugt und der Test ist grün. Auf einem CI-Runner ohne
/// committeten Snapshot würde das ebenfalls grün — daher Snapshots
/// **immer committen**, damit Regressions ab dem zweiten Run greifen.
final class SnapshotsTests: XCTestCase {
    /// Stabile Render-Konfiguration: fixe Größe, fixer Trait-Stack.
    /// Verhindert Flackern durch Simulator-Variationen.
    private let size = CGSize(width: 320, height: 80)

    func testPrimaryButton() {
        let view = PrimaryButton(title: "Sample anlegen", systemImage: "plus.circle.fill") {}
            .padding()
            .frame(width: size.width, height: size.height)
            .fixedSize()

        // Eine Referenz pro iOS-Hauptversion: `borderedProminent` hat
        // unter iOS 18 und iOS 26 andere Innenabstände und Schrift-
        // metrik, ein gemeinsames Bild wäre auf einer Seite immer rot.
        // Precision-Toleranzen fangen nur kleine Renderer-Diffs ab
        // (lokales Xcode ≠ CI-Xcode); 0.99/0.97 sind die Point-Free-
        // Empfehlungen für stabile SwiftUI-Smoketests.
        assertSnapshot(
            of: view,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.97,
                layout: .fixed(width: size.width, height: size.height)
            ),
            named: "iOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        )
    }

    /// Two columns at standard size, one at accessibility sizes.
    func testValuePairGrid() {
        let items = [
            LabeledValue(id: "h", label: "Luftfeuchte", value: "62 %", spoken: "Luftfeuchte 62 Prozent"),
            LabeledValue(id: "d", label: "Taupunkt", value: "11,0 °C", spoken: "Taupunkt 11,0 Grad Celsius"),
            LabeledValue(id: "w", label: "Wind", value: "9 km/h", spoken: "Wind 9 Kilometer pro Stunde")
        ]
        let os = "iOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        for (name, typeSize, height) in [("default", DynamicTypeSize.large, CGFloat(80)), ("ax5", .accessibility5, 420)] {
            let view = ValuePairGrid(items)
                .padding()
                .frame(width: size.width)
                .dynamicTypeSize(typeSize)
            assertSnapshot(
                of: view,
                as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .fixed(width: size.width, height: height)),
                named: "\(name).\(os)"
            )
        }
    }

    /// The area „Wetter und Klima“ with a full answer, at standard size
    /// and at AX5 (nothing may clip, pairs stack).
    func testConditionsSection() {
        var display = ConditionsDisplay(state: .values)
        display.isProvisional = true
        display.weatherTitle = "Leichter Regen"
        display.weatherSymbol = "cloud.rain"
        display.temperature = "16,0\u{00A0}°C"
        display.temperatureSpoken = "16,0 Grad Celsius"
        display.hourly = [
            LabeledValue(id: "h", label: "Luftfeuchte", value: "85\u{00A0}%", spoken: ""),
            LabeledValue(id: "d", label: "Taupunkt", value: "13,5\u{00A0}°C", spoken: ""),
            LabeledValue(id: "w", label: "Wind", value: "7\u{00A0}km/h", spoken: ""),
            LabeledValue(id: "c", label: "Bewölkung", value: "100\u{00A0}%", spoken: ""),
            LabeledValue(id: "p", label: "Niederschlag", value: "1,4\u{00A0}mm", spoken: "")
        ]
        display.daily = [
            LabeledValue(id: "p24", label: "Niederschlag 24\u{00A0}h", value: "34,0\u{00A0}mm", spoken: ""),
            LabeledValue(id: "p72", label: "Niederschlag 72\u{00A0}h", value: "62,5\u{00A0}mm", spoken: ""),
            LabeledValue(id: "day", label: "Tag", value: "14,2 – 18,5\u{00A0}°C", spoken: ""),
            LabeledValue(id: "mean", label: "Tagesmittel", value: "17,3\u{00A0}°C", spoken: "")
        ]
        display.sky = [
            LabeledValue(id: "moon", label: "Mond", value: "Vollmond, 98\u{00A0}%", spoken: ""),
            LabeledValue(id: "rise", label: "Sonnenaufgang", value: "05:16", spoken: ""),
            LabeledValue(id: "set", label: "Sonnenuntergang", value: "21:17", spoken: "")
        ]
        display.climate = LabeledValue(id: "climate", label: "Klima", value: "Dfb · submontan-kollin", spoken: "")

        let os = "iOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        for (name, typeSize) in [("default", DynamicTypeSize.large), ("ax5", .accessibility5)] {
            // As tall as the content needs: a fixed height would
            // truncate the texts and hide real clipping.
            let view = ConditionsSection(display: display, detail: ConditionsDetailModel())
                .padding(.horizontal)
                .frame(width: 375)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(.systemBackground))
                .dynamicTypeSize(typeSize)
            assertSnapshot(
                of: view,
                as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .sizeThatFits),
                named: "\(name).\(os)"
            )
        }
    }
}
