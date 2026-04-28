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
        // Re-save the shared secret so it picks up kSecAttrAccessibleAfterFirstUnlock.
        // Items first stored without that attribute are inaccessible while the
        // device is locked, which silently 401s the watch-decision POST.
        if let secret = KeychainHelper.load(key: "sharedSecret"), !secret.isEmpty {
            KeychainHelper.save(key: "sharedSecret", value: secret)
        }
        registerNotificationCategory()
        requestNotificationPermission()
        application.registerForRemoteNotifications()
        return true
    }

    // MARK: - Notification Category

    private func registerNotificationCategory() {
        // No .authenticationRequired — that option queues actions until the
        // iPhone is unlocked, which means an Apple Watch tap on a locked
        // iPhone never reaches the delegate.
        let allow = UNNotificationAction(
            identifier: NotificationAction.allow,
            title: "Allow",
            options: []
        )
        let deny = UNNotificationAction(
            identifier: NotificationAction.deny,
            title: "Deny",
            options: [.destructive]
        )
        let allowAlways = UNNotificationAction(
            identifier: NotificationAction.allowAlways,
            title: "Always Allow",
            options: []
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
        let requestId = userInfo["requestId"] as? String
        let historyId = (userInfo["historyId"] as? String) ?? requestId

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if let id = historyId {
                Task { @MainActor in
                    AppState.shared.pendingDetailId = id
                }
            }
            completionHandler()
            return
        }

        guard let requestId else {
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
            decision = "deny"
        default:
            completionHandler()
            return
        }

        // Apple expects a prompt completionHandler call. Hold a background
        // task assertion so iOS keeps us alive long enough to POST the
        // decision after we've signalled "done" to the notification system.
        let app = UIApplication.shared
        let bgState = BackgroundDecisionState()
        Task { @MainActor in
            bgState.bgTaskId = app.beginBackgroundTask(withName: "PagerSendDecision") {
                NSLog("Pager: PagerSendDecision bgTask expired")
                bgState.endIfActive(app: app)
            }
        }
        completionHandler()

        let decidedAt = Date()
        Task {
            await NetworkService.shared.sendDecision(requestId: requestId, decision: decision)
            do {
                try HistoryStore.updateDecision(
                    requestId: requestId,
                    decision: decision,
                    decidedAt: decidedAt
                )
            } catch {
                NSLog("Pager: HistoryStore.updateDecision failed: %@", "\(error)")
            }
            await MainActor.run { bgState.endIfActive(app: app) }
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

// MARK: - Background Task State

/// Holds the bgTaskId so the expiration handler and the work Task share the
/// same identifier safely. Using a reference type avoids capturing a `var`
/// across `@Sendable` boundaries.
@MainActor
private final class BackgroundDecisionState {
    var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    func endIfActive(app: UIApplication) {
        guard bgTaskId != .invalid else { return }
        app.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }
}
