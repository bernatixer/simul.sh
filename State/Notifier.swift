import Foundation
import UserNotifications

/// macOS notifications for sessions that need you, unless you're already
/// looking at them (AppModel.flagAttention decides). At most one per session (identified by its id), removed once
/// you look at the session; clicking one opens it.
@MainActor
final class Notifier: NSObject {
    /// A notification was clicked.
    var onOpen: ((Session.ID) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    private var isEnabled: Bool { Preferences.flag(Preferences.Key.notifications) }

    /// Call once at launch: becomes the delegate and asks for permission
    /// (macOS only asks the user the first time).
    func setUp() {
        center.delegate = self
        if isEnabled { Self.requestPermission() }
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                Log.app.error("notification permission: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func post(for session: Session, message: String) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = session.title
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Log.app.error("notification: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func remove(_ ids: Set<Session.ID>) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids.map(\.uuidString))
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// macOS hides notifications from the frontmost app unless asked; show
    /// them, since they're for a session you aren't looking at.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = UUID(uuidString: response.notification.request.identifier) else { return }
        await MainActor.run { onOpen?(id) }
    }
}
