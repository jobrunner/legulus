import CoreLocation
@testable import Legulus
import XCTest

final class MapSnapshotterTests: XCTestCase {
    private let wuerzburg = CLLocationCoordinate2D(latitude: 49.791234, longitude: 9.953456)

    func testRegionCenter_MiddleAnchorKeepsTheCoordinate() {
        let size = CGSize(width: 430, height: 300)
        let c = MapSnapshotter.regionCenter(
            for: wuerzburg, size: size, span: 0.04, anchor: CGPoint(x: 215, y: 150)
        )
        XCTAssertEqual(c.latitude, wuerzburg.latitude, accuracy: 1e-9)
        XCTAssertEqual(c.longitude, wuerzburg.longitude, accuracy: 1e-9)
    }

    /// The pin 60 pt below the middle of a 300 pt high image spanning
    /// 0,04° puts the map's centre 0,008° north of the coordinate.
    func testRegionCenter_LowerAnchorMovesTheCentreNorth() {
        let size = CGSize(width: 430, height: 300)
        let c = MapSnapshotter.regionCenter(
            for: wuerzburg, size: size, span: 0.04, anchor: CGPoint(x: 215, y: 210)
        )
        XCTAssertEqual(c.latitude, wuerzburg.latitude + 0.008, accuracy: 1e-9)
        XCTAssertEqual(c.longitude, wuerzburg.longitude, accuracy: 1e-9)
    }
}
