# Notification History (Design)

Date: 2026-04-11
Status: Approved for planning

## Problem

Pager notifications frequently contain long text (tool inputs, hook messages) that get truncated in the iOS notification alert. Users cannot read the full content:

1. The permission-request push body is truncated to 200 characters by the Worker.
2. The `/notify` endpoint can send long messages, but only what fits in the alert banner is visible.
3. Tapping a notification currently does nothing — `NotificationDelegate` falls through the `default` case in `AppDelegate.swift`.

Users want to open the app and read the full content of past notifications, including ones they did not interact with.

## Goals

- Capture every incoming push with its full content, regardless of whether the user taps it.
- Provide an in-app history list showing past notifications.
- Show full (non-truncated) content in a detail view with copyable text.
- Tapping a notification opens the app directly to that notification's detail.
- Record the user's decision (allow/deny/allowAlways) alongside the history entry.

## Non-Goals

- No server-side history storage or sync.
- No search, filter, or re-send from history.
- No offline queue for re-sending decisions from history — worker KV expires anyway.
- No rich notifications (images, custom UI).

## Architecture

```
[Claude Code Hook] → [Worker /request or /notify] → APNs → [iOS device]
                                                              │
                                                              ├─→ [Notification Service Extension (NSE)]
                                                              │     - intercept push before display
                                                              │     - write JSON to App Group container
                                                              │     - inject historyId into userInfo
                                                              │     - hand notification to OS
                                                              │
                                                              └─→ [OS displays on lock screen]
                                                                    │
                                                                    └─ tap →[Main App]
                                                                              - read history from App Group
                                                                              - navigate to HistoryDetailView
```

**Components:**

- **PagerNotificationService** — new NSE target. Runs before every push is shown, captures the full payload into shared storage.
- **App Group** `group.sh.saqoo.Pager` — shared container between the extension and the main app.
- **Shared/HistoryStore** — compiled into both targets. Handles JSON read/write in the App Group container.
- **Main app additions** — `HistoryListView`, `HistoryDetailView`, `AppState` for deep-link navigation, tap handling in `NotificationDelegate`.

## Storage

- **Location:** App Group container, subdirectory `history/`.
- **Layout:** one JSON file per history entry. Filename: `<receivedAtMillis>-<uuid>.json`.
- **Rationale:** file-per-entry eliminates write conflicts between the extension and the main app. The NSE only creates new files; the main app reads, deletes, or rewrites individual files.
- **Retention:** at most 100 entries. On write, the NSE prunes the oldest files beyond the limit.
- **Concurrency:** no locking required. Filenames are unique (timestamp + UUID). The main app is the only writer that mutates an existing file (decision updates); no cross-process overlap.

## Data Model

```swift
struct NotificationHistoryItem: Codable, Identifiable, Hashable {
    let id: String              // requestId if present, otherwise UUID
    let receivedAt: Date
    let title: String           // from aps.alert.title
    let body: String            // full text: toolInputFull for /request, aps.alert.body for /notify
    let category: String?       // "PERMISSION_REQUEST" or nil
    let project: String?        // /request only
    let toolName: String?       // /request only
    let requestId: String?      // /request only
    var decision: String?       // "allow" | "deny" | "allowAlways", set by main app after user acts
    var decidedAt: Date?
}
```

## Worker Changes

### `/request`

Add three top-level custom keys to the APNs payload so the NSE can capture full content. Keep the truncated preview as the alert body (lock-screen appearance unchanged).

```ts
const MAX_FULL_INPUT = 3000;
const toolInputFull = (body.toolInput || "").length > MAX_FULL_INPUT
  ? body.toolInput.slice(0, MAX_FULL_INPUT) + "…"
  : (body.toolInput || "");

const apnsPayload = {
  aps: {
    alert: { title: `[${body.project || "?"}] ${body.toolName}`, body: inputPreview },
    sound: "default",
    category: "PERMISSION_REQUEST",
    "interruption-level": "time-sensitive",
    "mutable-content": 1,
  },
  requestId: body.requestId,
  toolName: body.toolName,
  toolInputFull,
  project: body.project || "",
};
```

