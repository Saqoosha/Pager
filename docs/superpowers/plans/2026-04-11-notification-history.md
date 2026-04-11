# Notification History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app notification history view so users can read the full text of notifications that were truncated in the alert, using a Notification Service Extension to capture every push regardless of user interaction.

**Architecture:** A new iOS app extension (`CanopyNotificationService`) intercepts pushes via `UNNotificationServiceExtension.didReceive`, writes a JSON history entry to a shared App Group container, and injects a `historyId` into the notification's userInfo. The main app reads entries from the container, displays them in `HistoryListView` / `HistoryDetailView`, and on tap navigates straight to the relevant detail. The Worker gains two new payload fields (`toolInputFull`, `toolName`, `project`) so the extension can capture full content, and `/notify` + `/test` get `mutable-content: 1` so the extension is invoked.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, `UNNotificationServiceExtension`, App Groups, XcodeGen (`project.yml`), TypeScript Cloudflare Worker, `wrangler`.

**Spec:** `docs/superpowers/specs/2026-04-11-notification-history-design.md`

**Restricted Actions:**
- **Do NOT** run `git commit`, `git push`, `wrangler deploy`, or install to the device in the final "rollout" step without explicit approval. The user's global rules forbid it. The plan includes commit commands for reference, but each task ends with staging changes and pausing for approval on whether to commit.

---

## Task 0: Prepare working branch and confirm spec

**Files:** none modified

- [ ] **Step 1: Confirm you are on `main` with a clean tree**

