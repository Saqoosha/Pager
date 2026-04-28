# Architecture

## System Overview

```
┌─────────────────┐     ┌──────────────────────┐     ┌───────┐     ┌──────────────────┐
│  Claude Code    │────▶│  Cloudflare Worker    │────▶│ APNs  │────▶│  iPhone / Watch  │
│  (hooks)        │     │  (relay + state)      │     │       │     │  (notification)  │
│                 │◀────│                       │◀────│       │◀────│  (action tap)    │
└─────────────────┘     └──────────────────────┘     └───────┘     └──────────────────┘
      poll                    KV store
```

## Components

### iOS App (`Sources/Pager/`)

Minimal SwiftUI app with four responsibilities:

1. **APNs registration** — Requests notification permission, receives device token from APNs
2. **Notification categories** — Registers `PERMISSION_REQUEST` category with three `UNNotificationAction` buttons (Allow, Deny, Always Allow)
3. **Action handling** — `NotificationDelegate` captures user's button tap, sends decision to Worker
4. **Settings UI** — Stores Worker URL + shared secret, registers device token with Worker

#### Class Diagram

```
PagerApp (@main)
  └── AppDelegate (UIApplicationDelegate)
        ├── registers UNNotificationCategory
        ├── registers for remote notifications
        └── sets NotificationDelegate as UNUserNotificationCenter.delegate

NotificationDelegate (UNUserNotificationCenterDelegate, @unchecked Sendable)
  ├── didReceive response → maps action ID to decision → NetworkService.sendDecision()
  └── willPresent → shows banner + sound when app is foreground

NetworkService (@MainActor, ObservableObject)
  ├── registerDevice() → POST /register
  ├── sendDecision() → POST /response (nonisolated)
  └── sendTestNotification() → POST /test

ContentView (SwiftUI)
  └── Form: device token, worker URL, secret, register button, test button
```

### Cloudflare Worker (`worker/src/index.ts`)

Stateless relay between Claude Code hooks and APNs, with KV for request state.

#### Routes

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/register` | Store device token in KV |
| POST | `/request` | Receive permission request from hook, store in KV, send APNs push |
| POST | `/response` | Receive decision from iOS app, update KV |
| GET | `/status/:id` | Hook polls for decision, returns and cleans up when decided |
| POST | `/notify` | Send plain notification (no action buttons) |
| POST | `/test` | Send test notification with action buttons |

#### APNs Authentication

- ES256 JWT signed with Apple APNs key (.p8)
- Key imported via Web Crypto `crypto.subtle.importKey("pkcs8", ...)`
- JWT includes `kid` (key ID) and `iss` (team ID) claims
- Supports sandbox and production endpoints via `APNS_USE_SANDBOX` env var

#### KV Schema

| Key | Value | TTL |
|-----|-------|-----|
| `device_token` | APNs device token hex string | none |
| `request:{id}` | `PendingRequest` JSON (requestId, toolName, toolInput, project, decision?, timestamp) | 300s (pending) / 60s (decided) |

### Claude Code Hooks

#### `permission-request.sh` (PermissionRequest hook)

```
1. Generate UUID for request
2. POST /request with tool name, formatted input, project
3. Poll GET /status/:id every 2 seconds
4. On decision: output hookSpecificOutput JSON with PermissionRequest decision.behavior
5. On timeout (120s): exit 0 (falls through to normal prompt)
6. On error / expired / unknown decision: exit 0 (falls through to normal prompt)
```

#### `notify-notification.sh` / `notify-stop.sh` (async hooks)

Simple POST to `/notify` with title and message. Strips markdown formatting from message content.

## Data Flow: Permission Request

```
1. Claude Code triggers PermissionRequest hook
2. permission-request.sh generates UUID, POSTs to /request (with source="claude" default on worker)
3. Worker stores PendingRequest in KV (TTL 5min)
4. Worker sends APNs push with category "PERMISSION_REQUEST"
5. iOS displays notification with Allow / Deny / Always Allow buttons (Claude avatar from source field)
6. User taps a button — also works on a locked iPhone via Apple Watch
7. NotificationDelegate maps action → decision string
8. NetworkService POSTs decision to /response (held alive by beginBackgroundTask)
9. Worker updates KV entry with decision (TTL 60s)
10. permission-request.sh poll picks up decision from /status/:id
11. Hook outputs PermissionRequest decision JSON
12. Claude Code receives decision, continues or stops
```

## Security

- All Worker routes require `Authorization: Bearer <secret>` header
- APNs key stored as Cloudflare Worker secret (not in code)
- Shared secret passed via environment variables, not hardcoded
- `ALLOW_ACTION` and `ALLOW_ALWAYS_ACTION` require device authentication (`authenticationRequired`)
- `DENY_ACTION` is marked as destructive (red UI)

## APNs Payload

### Permission Request

```json
{
  "aps": {
    "alert": { "title": "[project] toolName", "body": "toolInput preview" },
    "sound": "default",
    "category": "PERMISSION_REQUEST",
    "interruption-level": "time-sensitive",
    "mutable-content": 1
  },
  "requestId": "uuid"
}
```

### Plain Notification

```json
{
  "aps": {
    "alert": { "title": "title", "body": "message" },
    "sound": "default"
  }
}
```