APNs payloads have a 4KB limit; capping at 3KB leaves headroom for the other fields.

### `/notify`

Add `"mutable-content": 1` so the NSE is invoked. The current `body.message` is already the full text; no other changes needed.

### `/test`

Add `"mutable-content": 1` so NSE behaviour is verifiable via the existing test button in the app.

### Backward compatibility

Existing app builds (no NSE) silently ignore the new keys and `mutable-content`. Roll out Worker changes first so that by the time the NSE ships, payloads already carry full content.

## iOS Project Changes

### Directory layout

```
Sources/
├── Pager/             # existing main app
├── PagerNotificationService/   # new NSE target
│   ├── NotificationService.swift
│   └── NotificationService.entitlements
└── Shared/                      # new, compiled into both targets
    ├── NotificationHistoryItem.swift
    └── HistoryStore.swift
```

Both targets include `Sources/Shared` in their `sources` list in `project.yml`.

### `project.yml` — new target

```yaml
  PagerNotificationService:
    type: app-extension
    platform: iOS
    sources:
      - Sources/PagerNotificationService
      - Sources/Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: sh.saqoo.Pager.NotificationService
        SWIFT_STRICT_CONCURRENCY: complete
        GENERATE_INFOPLIST_FILE: true
    entitlements:
      path: Sources/PagerNotificationService/NotificationService.entitlements
      properties:
        com.apple.security.application-groups:
          - group.sh.saqoo.Pager
```

Main app target: add `Sources/Shared` to `sources`, add the App Group entitlement to `Pager.entitlements`, and declare that the extension is embedded in the app.

### Provisioning

1. Create App Group `group.sh.saqoo.Pager` in Apple Developer Portal.
2. Assign the group to both bundle IDs (`sh.saqoo.Pager` and `sh.saqoo.Pager.NotificationService`).
3. Regenerate provisioning profiles. `xcodebuild -allowProvisioningUpdates` should handle this automatically; fall back to manual if needed.

## `HistoryStore` API

```swift
enum HistoryStore {
    static let appGroupID = "group.sh.saqoo.Pager"
    static let maxItems = 100

    static func containerURL() -> URL?
    static func historyDirectory() throws -> URL   // creates if missing

    // Called by NSE (nonisolated)
    static func append(_ item: NotificationHistoryItem) throws

    // Called by main app
    static func loadAll() throws -> [NotificationHistoryItem]  // sorted by receivedAt desc
    static func delete(id: String) throws
    static func deleteAll() throws
    static func updateDecision(requestId: String, decision: String, decidedAt: Date) throws

    // Internal
    private static func pruneOldFiles() throws
}
```

`append` writes the JSON, then calls `pruneOldFiles` to trim over-quota entries.

## NSE Implementation

```swift
final class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        let userInfo = request.content.userInfo
        let historyId = (userInfo["requestId"] as? String) ?? UUID().uuidString

        let item = NotificationHistoryItem(
            id: historyId,
            receivedAt: Date(),
            title: request.content.title,
            body: (userInfo["toolInputFull"] as? String) ?? request.content.body,
            category: request.content.categoryIdentifier.isEmpty ? nil : request.content.categoryIdentifier,
            project: userInfo["project"] as? String,
            toolName: userInfo["toolName"] as? String,
            requestId: userInfo["requestId"] as? String,
            decision: nil,
            decidedAt: nil
        )

        try? HistoryStore.append(item)

        // Inject historyId so the main app can look up the entry on tap
        if let best = bestAttempt {
            var newUserInfo = best.userInfo
            newUserInfo["historyId"] = historyId
            best.userInfo = newUserInfo
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
```

## Main App Changes

### `AppState`

```swift
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var pendingDetailId: String?
}
```

### `NotificationDelegate.didReceive` — tap handling

Add a case for `UNNotificationDefaultActionIdentifier`:

```swift
case UNNotificationDefaultActionIdentifier:
    let targetId = (userInfo["historyId"] as? String)
        ?? (userInfo["requestId"] as? String)
    Task { @MainActor in
        AppState.shared.pendingDetailId = targetId
    }
    completionHandler()
    return
```