Run: `git status`
Expected: `On branch main`, working tree clean (the spec file from brainstorming may already be staged — that's fine).

- [ ] **Step 2: Read the spec end-to-end**

Open `docs/superpowers/specs/2026-04-11-notification-history-design.md` and read it. Every task below assumes you know the model, storage layout, and rollout order described there.

- [ ] **Step 3: Verify current build still works**

Run:
```bash
xcodegen generate
xcodebuild -project CanopyCompanion.xcodeproj -scheme CanopyCompanion \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build
```
Expected: build succeeds. This is your baseline — if anything breaks during implementation, compare against this state.

---

## Task 1: Worker — add full payload fields to `/request`

**Files:**
- Modify: `worker/src/index.ts:152-202` (the `/request` handler)

- [ ] **Step 1: Add the truncation constant and update the payload**

Edit `worker/src/index.ts`. Find the `/request` handler (starts at `if (path === "/request" && request.method === "POST")`). Replace the existing `inputPreview` / `apnsPayload` block with:

```ts
        const inputPreview = (body.toolInput || "").length > 200 ? body.toolInput.slice(0, 200) + "…" : (body.toolInput || "");

        // Full tool input for Notification Service Extension history capture.
        // APNs payload limit is 4KB; cap to leave headroom for the rest of the payload.
        const MAX_FULL_INPUT = 3000;
        const toolInputFull = (body.toolInput || "").length > MAX_FULL_INPUT
          ? body.toolInput.slice(0, MAX_FULL_INPUT) + "…"
          : (body.toolInput || "");

        const apnsPayload = {
          aps: {
            alert: {
              title: `[${body.project || "?"}] ${body.toolName}`,
              body: inputPreview,
            },
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

- [ ] **Step 2: Typecheck**

Run: `cd worker && bunx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Start a dry-run dev server and hit `/request`**

Run in one terminal: `cd worker && bun run dev`
(wrangler will print a local URL, usually `http://localhost:8787`)

In another terminal, source the secret and hit it with a long payload to verify the new shape:
```bash
curl -s -X POST http://localhost:8787/request \
  -H "Authorization: Bearer $CANOPY_COMPANION_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"requestId":"test-1","toolName":"Bash","project":"demo","toolInput":"'"$(python3 -c 'print("X"*500)')"'"}'
```
Expected: `{"error":"apns_failed",...}` or `{"error":"no device registered"}` — either is fine. The point is that the handler doesn't 400 and the TypeScript compiled. If it returns `{"ok":true,...}` even better (means a device is registered).

Stop the dev server (Ctrl+C).

- [ ] **Step 4: Stage changes**

```bash
git add worker/src/index.ts
git status
```
Expected: only `worker/src/index.ts` staged. Do NOT commit yet — pause for user approval.

---

## Task 2: Worker — add `mutable-content: 1` to `/notify` and `/test`

**Files:**
- Modify: `worker/src/index.ts:260-287` (`/notify` handler)
- Modify: `worker/src/index.ts:289-316` (`/test` handler)

- [ ] **Step 1: Update `/notify` payload**

In `worker/src/index.ts`, inside the `/notify` handler, replace the existing `payload` block with:

```ts
        const payload = {
          aps: {
            alert: {
              title: body.title || "Canopy Companion",
              body: body.message || "",
            },
            sound: "default",
            "interruption-level": "time-sensitive",
            "mutable-content": 1,
          },
        };
```

- [ ] **Step 2: Update `/test` payload**

Replace the existing `testPayload` block with:

```ts
        const testPayload = {
          aps: {
            alert: {
              title: "Canopy Companion",
              body: "テスト通知。ボタンが表示されるか確認。",
            },
            sound: "default",
            category: "PERMISSION_REQUEST",
            "interruption-level": "time-sensitive",
            "mutable-content": 1,
          },
          requestId: crypto.randomUUID(),
        };
```

- [ ] **Step 3: Typecheck**

Run: `cd worker && bunx tsc --noEmit`
Expected: no errors.

- [ ] **Step 4: Stage changes**

```bash
git add worker/src/index.ts
git status
```
Expected: only `worker/src/index.ts` staged. Pause for user approval before committing.

---

## Task 3: Add App Group to main app entitlements

**Files:**
- Modify: `Sources/CanopyCompanion/CanopyCompanion.entitlements`

- [ ] **Step 1: Add the App Group key**

Replace the entire contents of `Sources/CanopyCompanion/CanopyCompanion.entitlements` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.sh.saqoo.CanopyCompanion</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Create the App Group in Apple Developer Portal (one-time, manual)**

Open https://developer.apple.com/account/resources/identifiers/list/applicationGroup and create `group.sh.saqoo.CanopyCompanion` if it doesn't already exist. Assign it to the `sh.saqoo.CanopyCompanion` App ID (and to `sh.saqoo.CanopyCompanion.NotificationService` when it exists — Task 5).

If you cannot access the portal right now, `-allowProvisioningUpdates` in `xcodebuild` usually creates the group on first build. If that fails later, come back here.

- [ ] **Step 3: Stage changes**

```bash
git add Sources/CanopyCompanion/CanopyCompanion.entitlements
git status
```
Pause for approval.

---

## Task 4: Shared data model — `NotificationHistoryItem`

**Files:**
- Create: `Sources/Shared/NotificationHistoryItem.swift`

- [ ] **Step 1: Create the `Shared` directory**

Run: `mkdir -p Sources/Shared`
Expected: directory exists.

- [ ] **Step 2: Write the model**

Create `Sources/Shared/NotificationHistoryItem.swift` with:

```swift
import Foundation

/// A single captured notification, shared between the main app and the
/// Notification Service Extension via the App Group container.
struct NotificationHistoryItem: Codable, Identifiable, Hashable, Sendable {
    /// Stable identifier. Equals `requestId` for permission requests,
    /// otherwise a UUID generated by the extension.
    let id: String
    let receivedAt: Date
    let title: String
    /// Full body. For `/request`, taken from the custom `toolInputFull`
    /// key. For `/notify`, taken from `aps.alert.body`.
    let body: String
    let category: String?
    let project: String?
    let toolName: String?
    let requestId: String?
    var decision: String?
    var decidedAt: Date?

    init(
        id: String,
        receivedAt: Date,
        title: String,
        body: String,
        category: String? = nil,
        project: String? = nil,
        toolName: String? = nil,
        requestId: String? = nil,
        decision: String? = nil,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.title = title
        self.body = body
        self.category = category
        self.project = project
        self.toolName = toolName
        self.requestId = requestId
        self.decision = decision
        self.decidedAt = decidedAt
    }
}
```

- [ ] **Step 3: Stage changes**

```bash
git add Sources/Shared/NotificationHistoryItem.swift
git status
```
Pause for approval.

---

## Task 5: Shared storage — `HistoryStore`

**Files:**
- Create: `Sources/Shared/HistoryStore.swift`

- [ ] **Step 1: Write the store**

Create `Sources/Shared/HistoryStore.swift`:

```swift
import Foundation

/// Read/write API for notification history, backed by per-entry JSON files
/// inside the App Group container. Safe to call from both the main app and
/// the Notification Service Extension because each entry lives in its own
/// file (unique name = no write conflicts).
enum HistoryStore {
    static let appGroupID = "group.sh.saqoo.CanopyCompanion"
    static let maxItems = 100

    enum StoreError: Error {
        case containerUnavailable
    }

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func historyDirectory() throws -> URL {
        guard let container = containerURL() else {
            throw StoreError.containerUnavailable
        }
        let dir = container.appendingPathComponent("history", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func filename(for item: NotificationHistoryItem) -> String {
        let millis = Int64(item.receivedAt.timeIntervalSince1970 * 1000)
        return "\(millis)-\(item.id).json"
    }

    /// Called by the Notification Service Extension when a push arrives.
    static func append(_ item: NotificationHistoryItem) throws {
        let dir = try historyDirectory()
        let url = dir.appendingPathComponent(filename(for: item))
        let data = try encoder().encode(item)
        try data.write(to: url, options: .atomic)
        try pruneOldFiles(in: dir)
    }

    /// Loads all history entries, newest first.
    static func loadAll() throws -> [NotificationHistoryItem] {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        let dec = decoder()
        var items: [NotificationHistoryItem] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                items.append(try dec.decode(NotificationHistoryItem.self, from: data))
            } catch {
                // Corrupt file — skip. Could log, but this runs on every list load.
                continue
            }
        }
        items.sort { $0.receivedAt > $1.receivedAt }
        return items
    }

    static func item(withId id: String) throws -> NotificationHistoryItem? {
        try loadAll().first(where: { $0.id == id })
    }

    static func delete(id: String) throws {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for file in files where file.lastPathComponent.contains("-\(id).json") {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func deleteAll() throws {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Updates `decision` / `decidedAt` for the entry with a matching requestId.
    /// Called from the main app after the user acts on Allow/Deny/AllowAlways.
    /// No-op if the entry has already been pruned.
    static func updateDecision(requestId: String, decision: String, decidedAt: Date) throws {
        guard var item = try item(withId: requestId) else { return }
        item.decision = decision
        item.decidedAt = decidedAt
        // Overwrite the existing file by re-appending under the same filename.
        let dir = try historyDirectory()
        let url = dir.appendingPathComponent(filename(for: item))
        let data = try encoder().encode(item)
        try data.write(to: url, options: .atomic)
    }

    private static func pruneOldFiles(in dir: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        guard files.count > maxItems else { return }
        // Sort ascending by filename (filenames begin with receivedAt millis, so
        // lexicographic order matches chronological order).
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excess = sorted.count - maxItems
        for i in 0..<excess {
            try? FileManager.default.removeItem(at: sorted[i])
        }
    }
}
```

- [ ] **Step 2: Stage changes**

```bash
git add Sources/Shared/HistoryStore.swift
git status
```
Pause for approval.

---

## Task 6: Create the Notification Service Extension target

**Files:**
- Create: `Sources/CanopyNotificationService/NotificationService.swift`
- Create: `Sources/CanopyNotificationService/NotificationService.entitlements`
- Create: `Sources/CanopyNotificationService/Info.plist`
- Modify: `project.yml`

- [ ] **Step 1: Create the directory**

Run: `mkdir -p Sources/CanopyNotificationService`

- [ ] **Step 2: Write the extension entitlements file**

Create `Sources/CanopyNotificationService/NotificationService.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.sh.saqoo.CanopyCompanion</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: Write the extension Info.plist**

`INFOPLIST_KEY_NSExtension` via XcodeGen is unreliable because `NSExtension` is a nested dictionary. Use an explicit `Info.plist` file instead.

Create `Sources/CanopyNotificationService/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>Canopy Notification Service</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.usernotifications.service</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).NotificationService</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 4: Write the extension source**

