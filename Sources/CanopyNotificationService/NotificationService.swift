import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        let userInfo = request.content.userInfo
        let historyId = (userInfo["requestId"] as? String) ?? UUID().uuidString

        let fullBody = (userInfo["toolInputFull"] as? String) ?? request.content.body

        let item = NotificationHistoryItem(
            id: historyId,
            receivedAt: Date(),
            title: request.content.title,
            body: fullBody,
            category: request.content.categoryIdentifier.isEmpty ? nil : request.content.categoryIdentifier,
            project: userInfo["project"] as? String,
            toolName: userInfo["toolName"] as? String,
            requestId: userInfo["requestId"] as? String,
            decision: nil,
            decidedAt: nil
        )

        do {
            try HistoryStore.append(item)
        } catch {
            // Non-fatal: continue delivering the notification even if write fails.
            NSLog("CanopyNotificationService: HistoryStore.append failed: \(error)")
        }

        // Inject historyId so main app can look up this entry when the user taps.
        if let best = bestAttempt {
            var merged = best.userInfo
            merged["historyId"] = historyId
            best.userInfo = merged
            contentHandler(best)
        } else {
            contentHandler(request.content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}
