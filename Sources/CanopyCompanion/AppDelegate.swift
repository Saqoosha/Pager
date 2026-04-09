import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, @unchecked Sendable {

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
            identifier: "ALLOW_ACTION",
            title: "Allow",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: "DENY_ACTION",
            title: "Deny",
            options: [.destructive]
        )
        let allowAlways = UNNotificationAction(
            identifier: "ALLOW_ALWAYS_ACTION",
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
            print("Notification permission granted: \(granted)")
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
    }
}

// MARK: - Notification Delegate (nonisolated for Swift 6)

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
        case "ALLOW_ACTION":
            decision = "allow"
        case "DENY_ACTION":
            decision = "deny"
        case "ALLOW_ALWAYS_ACTION":
            decision = "allowAlways"
        case UNNotificationDismissActionIdentifier:
            decision = "deny"
        default:
            completionHandler()
            return
        }

        Task {
            await NetworkService.shared.sendDecision(requestId: requestId, decision: decision)
            completionHandler()
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