Create `Sources/CanopyNotificationService/NotificationService.swift`:

```swift
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
```

- [ ] **Step 5: Add the extension target to `project.yml`**

Open `project.yml`. Under `targets:`, after the existing `CanopyCompanion:` block, add both the shared sources entry on the main target and a new extension target. Replace the entire `targets:` section with:

```yaml
targets:
  CanopyCompanion:
    type: application
    platform: iOS
    sources:
      - Sources/CanopyCompanion
      - Sources/Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: sh.saqoo.CanopyCompanion
        SWIFT_STRICT_CONCURRENCY: complete
        GENERATE_INFOPLIST_FILE: true
        INFOPLIST_KEY_UILaunchScreen_Generation: true
        INFOPLIST_KEY_CFBundleDisplayName: Canopy Companion
        INFOPLIST_KEY_UIBackgroundModes: remote-notification
    entitlements:
      path: Sources/CanopyCompanion/CanopyCompanion.entitlements
      properties:
        aps-environment: development
        com.apple.security.application-groups:
          - group.sh.saqoo.CanopyCompanion
    dependencies:
      - target: CanopyNotificationService

  CanopyNotificationService:
    type: app-extension
    platform: iOS
    sources:
      - Sources/CanopyNotificationService
      - Sources/Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: sh.saqoo.CanopyCompanion.NotificationService
        SWIFT_STRICT_CONCURRENCY: complete
        INFOPLIST_FILE: Sources/CanopyNotificationService/Info.plist
    entitlements:
      path: Sources/CanopyNotificationService/NotificationService.entitlements
      properties:
        com.apple.security.application-groups:
          - group.sh.saqoo.CanopyCompanion
```