For Allow / Deny / AllowAlways actions, after `sendDecision` is dispatched, also call `HistoryStore.updateDecision(requestId:decision:decidedAt:)` from a `Task` so the history reflects the user's choice.

### `ContentView` — navigation path

Switch `NavigationStack` to path-based form:

```swift
@State private var navPath = NavigationPath()
...
NavigationStack(path: $navPath) {
    Form { /* existing */ 
        Section("History") {
            NavigationLink("View Notification History", value: HistoryRoute.list)
        }
    }
    .navigationDestination(for: HistoryRoute.self) { route in
        switch route {
        case .list: HistoryListView(path: $navPath)
        case .detail(let id): HistoryDetailView(id: id)
        }
    }
}
.onReceive(AppState.shared.$pendingDetailId.compactMap { $0 }) { id in
    navPath = NavigationPath()
    navPath.append(HistoryRoute.list)
    navPath.append(HistoryRoute.detail(id))
    AppState.shared.pendingDetailId = nil
}
```

```swift
enum HistoryRoute: Hashable {
    case list
    case detail(String)
}
```

### `HistoryListView`

- `List` of `HistoryRow` items, sorted by `receivedAt` desc.
- Swipe-to-delete per row.
- `Clear All` toolbar button.
- `refreshable` and `onAppear` both call `HistoryStore.loadAll()`.
- Row tap pushes `HistoryRoute.detail(item.id)`.

`HistoryRow` shows: title (bold), body preview (~80 chars), relative time, decision badge when present.

### `HistoryDetailView`

- Loads the item by id from `HistoryStore` (handles "not found" gracefully — entry may have been pruned).
- Header: title, absolute timestamp, decision label with colored icon.
- Body: `Text(item.body)` in monospaced font, `textSelection(.enabled)`.
- Toolbar: copy-to-clipboard button.

## Tap-to-Open Flow (bug fix)

Current behaviour: tapping a notification enters `NotificationDelegate.didReceive` with `UNNotificationDefaultActionIdentifier`, which is not handled and falls through to `default`, doing nothing.

New behaviour:
1. NSE injects `historyId` into the userInfo when the notification arrives.
2. On tap, `didReceive` reads `historyId` and sets `AppState.shared.pendingDetailId`.
3. `ContentView` observes the state and pushes `HistoryRoute.list` + `HistoryRoute.detail(id)` onto the navigation path.
4. The user lands directly on the detail view with the full body.

## Testing

### Worker
- Unit-level: verify `/request` payload includes `toolInputFull`, `toolName`, `project`, and that `toolInput` > 3000 chars is truncated with `"…"`.
- Verify `/notify` and `/test` include `"mutable-content": 1`.
- Verify `/response` and `/status` are unchanged.

### iOS (manual on device "S")
1. Deploy Worker.
2. Build and install main app + NSE.
3. Tap **Send Test Notification** → a history entry appears.
4. Send a real `/request` with a long `toolInput` → history entry contains the full text.
5. Tap the lock-screen notification → app opens to `HistoryDetailView`.
6. Tap Allow → history entry's `decision` updates to `allow`.
7. Send a `/notify` message → entry appears with the full `body`.
8. Kill and relaunch the app → history persists.
9. Generate >100 notifications → oldest are pruned.
10. Swipe-delete and Clear All both work.

## Rollout

1. Deploy Worker changes first (backward-compatible).
2. Ship iOS update with the NSE target and history UI.
3. Verify on device "S" end-to-end.

## Open decisions (resolved)

- **AllowAlways in history?** Yes, recorded like any other decision.
- **Pruning vs. pending decisions?** Accept the edge case; 100-entry ceiling is not realistic to hit before a decision.
- **Dismiss handling?** Dismissal stays as `deny` (current behaviour). Recorded in history as `deny`.
- **Re-decide from detail view?** No — worker KV expires quickly, and history is read-only.
- **Timestamp format?** Relative in the list row, absolute in the detail header.

## Future work (out of scope)

- Server-side history mirror.
- Search and filter.
- Per-project filtering.
- Re-send decision from the app.
