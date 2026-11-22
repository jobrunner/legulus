import CoreLocation
import CryptoKit
import Foundation
import UIKit

/// Renders the sample's map header from OpenTopoMap tiles: loads the
/// tiles around the coordinate, draws them into one image with the pin
/// in the middle and caches the result per coordinate and size.
///
/// Offline first: a cached image is used as is; when a tile cannot be
/// loaded, the Apple map snapshot (`MapSnapshotter`) stands in and is
/// not cached as a topographic map, so the next view tries again.
enum TopoMapRenderer {
    /// Zoom level of the header: about one kilometre across.
    static let zoom = 15
    /// OpenTopoMap tiles are 256 px without a retina variant; drawn at
    /// 192 pt they stay readable without looking blurred.
    static let tileSide: CGFloat = 192

    private static let timeout: TimeInterval = 8
    private static let memoryCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 100
        return c
    }()

    /// The header image and whether it is the topographic map (the
    /// attribution belongs to it) or the Apple fallback; nil when both
    /// fail.
    static func image(at coord: CLLocationCoordinate2D, size: CGSize, dark: Bool) async -> (image: UIImage, isTopo: Bool)? {
        let key = cacheKey(coord: coord, size: size)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return (cached, true)
        }
        if let url = diskURL(for: key), let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: key as NSString)
            return (image, true)
        }
        let start = Date()
        if let image = await renderTopo(coord: coord, size: size) {
            Log.network.info(
                "topo header rendered in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms"
            )
            memoryCache.setObject(image, forKey: key as NSString)
            if let url = diskURL(for: key), let data = image.pngData() {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? data.write(to: url)
            }
            return (image, true)
        }
        if let fallback = try? await MapSnapshotter.snapshot(at: coord, size: size, dark: dark) {
            return (fallback, false)
        }
        return nil
    }

    // MARK: - private

    private static func renderTopo(coord: CLLocationCoordinate2D, size: CGSize) async -> UIImage? {
        let placements = TopoTiles.placements(center: coord, zoom: zoom, size: size, tileSide: tileSide)
        guard !placements.isEmpty else { return nil }
        var tiles: [(TopoTiles.TilePlacement, UIImage)] = []
        do {
            try await withThrowingTaskGroup(of: (TopoTiles.TilePlacement, UIImage).self) { group in
                for placement in placements {
                    group.addTask {
                        let image = try await loadTile(placement)
                        return (placement, image)
                    }
                }
                for try await tile in group {
                    tiles.append(tile)
                }
            }
        } catch {
            Log.network.warning("topo tile failed, Apple map stands in: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let scale = await MainActor.run { UIScreen.main.scale }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            for (placement, tile) in tiles {
                tile.draw(in: CGRect(origin: placement.origin, size: CGSize(width: tileSide, height: tileSide)))
            }
            MapSnapshotter.drawPinMark(at: CGPoint(x: size.width / 2, y: size.height / 2), in: ctx.cgContext)
        }
    }

    private enum TileError: Error {
        case badURL, badResponse(Int), notAnImage
    }

    private static func loadTile(_ p: TopoTiles.TilePlacement) async throws -> UIImage {
        let server = ["a", "b", "c"][(p.x + p.y) % 3]
        let text = AppConfig.topoTileURLTemplate
            .replacingOccurrences(of: "{s}", with: server)
            .replacingOccurrences(of: "{z}", with: String(p.z))
            .replacingOccurrences(of: "{x}", with: String(p.x))
            .replacingOccurrences(of: "{y}", with: String(p.y))
        guard let url = URL(string: text) else { throw TileError.badURL }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        // The tile servers ask for an identifying user agent.
        request.setValue("Legulus iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TileError.badResponse(status) }
        guard let image = UIImage(data: data) else { throw TileError.notAnImage }
        return image
    }

    private static func cacheKey(coord: CLLocationCoordinate2D, size: CGSize) -> String {
        let raw = String(format: "topo|%.5f|%.5f|%d|%.0fx%.0f",
                         coord.latitude, coord.longitude, zoom, size.width, size.height)
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func diskURL(for key: String) -> URL? {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return caches.appendingPathComponent("topo/\(key).png")
    }
}
