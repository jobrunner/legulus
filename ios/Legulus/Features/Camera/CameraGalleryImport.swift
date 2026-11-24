import Foundation

/// Takes photos picked from the library into the camera's series: load,
/// convert to JPEG with the metadata kept, store, in the order of the
/// selection. One photo that fails (only in iCloud and offline, cannot
/// be converted, disk full) does not stop the others.
///
/// The photo keeps its own EXIF; no current position is added — it was
/// taken somewhere else.
enum CameraGalleryImport {
    struct Result: Equatable {
        var stored: Int
        /// The last stored file, for the preview.
        var last: Data?
        var failed: Int
    }

    /// Cancellation skips the rest without counting it as failed.
    static func run(
        _ items: [() async throws -> Data?],
        prepare: (Data) async -> Data?,
        store: (Data) throws -> Void
    ) async -> Result {
        var result = Result(stored: 0, last: nil, failed: 0)
        for load in items {
            if Task.isCancelled { break }
            do {
                guard let original = try await load(), let jpeg = await prepare(original) else {
                    result.failed += 1
                    continue
                }
                try store(jpeg)
                result.stored += 1
                result.last = jpeg
            } catch {
                Log.ui.error("gallery photo not taken over: \(error.localizedDescription, privacy: .public)")
                result.failed += 1
            }
        }
        return result
    }
}
