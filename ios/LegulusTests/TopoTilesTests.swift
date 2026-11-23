import CoreLocation
@testable import Legulus
import XCTest

final class TopoTilesTests: XCTestCase {
    private let wuerzburg = CLLocationCoordinate2D(latitude: 49.791234, longitude: 9.953456)

    func testWorldPixel_KnownCoordinate() {
        let p = TopoTiles.worldPixel(lat: wuerzburg.latitude, lon: wuerzburg.longitude, zoom: 15)
        XCTAssertEqual(p.x, 17289.986, accuracy: 0.001)
        XCTAssertEqual(p.y, 11142.594, accuracy: 0.001)
    }

    func testWorldPixel_Origin() {
        let p = TopoTiles.worldPixel(lat: 0, lon: 0, zoom: 1)
        XCTAssertEqual(p.x, 1, accuracy: 1e-9)
        XCTAssertEqual(p.y, 1, accuracy: 1e-9)
    }

    /// The tiles cover the whole rectangle, the coordinate in its middle.
    func testPlacements_CoverTheRectangle() {
        let size = CGSize(width: 390, height: 200)
        let tiles = TopoTiles.placements(center: wuerzburg, zoom: 15, size: size, tileSide: 192)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertLessThanOrEqual(tiles.map(\.origin.x).min() ?? 1, 0)
        XCTAssertLessThanOrEqual(tiles.map(\.origin.y).min() ?? 1, 0)
        XCTAssertGreaterThanOrEqual((tiles.map(\.origin.x).max() ?? 0) + 192, size.width)
        XCTAssertGreaterThanOrEqual((tiles.map(\.origin.y).max() ?? 0) + 192, size.height)
        XCTAssertTrue([6, 8, 9, 12].contains(tiles.count), "3×2 … 4×3 tiles, got \(tiles.count)")
        XCTAssertTrue(tiles.contains { $0.x == 17289 && $0.y == 11142 && $0.z == 15 }, "the centre tile")
    }

    /// Next to the date line the columns wrap around.
    func testPlacements_WrapAtTheDateLine() {
        let edge = CLLocationCoordinate2D(latitude: 10, longitude: 179.99)
        let tiles = TopoTiles.placements(center: edge, zoom: 4, size: CGSize(width: 390, height: 200), tileSide: 192)
        XCTAssertTrue(tiles.contains { $0.x == 0 }, "the column east of the last one is 0")
        XCTAssertTrue(tiles.allSatisfy { (0 ..< 16).contains($0.x) })
    }

    /// Beyond the top of the world there is nothing to load.
    func testPlacements_NoRowsOutsideTheWorld() {
        let north = CLLocationCoordinate2D(latitude: 85.05, longitude: 0)
        let tiles = TopoTiles.placements(center: north, zoom: 3, size: CGSize(width: 390, height: 200), tileSide: 192)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.allSatisfy { $0.y >= 0 && $0.y < 8 })
    }

    /// The poles lie outside Web Mercator: clamped, no trap on infinity.
    func testWorldPixel_PolesAreClamped() {
        let south = TopoTiles.worldPixel(lat: -90, lon: 0, zoom: 3)
        XCTAssertTrue(south.y.isFinite)
        XCTAssertEqual(south.y, 8, accuracy: 0.001, "the bottom edge of the world")
        let tiles = TopoTiles.placements(
            center: CLLocationCoordinate2D(latitude: -90, longitude: 0), zoom: 3,
            size: CGSize(width: 390, height: 200), tileSide: 192
        )
        XCTAssertTrue(tiles.allSatisfy { $0.y >= 0 && $0.y < 8 })
    }
}
