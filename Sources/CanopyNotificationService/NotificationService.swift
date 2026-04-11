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
        // `historyId` is stored alongside `requestId` so main-app lookups also
        // work for `/notify` pushes, which have no requestId.
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

        if let best = bestAttempt {
            var merged = best.userInfo
            merged["historyId"] = historyId
            best.userInfo = merged
            contentHandler(best)
        } else {
            NSLog("CanopyNotificationService: mutableCopy failed — delivering original content without historyId")
            contentHandler(request.content)
        }
        self.contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
            contentHandler = nil
        }
    }
}
