@testable import Legulus
import XCTest

/// Galerie-Import in der Kamera: Reihenfolge, und ein Fehler hält die
/// übrigen Fotos nicht auf.
final class CameraGalleryImportTests: XCTestCase {
    private struct Offline: Error {}
    private struct DiskFull: Error {}

    func testStoresInSelectionOrder() async {
        var stored: [Data] = []
        let result = await CameraGalleryImport.run(
            [{ Data([1]) }, { Data([2]) }],
            prepare: { $0 },
            store: { stored.append($0) }
        )
        XCTAssertEqual(stored, [Data([1]), Data([2])])
        XCTAssertEqual(result, .init(stored: 2, last: Data([2]), failed: 0))
    }

    func testFailedItemDoesNotStopTheRest() async {
        let result = await CameraGalleryImport.run(
            [{ throw Offline() }, { nil }, { Data([3]) }],
            prepare: { $0 },
            store: { _ in }
        )
        XCTAssertEqual(result, .init(stored: 1, last: Data([3]), failed: 2))
    }

    func testConversionFailureCounts() async {
        let result = await CameraGalleryImport.run([{ Data([4]) }], prepare: { _ in nil }, store: { _ in })
        XCTAssertEqual(result, .init(stored: 0, last: nil, failed: 1))
    }

    func testStoreErrorCounts() async {
        let result = await CameraGalleryImport.run([{ Data([5]) }], prepare: { $0 }, store: { _ in throw DiskFull() })
        XCTAssertEqual(result.failed, 1)
        XCTAssertNil(result.last)
    }
}
