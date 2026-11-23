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
    /// The „Zeit“ card by day (sun), at night (moon, over midnight) and
    /// in twilight (both), at standard size and AX5.
    func testSampleTimeCard() {
        let os = "iOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        let cards = [("day", SampleTimeCardPreviewData.day), ("night", SampleTimeCardPreviewData.night),
                     ("twilight", SampleTimeCardPreviewData.twilight)]
        for (phase, card) in cards {
            for (name, typeSize) in [("default", DynamicTypeSize.large), ("ax5", .accessibility5)] {
                let view = AppCard { card }
                    .padding(.horizontal)
                    .frame(width: 375)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(AppColor.surfaceGrouped)
                    .dynamicTypeSize(typeSize)
                assertSnapshot(
                    of: view,
                    as: .image(precision: 0.99, perceptualPrecision: 0.97, layout: .sizeThatFits),
                    named: "\(phase)-\(name).\(os)"
                )
            }
        }
    }

    func testConditionsSection() {
        var display = ConditionsDisplay(state: .values)
        display.isProvisional = true
        display.provisionalNote = "Wetterwerte vorläufig bis 24.05."
        display.weatherTitle = "Leichter Regen"
        display.weatherSymbol = "cloud.rain"
        display.temperature = "16°C"
        display.temperatureSpoken = "16 Grad Celsius"
        display.tiles = [
            WeatherTile(id: "wind", value: "7", unit: "km/h", caption: "Wind", word: "leichte Brise", spoken: ""),
            WeatherTile(id: "clouds", value: "100", unit: "%", caption: "Wolken", word: nil, spoken: ""),
            WeatherTile(id: "humidity", value: "85", unit: "%", caption: "Feuchte", word: "leicht feucht", spoken: ""),
            WeatherTile(id: "precipitation72", value: "62,5", unit: "mm", caption: "72\u{00A0}h", word: nil, spoken: "")
        ]
        display.koppen = "Dfb"

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
