import SwiftUI

// MARK: - AppDelegate for background URLSession (ADR D4)

/// background URLSession completion handler를 수신한다.
/// SwiftUI App lifecycle과 함께 쓰기 위해 @UIApplicationDelegateAdaptor로 연결.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// OS가 background URLSession 이벤트를 앱에 전달할 때 저장해두고 URLSession에 전달한다.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == ChunkUploadQueue.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        // ChunkUploadQueue는 앱 생애 동안 유일하게 존재해야 한다.
        // RootView → AdminWorkspaceStore → ScanStore → ChunkUploadQueue로 접근하는 경로를
        // 두는 것이 이상적이지만, cycle 1에서는 NotificationCenter를 통해 전달한다.
        NotificationCenter.default.post(
            name: .chunkUploadBackgroundSessionEvent,
            object: completionHandler
        )
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let chunkUploadBackgroundSessionEvent = Notification.Name(
        "ac.koreatech.indoorpathfinding.chunkUploadBackgroundSession"
    )
}

// MARK: - App entry point

@main
struct IndoorPathfindingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
