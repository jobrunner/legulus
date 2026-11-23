import CoreGraphics
import CoreLocation
import Foundation

/// Slippy-map tile arithmetic (Web Mercator, as OpenStreetMap and
/// OpenTopoMap number their tiles). Pure, so the geometry is tested
/// without a network.
enum TopoTiles {
    /// Northern and southern edge of the Web Mercator world.
    static let maxLatitude = 85.051_128_78
    /// One tile to draw: its index and where its top-left corner lands
    /// in the image, in points.
    struct TilePlacement: Equatable {
        let x: Int
        let y: Int
        let z: Int
        let origin: CGPoint
    }

    /// Position of a coordinate in tile units at `zoom`: the integer part
    /// is the tile's column/row, the fraction the position inside it.
    static func worldPixel(lat: Double, lon: Double, zoom: Int) -> CGPoint {
        let n = pow(2, Double(zoom))
        let x = (lon + 180) / 360 * n
        // Web Mercator ends at ±85.0511°; at the poles the formula runs
        // to infinity and Int(floor(_:)) would trap.
        let phi = min(max(lat, -maxLatitude), maxLatitude) * .pi / 180
        let y = (1 - log(tan(phi) + 1 / cos(phi)) / .pi) / 2 * n
        return CGPoint(x: x, y: y)
    }

    /// The tiles covering an image of `size` points with `center` at
    /// `anchor` (the middle by default; lower when the image's top lies
    /// under the bars), each drawn `tileSide` points wide. Columns wrap
    /// around the date line; rows beyond the poles are left out.
    static func placements(
        center: CLLocationCoordinate2D, zoom: Int, size: CGSize, tileSide: CGFloat, anchor: CGPoint? = nil
    ) -> [TilePlacement] {
        let a = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let c = worldPixel(lat: center.latitude, lon: center.longitude, zoom: zoom)
        let n = 1 << zoom
        // Tile units from the anchor to the image's edges.
        let left = a.x / tileSide, right = (size.width - a.x) / tileSide
        let top = a.y / tileSide, bottom = (size.height - a.y) / tileSide
        let minX = Int(floor(c.x - left)), maxX = Int(floor(c.x + right))
        let minY = Int(floor(c.y - top)), maxY = Int(floor(c.y + bottom))
        var tiles: [TilePlacement] = []
        for ty in minY ... maxY where ty >= 0 && ty < n {
            for tx in minX ... maxX {
                let origin = CGPoint(
                    x: (CGFloat(tx) - c.x) * tileSide + a.x,
                    y: (CGFloat(ty) - c.y) * tileSide + a.y
                )
                tiles.append(TilePlacement(x: ((tx % n) + n) % n, y: ty, z: zoom, origin: origin))
            }
        }
        return tiles
    }
}
