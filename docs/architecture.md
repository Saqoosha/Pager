# Architecture

## System Overview

```
┌─────────────────┐     ┌──────────────────────┐     ┌───────┐     ┌──────────────────┐
│  Claude / Codex │────▶│  Cloudflare Worker    │────▶│ APNs  │────▶│  iPhone / Watch  │
│  / Cursor hooks │     │  (relay + state)      │     │       │     │  (notification)  │
│                 │◀────│                       │◀────│       │◀────│  (action tap)    │
└─────────────────┘     └──────────────────────┘     └───────┘     └──────────────────┘
      poll                    KV store
                                                                    ┌──────────────────┐
                                                                    │   App container  │
                                                                    │   (App Group)    │
                                                                    │  history JSON    │
                                                                    │  • NSE appends   │
                                                                    │  • app updates   │
                                                                    │    decision      │
                                                                    └──────────────────┘
```

## Components

### iOS App (`Sources/Pager/`)

SwiftUI app with five responsibilities:

1. **APNs registration** — Requests notification permission, receives device token from APNs
2. **Notification categories** — Registers `PERMISSION_REQUEST` category with three `UNNotificationAction` buttons (Allow, Deny, Always Allow)
3. **Action handling** — `NotificationDelegate` captures the user's button tap, sends decision to Worker, updates the local history entry
4. **Settings UI** — Worker URL + shared secret (Keychain), device token, register / test buttons
5. **History view** — Lists every push received and its decision; tapping a notification jumps directly to the detail page

### Notification Service Extension (`Sources/PagerNotificationService/`)

Runs in a separate process when an APNs push with `mutable-content: 1` arrives.

- Donates an `INSendMessageIntent` carrying the per-source avatar so iOS renders a Communication-style banner ("from Claude Code", etc.)
- Falls back to `UNNotificationAttachment` if the Communication Notifications entitlement is missing or the system rejects the intent
- Appends a `NotificationHistoryItem` to the App Group history store and posts a Darwin notification so the main app refreshes its list live

### Shared (`Sources/Shared/`)

Compiled into both targets:

- `NotificationHistoryItem` — Codable record (id, receivedAt, title, body, decision, decidedAt, source…)
- `HistoryStore` — JSON-per-entry filesystem store inside the App Group container; pruning, atomic writes, separate writer paths for NSE (append) and main app (updateDecision)
- `HistoryUpdateBridge` — Darwin notification (`sh.saqoo.Pager.historyDidUpdate`) re-posted as a regular `NotificationCenter` event for SwiftUI

### Class Diagram

```
PagerApp (@main)
  └── AppDelegate (UIApplicationDelegate, @MainActor)
        ├── registers UNNotificationCategory  (no authenticationRequired — Watch needs locked-phone delivery)
        ├── registers for remote notifications
        ├── re-saves shared secret with kSecAttrAccessibleAfterFirstUnlock
        ├── starts HistoryUpdateBridge
        └── sets NotificationDelegate.shared as UNUserNotificationCenter.delegate

NotificationDelegate (UNUserNotificationCenterDelegate, @unchecked Sendable)
  ├── didReceive default action  → AppState.pendingDetailId  (jumps to History detail)
  ├── didReceive Allow/Deny/Always → maps action ID to decision
  │                                 → completionHandler() called immediately
  │                                 → NetworkService.sendDecision() under beginBackgroundTask
  │                                 → HistoryStore.updateDecision()
  │                                 → endBackgroundTask
  └── willPresent → shows banner + sound when app is foreground

NetworkService (@MainActor, ObservableObject)
  ├── registerDevice()              → POST /register
  ├── sendDecision() (nonisolated)  → POST /response  (10s timeout, one retry)
  └── sendTestNotification()        → POST /test

ContentView (SwiftUI, NavigationStack)
  ├── HistoryListView  (root)
  │   ├── refreshes on scenePhase=.active and HistoryUpdateBridge.didUpdate
  │   └── per-row SourceAvatar (claude / codex / cursor PNG)
  ├── HistoryDetailView  (push)
  └── SettingsView  (push) — worker URL, secret (Keychain), register, test

NotificationService (UNNotificationServiceExtension)
  ├── parses APNs userInfo (requestId, source, toolInputFull, project, toolName)
  ├── HistoryStore.append(NotificationHistoryItem)
  ├── if source set: applyCommunicationStyle (donate INSendMessageIntent) → updating(from:)
  └── else / on failure: applyAttachmentFallback (copy bundled PNG to tmp, attach)

KeychainHelper
  ├── save(key, value)  with kSecAttrAccessibleAfterFirstUnlock
  ├── load(key)
  └── delete(key)
```

