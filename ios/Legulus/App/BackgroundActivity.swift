import UIKit

/// Time to finish after the app left the foreground: the system keeps
/// the app running (typically about 30 s) until the returned closure is
/// called or the time is up. Used for the photo upload, which otherwise
/// breaks off when the phone is put away right after the photos.
enum BackgroundActivity {
    @MainActor
    static func begin(_ name: String) -> () -> Void {
        let request = Request()
        request.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Time is up: the upload in flight is cut off and retried
            // on the next pass.
            Log.sync.notice("background time for \(name, privacy: .public) expired")
            request.end()
        }
        return { request.end() }
    }

    /// Ends the request exactly once, whether the work finished or the
    /// time ran out first.
    @MainActor
    private final class Request {
        var id: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