Note: the `dependencies: - target: CanopyNotificationService` line on the main app target is what causes XcodeGen to embed the extension into the app bundle. The main app keeps `GENERATE_INFOPLIST_FILE: true`; only the extension uses an explicit Info.plist.

- [ ] **Step 6: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: output lists both targets (`CanopyCompanion`, `CanopyNotificationService`) and no errors.

- [ ] **Step 7: Build**

Run:
```bash
xcodebuild -project CanopyCompanion.xcodeproj -scheme CanopyCompanion \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build
```
Expected: both targets compile. The first build may take longer while Xcode provisions the new extension. If signing fails, check that the App Group from Task 3 Step 2 exists in the Apple Developer Portal and is assigned to both bundle IDs.

- [ ] **Step 8: Stage changes**

```bash
git add project.yml Sources/CanopyNotificationService/
git status
```
`CanopyCompanion.xcodeproj/` is a generated artifact — do not stage it (it's regenerated by `xcodegen`). Pause for approval.

---

## Task 7: Main app — `AppState` for deep-link navigation

**Files:**
- Create: `Sources/CanopyCompanion/AppState.swift`

- [ ] **Step 1: Write the state holder**

Create `Sources/CanopyCompanion/AppState.swift`:

```swift
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Set by `NotificationDelegate.didReceive` when the user taps a
    /// notification. `ContentView` observes this and pushes the detail view
    /// onto the navigation stack.
    @Published var pendingDetailId: String?

    private init() {}
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project CanopyCompanion.xcodeproj -scheme CanopyCompanion \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build
```
Expected: succeeds.

- [ ] **Step 3: Stage changes**

```bash
git add Sources/CanopyCompanion/AppState.swift
git status
```
Pause for approval.

---

## Task 8: Main app — `HistoryListView` and `HistoryDetailView`

**Files:**
- Create: `Sources/CanopyCompanion/HistoryView.swift`

- [ ] **Step 1: Write the views and route enum**

Create `Sources/CanopyCompanion/HistoryView.swift`:

```swift
import SwiftUI

enum HistoryRoute: Hashable {
    case list
    case detail(String)
}

struct HistoryListView: View {
    @State private var items: [NotificationHistoryItem] = []
    @State private var loadError: String?

    var body: some View {
        List {
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if items.isEmpty && loadError == nil {
                Text("No notifications yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                NavigationLink(value: HistoryRoute.detail(item.id)) {
                    HistoryRow(item: item)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    do {
                        try HistoryStore.deleteAll()
                        items = []
                    } catch {
                        loadError = "Clear failed: \(error.localizedDescription)"
                    }
                } label: {
                    Text("Clear All")
                }
                .disabled(items.isEmpty)
            }
        }
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        do {
            items = try HistoryStore.loadAll()
            loadError = nil
        } catch {
            loadError = "Load failed: \(error.localizedDescription)"
            items = []
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            try? HistoryStore.delete(id: items[i].id)
        }
        items.remove(atOffsets: offsets)
    }
}

private struct HistoryRow: View {
    let item: NotificationHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.subheadline.bold())
                .lineLimit(2)
            Text(item.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(item.receivedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let decision = item.decision {
                    DecisionBadge(decision: decision)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DecisionBadge: View {
    let decision: String

    var body: some View {
        Text(decision)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch decision {
        case "allow", "allowAlways": return .green
        case "deny": return .red
        default: return .gray
        }
    }
}

struct HistoryDetailView: View {
    let id: String
    @State private var item: NotificationHistoryItem?
    @State private var missing = false

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text(item.receivedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let decision = item.decision {
                                Label(decision, systemImage: icon(for: decision))
                                    .foregroundStyle(color(for: decision))
                                    .font(.subheadline)
                            }
                        }
                        Divider()
                        Text(item.body)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .navigationTitle(item.toolName ?? "Notification")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = item.body
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            } else if missing {
                ContentUnavailableView(
                    "Notification not found",
                    systemImage: "tray",
                    description: Text("It may have been cleared or pruned.")
                )
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            if let found = try HistoryStore.item(withId: id) {
                item = found
            } else {
                missing = true
            }
        } catch {
            missing = true
        }
    }

    private func icon(for decision: String) -> String {
        switch decision {
        case "allow", "allowAlways": return "checkmark.circle.fill"
        case "deny": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private func color(for decision: String) -> Color {
        switch decision {
        case "allow", "allowAlways": return .green
        case "deny": return .red
        default: return .gray
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project CanopyCompanion.xcodeproj -scheme CanopyCompanion \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build
```
Expected: succeeds.

- [ ] **Step 3: Stage changes**

```bash
git add Sources/CanopyCompanion/HistoryView.swift
git status
```
Pause for approval.

---

## Task 9: Main app — wire history into `ContentView` with path-based navigation

**Files:**
- Modify: `Sources/CanopyCompanion/ContentView.swift`

- [ ] **Step 1: Convert `NavigationStack` to path-based form and add History section**

Edit `Sources/CanopyCompanion/ContentView.swift`. Replace the entire file with:

```swift
import SwiftUI

struct ContentView: View {
    @AppStorage("workerUrl") private var workerUrl = ""
    @AppStorage("deviceToken") private var deviceToken = ""
    @ObservedObject private var network = NetworkService.shared
    @ObservedObject private var appState = AppState.shared
    @State private var sharedSecret = Self.loadOrMigrateSecret()
    @State private var testResult: String?
    @State private var navPath = NavigationPath()

    /// Migrate sharedSecret from UserDefaults to Keychain on first launch after update
    private static func loadOrMigrateSecret() -> String {
        if let existing = KeychainHelper.load(key: "sharedSecret") {
            return existing
        }
        if let legacy = UserDefaults.standard.string(forKey: "sharedSecret"), !legacy.isEmpty {
            KeychainHelper.save(key: "sharedSecret", value: legacy)
            UserDefaults.standard.removeObject(forKey: "sharedSecret")
            return legacy
        }
        return ""
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            Form {
                Section("Device Token") {
                    if deviceToken.isEmpty {
                        Text("Waiting for APNs token...")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text(deviceToken)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                            Spacer()
                            Button("Copy") {
                                UIPasteboard.general.string = deviceToken
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Section("Worker Configuration") {
                    TextField("Worker URL", text: $workerUrl)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Shared Secret", text: $sharedSecret)
                        .onChange(of: sharedSecret) { _, newValue in
                            if newValue.isEmpty {
                                KeychainHelper.delete(key: "sharedSecret")
                            } else {
                                KeychainHelper.save(key: "sharedSecret", value: newValue)
                            }
                        }
                }

                Section {
                    Button("Register Device") {
                        Task { await network.registerDevice() }
                    }
                    .disabled(deviceToken.isEmpty || workerUrl.isEmpty || sharedSecret.isEmpty)

                    if network.isRegistered {
                        Label("Registered", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    if let error = network.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button("Send Test Notification") {
                        Task {
                            testResult = await network.sendTestNotification()
                        }
                    }
                    .disabled(!network.isRegistered)

                    if let result = testResult {
                        Text(result)
                            .foregroundStyle(result == "Sent!" ? .green : .red)
                            .font(.caption)
                    }
                }

                Section("History") {
                    NavigationLink("View Notification History", value: HistoryRoute.list)
                }

                Section("How to Use") {
                    Text("""
                    1. Deploy the Cloudflare Worker
                    2. Enter the Worker URL and shared secret above
                    3. Tap "Register Device"
                    4. Configure the hook in Claude Code settings
                    5. Permission requests will appear as notifications with Allow/Deny buttons
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Canopy Companion")
            .navigationDestination(for: HistoryRoute.self) { route in
                switch route {
                case .list:
                    HistoryListView()
                case .detail(let id):
                    HistoryDetailView(id: id)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceTokenReceived)) { _ in
            // Token updated, UI will refresh via @AppStorage
        }
        .onChange(of: appState.pendingDetailId) { _, newValue in
            guard let id = newValue else { return }
            navPath = NavigationPath()
            navPath.append(HistoryRoute.list)
            navPath.append(HistoryRoute.detail(id))
            appState.pendingDetailId = nil
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project CanopyCompanion.xcodeproj -scheme CanopyCompanion \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build
```
Expected: succeeds.

- [ ] **Step 3: Stage changes**

```bash
git add Sources/CanopyCompanion/ContentView.swift
git status
```
Pause for approval.

---

## Task 10: Main app — handle notification tap and record decision in history

**Files:**
- Modify: `Sources/CanopyCompanion/AppDelegate.swift`

- [ ] **Step 1: Update `NotificationDelegate.didReceive`**

In `Sources/CanopyCompanion/AppDelegate.swift`, replace the entire `NotificationDelegate` class with:

```swift
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

        // Handle plain tap: open the detail view for this notification.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if let id = historyId {
                Task { @MainActor in
                    AppState.shared.pendingDetailId = id
                }
            }
            completionHandler()
            return
        }

        // Otherwise this is an action button (Allow / Deny / AllowAlways / dismiss).
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

        // Call completionHandler immediately — Apple requires prompt return.
        // sendDecision and history update run fire-and-forget.
        completionHandler()

        let decidedAt = Date()
        Task {
            await NetworkService.shared.sendDecision(requestId: requestId, decision: decision)
        }
        Task.detached {
            do {
                try HistoryStore.updateDecision(
                    requestId: requestId,
                    decision: decision,
                    decidedAt: decidedAt
                )
            } catch {
                NSLog("HistoryStore.updateDecision failed: \(error)")
            }
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
```

Leave the rest of `AppDelegate.swift` unchanged.

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project CanopyCompanion.xcodeproj -scheme CanopyCompanion \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build
```
Expected: succeeds.

- [ ] **Step 3: Stage changes**

```bash
git add Sources/CanopyCompanion/AppDelegate.swift
git status
```
Pause for approval.

---

## Task 11: Manual end-to-end verification on device "S"

**Files:** none

This task is a manual smoke test. Do NOT deploy the worker in production until the user explicitly says so; for testing, use `bun run dev` against a local tunnel or use the production worker only if the user authorizes it.

- [ ] **Step 1: Confirm user wants to proceed with device test**

Ask the user: "All code changes staged. Ready to deploy the Worker and install to device S for end-to-end testing?"

Do not proceed until the user says yes. Worker deploy and device install are both in the "do not do without approval" list per the global rules.

- [ ] **Step 2: Deploy the Worker (user-approved)**

Run: `cd worker && wrangler deploy`
Expected: deploy succeeds.

- [ ] **Step 3: Kill any existing app on device**

Find the running app's PID and confirm before killing:
```bash
xcrun devicectl device process list --device "00008150-001C65CC1E40401C" \
  | grep -i CanopyCompanion
```
If the app is running, terminate it via the device (or just let `devicectl install` handle the replacement; usually safer to close it by hand on the device).

- [ ] **Step 4: Install to device**

```bash
APP_PATH=$(xcodebuild -project CanopyCompanion.xcodeproj -scheme CanopyCompanion \
  -destination "platform=iOS,name=S" -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR = /{print $3}' | head -n1)/CanopyCompanion.app
xcrun devicectl device install app --device "00008150-001C65CC1E40401C" "$APP_PATH"
```
Expected: install succeeds. If the path is empty, re-run the build from Task 9.

- [ ] **Step 5: Verify test notification → history entry**

1. Open Canopy Companion on device S.
2. Tap **Send Test Notification**.
3. Lock the device; verify the notification appears.
4. Unlock, open the app, go to `History → View Notification History`.
5. Expected: one entry with title "Canopy Companion", body starts with "テスト通知".

- [ ] **Step 6: Verify `/request` with long `toolInput` stores full body**

From your dev machine:
```bash
LONG=$(python3 -c 'print("line " + "\n".join(["X" * 80 for _ in range(20)]))')
curl -s -X POST "$CANOPY_COMPANION_WORKER_URL/request" \
  -H "Authorization: Bearer $CANOPY_COMPANION_SECRET" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,os; print(json.dumps({'requestId':'test-long','toolName':'Bash','project':'demo','toolInput':os.environ['LONG']}))")"
```
Expected response: `{"ok":true,"requestId":"test-long"}`

On device:
1. Receive the notification (alert body will be truncated to ~200 chars).
2. Tap the notification.
3. Expected: app opens directly to `HistoryDetailView` for `test-long`, showing the FULL body (all ~1600 chars).

- [ ] **Step 7: Verify decision updates history**

1. Send another `/request` (shorter this time).
2. On the lock screen, long-press the notification to expose actions.
3. Tap **Allow**.
4. Open the app → `History`.
5. Expected: that entry shows a green `allow` badge.

- [ ] **Step 8: Verify `/notify` captures full body**

```bash
LONG_MSG=$(python3 -c 'print("Hook message: " + "X" * 500)')
curl -s -X POST "$CANOPY_COMPANION_WORKER_URL/notify" \
  -H "Authorization: Bearer $CANOPY_COMPANION_SECRET" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,os; print(json.dumps({'title':'Stop hook','message':os.environ['LONG_MSG']}))")"
```
Expected on device: notification arrives, tap opens detail view with all ~515 chars of the body.

- [ ] **Step 9: Verify persistence across launches**

1. Swipe up to kill the app.
2. Relaunch.
3. Navigate to History.
4. Expected: previous entries still present.

- [ ] **Step 10: Verify delete and clear**

1. Swipe-delete one row → gone.
2. Tap **Clear All** → list empties.
3. Kill and relaunch → list still empty.

---

## Task 12: Final commit sequence (only after user approval)

**Files:** any remaining unstaged

- [ ] **Step 1: Confirm everything is green and user approves commit**

Ask the user explicitly: "All manual tests passed. Ready to commit?"
Do NOT proceed without an explicit yes.

- [ ] **Step 2: Review the full diff**

```bash
git status
git diff --cached
```
Expected: staged changes include all the Worker/iOS changes from Tasks 1–10 but nothing from `build/` or `CanopyCompanion.xcodeproj/`.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add notification history with Service Extension

- New CanopyNotificationService target captures every push into the
  App Group container before the OS displays it, so truncated alerts
  can be read in full later.
- HistoryStore persists per-entry JSON files keyed by timestamp+id,
  with pruning at 100 entries and no cross-process locking needed.
- HistoryListView and HistoryDetailView show title, body, and the
  user's eventual decision; detail view uses monospaced copyable text.
- NotificationDelegate now handles the default tap action by pushing
  the relevant detail view onto the navigation stack via AppState.
- Worker /request includes full toolInput (capped at 3KB to fit APNs
  payload limit); /notify and /test add mutable-content:1 so the
  extension is invoked for all push types.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Push (only if user explicitly asks)**

Do not push unless the user says so. If they do:
```bash
git push origin main
```

---

## Notes for the implementer

- **Do not commit or deploy without approval.** Every task ends with `git add` only. Confirm with the user before running `git commit`, `wrangler deploy`, or `devicectl install`.
- **`xcodegen generate` rewrites `CanopyCompanion.xcodeproj/`.** This is expected. Do not stage or commit it; it is regenerated from `project.yml`.
- **Signing issues on first build of the NSE** usually mean the App Group isn't assigned in the Developer Portal. Fix that before changing any code.
- **If `INFOPLIST_KEY_NSExtension` as a stringified dict fails at runtime**, create `Sources/CanopyNotificationService/Info.plist` with the standard NSExtension structure and point to it via `settings.base.INFOPLIST_FILE`. Only fall back to this if needed; it's more verbose.
- **The `id` ↔ filename relationship** in `HistoryStore.delete(id:)` uses a substring match on `-\(id).json`. `id` values come from `requestId` (UUIDs from Claude Code or the worker's `crypto.randomUUID()`) or from `UUID().uuidString`, both of which are unique enough that substring matching is safe.