### Cloudflare Worker (`worker/src/index.ts`)

Stateless relay between CLI hooks and APNs, with KV for request state.

#### Routes

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/register` | Store device token in KV (validates lowercase-hex format) |
| POST | `/request` | Receive permission request from hook, store in KV, send APNs push |
| POST | `/response` | Receive decision from iOS app, update KV |
| GET  | `/status/:id` | Hook polls for decision; returns `pending` / `decided` / `expired` |
| POST | `/notify` | Send plain notification (no action buttons), optional `source` for avatar |
| POST | `/test` | Send test notification with action buttons |
| OPTIONS | `*` | CORS preflight |

All non-OPTIONS routes require `Authorization: Bearer <SHARED_SECRET>`, compared with a SHA-256 timing-safe equal.

#### APNs Authentication

- ES256 JWT signed with Apple APNs key (.p8)
- Key imported via Web Crypto `crypto.subtle.importKey("pkcs8", ...)`
- Web Crypto's ECDSA sign returns raw `r||s` directly — no DER-to-raw conversion needed
- JWT includes `kid` (key ID) and `iss` (team ID) claims
- Supports sandbox and production endpoints via `APNS_USE_SANDBOX` env var

#### KV Schema

| Key | Value | TTL |
|-----|-------|-----|
| `device_token` | APNs device token hex string | none |
| `request:{id}` | `PendingRequest` JSON (requestId, toolName, toolInput, project, decision?, timestamp) | 300s (pending) / 60s (decided) |

`requestId` is constrained to `^[A-Za-z0-9_-]{1,128}$` because it's used as both a KV key and a filename suffix on iOS.

#### Payload size limits

`/request` clamps incoming strings before pushing to APNs so an adversarial payload cannot exceed APNs' 4KB limit:

- `toolName` ≤ 120 chars
- `project` ≤ 120 chars
- `toolInputFull` ≤ 3000 chars (truncated with `…`)
- `inputPreview` (the lock-screen body) ≤ 200 chars

### CLI Hooks (`hooks/`)

#### `permission-request.sh` (PermissionRequest hook)

```
1. Read JSON from stdin, derive tool_name, tool-specific input preview, project, requestId (uuid)
2. POST /request with tool name, formatted input, project (source defaults to "claude" on the worker)
3. Poll GET /status/:id every 2 seconds (max 120s; 3 consecutive curl failures bail out)
4. On decision:
     allow / allowAlways → emit hookSpecificOutput { decision: { behavior: "allow" } }
     deny                → emit hookSpecificOutput { decision: { behavior: "deny", message: "Denied via Pager" } }
5. On timeout / expired / unknown decision: exit 0 (falls through to normal Claude prompt)
```

#### `notify-notification.sh` / `notify-stop.sh` (async notification hooks)

POST to `/notify` with title, message, and `source`. Markdown formatting is stripped before send.

`notify-stop.sh` is multi-CLI:

- `claude` / `codex` — read `last_assistant_message` from stdin, fall back to the JSONL transcript (Claude shape; Codex transcripts won't match and fall through to `"Done"`). Claude branch waits ~2s for the assistant block to flush before parsing
- `cursor` — read `workspace_roots[]` + `status`, pull last assistant text block from the Anthropic Messages-shaped JSONL transcript
- PPID guard suppresses the duplicate Claude notification when Cursor invokes the Claude CLI inside its own hook

## Data Flow: Permission Request

```
1. Claude Code triggers PermissionRequest hook
2. permission-request.sh generates UUID, POSTs to /request (worker defaults source="claude")
3. Worker stores PendingRequest in KV (TTL 5min) and sends APNs push (category PERMISSION_REQUEST,
   mutable-content: 1, interruption-level: time-sensitive)
