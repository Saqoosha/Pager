import Intents
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
        // /notify pushes have no requestId, so synthesize a historyId for them
        // so the main app's tap-to-history lookup works for both push types.
        let historyId = (userInfo["requestId"] as? String) ?? UUID().uuidString

        let fullBody = (userInfo["toolInputFull"] as? String)
            ?? (userInfo["messageFull"] as? String)
            ?? request.content.body
        let rawSource = (userInfo["source"] as? String) ?? ""

        let item = NotificationHistoryItem(
            id: historyId,
            receivedAt: Date(),
            title: request.content.title,
            body: fullBody,
            category: request.content.categoryIdentifier.isEmpty ? nil : request.content.categoryIdentifier,
            project: userInfo["project"] as? String,
            toolName: userInfo["toolName"] as? String,
            requestId: userInfo["requestId"] as? String,
            source: rawSource.isEmpty ? nil : rawSource,
            decision: nil,
            decidedAt: nil
        )

        do {
            try HistoryStore.append(item)
        } catch {
            // Non-fatal: continue delivering the notification even if write fails.
            NSLog("PagerNotificationService: HistoryStore.append failed: \(error)")
        }

        guard let best = bestAttempt else {
            NSLog("PagerNotificationService: mutableCopy failed — delivering original content")
            contentHandler(request.content)
            self.contentHandler = nil
            return
        }

        var merged = best.userInfo
        merged["historyId"] = historyId
        best.userInfo = merged

        if rawSource.isEmpty {
            contentHandler(best)
        } else if let source = NotificationSource(rawValue: rawSource) {
            // applyCommunicationStyle returns nil if the entitlement is missing
            // or the system rejects the intent; fall back to an attachment so
            // the source is still visually identifiable.
            if let updated = applyCommunicationStyle(to: best, source: source) {
                contentHandler(updated)
            } else {
                applyAttachmentFallback(to: best, source: source)
                contentHandler(best)
            }
        } else {
            // Worker-allowlisted source values that the extension doesn't yet
            // know — log so producer/consumer drift is observable instead of
            // silently impersonating Claude.
            NSLog("PagerNotificationService: unknown source \"\(rawSource)\" — delivering plain notification")
            contentHandler(best)
        }
        self.contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
            contentHandler = nil
        }
    }

    // MARK: - Communication notification

    private func applyCommunicationStyle(
        to content: UNMutableNotificationContent,
        source: NotificationSource
    ) -> UNNotificationContent? {
        guard let imageData = avatarImageData(for: source) else {
            NSLog("PagerNotificationService: avatar asset unreadable: \(source.assetName)")
            return nil
        }

        let image = INImage(imageData: imageData)
        let handle = INPersonHandle(value: "\(source.assetName)@pager", type: .unknown)
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: source.displayName,
            image: image,
            contactIdentifier: nil,
            customIdentifier: source.assetName
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .unknown,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: source.assetName,
            serviceName: "Pager",
            sender: sender,
            attachments: nil
        )
        intent.setImage(image, forParameterNamed: \.sender)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        // Best-effort donation for Siri/Communication Limit context. The
        // extension may be torn down before the async callback fires; the
        // visible avatar comes from updating(from:) below, not from this.
        interaction.donate { error in
            if let error {
                NSLog("PagerNotificationService: INInteraction.donate failed: \(error)")
            }
        }

        do {
            return try content.updating(from: intent)
        } catch {
            NSLog("PagerNotificationService: updating(from:) failed: \(error)")
            return nil
        }
    }

    private func applyAttachmentFallback(
        to content: UNMutableNotificationContent,
        source: NotificationSource
    ) {
        guard let bundleURL = avatarBundleURL(for: source) else {
            NSLog("PagerNotificationService: attachment fallback asset missing: \(source.assetName)")
            return
        }
        // UNNotificationAttachment moves the file out of our sandbox, so the
        // source URL has to be writable — copy the read-only bundled PNG into
        // the extension's tmp dir first. Unique filename per delivery avoids
        // collisions if multiple notifications are inflight at once.
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(source.assetName)-\(UUID().uuidString).png")
        do {
            try FileManager.default.copyItem(at: bundleURL, to: tmpURL)
        } catch {
            NSLog("PagerNotificationService: attachment copy failed: \(error)")
            return
        }
        do {
            let attachment = try UNNotificationAttachment(identifier: source.assetName, url: tmpURL, options: nil)
            content.attachments = [attachment]
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            NSLog("PagerNotificationService: attachment init failed: \(error)")
        }
    }

    private func avatarBundleURL(for source: NotificationSource) -> URL? {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: source.assetName, withExtension: "png", subdirectory: "Avatars")
            ?? bundle.url(forResource: source.assetName, withExtension: "png")
    }

    private func avatarImageData(for source: NotificationSource) -> Data? {
        guard let url = avatarBundleURL(for: source) else {
            NSLog("PagerNotificationService: avatar URL missing: \(source.assetName)")
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            NSLog("PagerNotificationService: avatar read failed for \(source.assetName) at \(url): \(error)")
            return nil
        }
    }
}

// Mirrored in worker/src/index.ts (VALID_SOURCES) and hooks/notify-stop.sh
// (--source argument). Add a new case here when widening the worker allowlist.
private enum NotificationSource: CaseIterable {
    case claude
    case codex
    case cursor

    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "claude", "claude-code", "claudecode": self = .claude
        case "codex": self = .codex
        case "cursor": self = .cursor
        default: return nil
        }
    }

    var assetName: String {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        case .cursor: return "cursor"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }
}
