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
/// not cached as a topographic map, so the next view tries again. After
/// a failure the tile server is skipped for a few minutes
/// (`TopoFailureGate`), so a server that is down doesn't cost a
/// deadline on every sample.
enum TopoMapRenderer {
    /// Zoom level of the header: about one kilometre across.
    static let zoom = 15
    /// OpenTopoMap tiles are 256 px without a retina variant; drawn at
    /// 192 pt they stay readable, slightly soft on @3x screens.
    static let tileSide: CGFloat = 192

    private static let timeout: TimeInterval = 8
    /// Overall deadlines: a server that trickles bytes never trips the
    /// per-request idle timeout, the header must still give up.
    private static let topoDeadline: TimeInterval = 10
    private static let fallbackDeadline: TimeInterval = 8
    /// How long the tile server is left alone after a failure.
    private static let failureCooldown: TimeInterval = 300
    /// Upper bound of the rendered headers on disk.
    private static let diskLimitBytes = 50 * 1024 * 1024
    private static let jpegQuality: CGFloat = 0.85

    private static let memoryCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 100
        return c
    }()

    private static let gateLock = NSLock()
    private nonisolated(unsafe) static var gate = TopoFailureGate(cooldown: failureCooldown)

    /// The header image and whether it is the topographic map (the
    /// attribution belongs to it) or the Apple fallback; nil when both
    /// fail. `scale` is the screen's display scale.
    static func image(
        at coord: CLLocationCoordinate2D, size: CGSize, scale: CGFloat, dark: Bool
    ) async -> (image: UIImage, isTopo: Bool)? {
        let key = cacheKey(coord: coord, size: size)
        if let cached = memoryCache.object(forKey: key as NSString) {
            Log.network.debug("topo header: cache hit (memory)")
            return (cached, true)
        }
        if let url = diskURL(for: key), let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            Log.network.debug("topo header: cache hit (disk)")
            // Marks the file as used for the pruning.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            memoryCache.setObject(image, forKey: key as NSString)
            return (image, true)
        }
        if gateAllows() {
            let start = Date()
            if let image = await withDeadline(topoDeadline, { await renderTopo(coord: coord, size: size, scale: scale) }) {
                Log.network.info(
                    "topo header: cache miss, rendered in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms"
                )
                recordOutcome(success: true)
                memoryCache.setObject(image, forKey: key as NSString)
                store(image, key: key)
                return (image, true)
            }
            // Left the view or the coordinate changed: no fallback render,
            // and no reason to blame the server.
            if Task.isCancelled { return nil }
            recordOutcome(success: false)
        } else {
            Log.network.debug("topo header: server skipped after a recent failure")
        }
        if let fallback = await withDeadline(fallbackDeadline, {
            try? await MapSnapshotter.snapshot(at: coord, size: size, dark: dark)
        }) {
            return (fallback, false)
        }
        return nil
    }

    // MARK: - private

    private static func gateAllows() -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        return gate.allows(at: Date())
    }

    private static func recordOutcome(success: Bool) {
        gateLock.lock()
        defer { gateLock.unlock() }
        if success { gate.recordSuccess() } else { gate.recordFailure(at: Date()) }
    }

    /// `operation`'s result, or nil once `seconds` have passed.
    private static func withDeadline<T>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func renderTopo(coord: CLLocationCoordinate2D, size: CGSize, scale: CGFloat) async -> UIImage? {
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
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                // Only domain and code: a URLError's description carries the
                // tile URL, whose z/x/y locate the sample to about a km.
                let nsError = error as NSError
                Log.network.warning(
                    "topo tile failed, Apple map stands in: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)"
                )
            }
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
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

    /// The tile servers ask for an identifying user agent: app, version
    /// and where to find the app.
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Legulus/\(version) (iOS; +https://legulus.app)"
    }()

    private static func loadTile(_ p: TopoTiles.TilePlacement) async throws -> UIImage {
        let server = ["a", "b", "c"][(p.x + p.y) % 3]
        let text = AppConfig.topoTileURLTemplate
            .replacingOccurrences(of: "{s}", with: server)
            .replacingOccurrences(of: "{z}", with: String(p.z))
            .replacingOccurrences(of: "{x}", with: String(p.x))
            .replacingOccurrences(of: "{y}", with: String(p.y))
        guard let url = URL(string: text) else { throw TileError.badURL }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Log.network.warning("topo tile HTTP \(status, privacy: .public)")
            throw TileError.badResponse(status)
        }
        guard let image = UIImage(data: data) else { throw TileError.notAnImage }
        return image
    }

    /// Writes the header as JPEG (no transparency, a fraction of a PNG)
    /// and keeps the folder under `diskLimitBytes`.
    private static func store(_ image: UIImage, key: String) {
        guard let url = diskURL(for: key), let data = image.jpegData(compressionQuality: jpegQuality) else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url)
        prune(folder)
    }

    private static func prune(_ folder: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys
        ) else { return }
        let entries = files.compactMap { file -> TopoCacheEntry? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize, let used = values.contentModificationDate
            else { return nil }
            return TopoCacheEntry(name: file.lastPathComponent, size: size, used: used)
        }
        for name in TopoCacheEntry.toDelete(entries, limit: diskLimitBytes) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
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
        return caches.appendingPathComponent("topo/\(key).jpg")
    }
}