4. NSE on the device appends NotificationHistoryItem, donates INSendMessageIntent for the avatar,
   posts Darwin notification
5. iOS displays Communication-style notification with Allow / Deny / Always Allow buttons
6. User taps a button — also works on a locked iPhone via Apple Watch (no authenticationRequired flag)
7. NotificationDelegate maps action → decision string
8. NetworkService POSTs decision to /response (held alive by beginBackgroundTask)
9. Worker updates KV entry with decision (TTL 60s — let it expire rather than delete-on-read so a lost
   HTTP response on the poller side doesn't lose the decision)
10. permission-request.sh poll picks up decision from /status/:id
11. Hook outputs PermissionRequest decision JSON
12. Claude Code receives decision, continues or stops
13. HistoryStore.updateDecision sets decision/decidedAt on the entry; main app's HistoryListView
    refreshes via the Darwin → NotificationCenter bridge
```

## Security

- All Worker routes require `Authorization: Bearer <secret>`; comparison is SHA-256 timing-safe equal
- APNs key stored as Cloudflare Worker secret (not in code)
- Shared secret on the iPhone is stored in Keychain (`kSecAttrAccessibleAfterFirstUnlock`) so the watch-decision POST works while the device is locked
- `requestId` is regex-validated (`^[A-Za-z0-9_-]{1,128}$`) before being used as a KV key or filename
- `source` is allowlisted server-side and re-validated by the NSE; unknown values are logged and delivered as plain notifications, never impersonating an existing CLI
- Internal errors are logged server-side but the public response is the opaque `{"error":"internal_error"}`

> **Note**: Allow / Deny actions are **not** marked `authenticationRequired`. With that flag, taps on a locked iPhone (including ones forwarded from Apple Watch) get queued until the iPhone is unlocked and never reach the delegate. Trade-off: anyone holding the unlocked phone can tap Allow.

## APNs Payloads

### Permission Request (`/request`)

```json
{
  "aps": {
    "alert": { "title": "[project] toolName", "body": "toolInput preview (≤200 chars)" },
    "sound": "default",
    "category": "PERMISSION_REQUEST",
    "interruption-level": "time-sensitive",
    "mutable-content": 1
  },
  "requestId": "uuid",
  "toolName": "...",
  "toolInputFull": "full toolInput (≤3000 chars)",
  "project": "...",
  "source": "claude" | "codex" | "cursor"
}
```

### Plain Notification (`/notify`)

```json
{
  "aps": {
    "alert": { "title": "title", "body": "message" },
    "sound": "default",
    "interruption-level": "time-sensitive",
    "mutable-content": 1
  },
  "source": "claude" | "codex" | "cursor"   // optional
}
```

### History entry (App Group container)

```jsonc
// {appgroup}/history/<unix_millis>-<id>.json
{
  "id": "uuid (= requestId for permission requests)",
  "receivedAt": "2026-04-28T12:43:01.234Z",
  "title": "[project] toolName",
  "body": "full toolInput / message",
  "category": "PERMISSION_REQUEST" | null,
  "project": "...",
  "toolName": "...",
  "requestId": "...",
  "source": "claude" | "codex" | "cursor" | null,
  "decision": "allow" | "allowAlways" | "deny" | null,
  "decidedAt": "2026-04-28T12:43:05Z" | null
}
```

`HistoryStore.maxItems = 100`; older entries are best-effort pruned on append.
