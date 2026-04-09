import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerNotificationCategory()
        requestNotificationPermission()
        application.registerForRemoteNotifications()
        return true
    }

    // MARK: - Notification Category

    private func registerNotificationCategory() {
        let allow = UNNotificationAction(
            identifier: NotificationAction.allow,
            title: "Allow",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: NotificationAction.deny,
            title: "Deny",
            options: [.destructive]
        )
        let allowAlways = UNNotificationAction(
            identifier: NotificationAction.allowAlways,
            title: "Always Allow",
            options: [.authenticationRequired]
        )

        let category = UNNotificationCategory(
            identifier: "PERMISSION_REQUEST",
            actions: [allow, deny, allowAlways],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error {
                print("Notification auth error: \(error)")
            }
            if !granted {
                print("Notification permission denied")
                Task { @MainActor in
                    NetworkService.shared.lastError = "Notification permission denied — enable in Settings"
                }
            }
        }
    }

    // MARK: - APNs Token

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("APNs device token: \(token)")
        UserDefaults.standard.set(token, forKey: "deviceToken")
        NotificationCenter.default.post(name: .deviceTokenReceived, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error)")
        Task { @MainActor in
            NetworkService.shared.lastError = "APNs registration failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Notification Action Identifiers

enum NotificationAction {
    static let allow = "ALLOW_ACTION"
    static let deny = "DENY_ACTION"
    static let allowAlways = "ALLOW_ALWAYS_ACTION"
}

// MARK: - Notification Delegate (separate class for Swift 6 strict concurrency)

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let requestId = userInfo["requestId"] as? String else {
            completionHandler()
            return
        }

        let decision: String
        switch response.actionIdentifier {
        case NotificationAction.allow:
            decision = "allow"
        case NotificationAction.deny:
            decision = "deny"
        case NotificationAction.allowAlways:
            decision = "allowAlways"
        case UNNotificationDismissActionIdentifier:
            // Dismissing notification is treated as deny
            decision = "deny"
        default:
            completionHandler()
            return
        }

        // Call completionHandler immediately — Apple requires prompt return.
        // sendDecision runs fire-and-forget with retry.
        completionHandler()
        Task {
            await NetworkService.shared.sendDecision(requestId: requestId, decision: decision)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

extension Notification.Name {
    static let deviceTokenReceived = Notification.Name("deviceTokenReceived")
}
