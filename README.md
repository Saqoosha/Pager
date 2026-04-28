# Pager

iOS app for managing AI coding agent permission requests and "done" notifications from your iPhone and Apple Watch. Supports **Claude Code**, **Codex CLI**, and **Cursor**.

Receive push notifications when your agent needs permission to run a tool, and approve or deny directly from the lock screen or Watch — no need to switch to the terminal.

## Features

- **Lock screen actions**: Allow / Deny / Always Allow buttons on notifications
- **Apple Watch support**: Action buttons mirrored automatically; Watch taps reach the app even with the iPhone locked
- **Plain notifications**: Receive "task done" and "waiting for input" alerts
- **Per-CLI sender avatars**: Slack-style "from Claude Code / Codex / Cursor" header on the lock screen via Apple Communication Notifications
- **History view**: Every notification is persisted in an App Group container — tap any push to jump straight to the full payload + decision
- **Cloudflare Worker relay**: APNs push via lightweight edge worker with KV state

## Architecture

```
CLI hooks  ──→  Cloudflare Worker  ──→  APNs  ──→  iPhone/Watch
                      ↕ KV
           hook polls for decision  ←──  user taps action button
```

See [docs/architecture.md](docs/architecture.md) for details.

## Setup

### Prerequisites

- Xcode 16+ with iOS 17.0 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Apple Developer account with APNs key
- Cloudflare account
- [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/)
- [Bun](https://bun.sh/) (for worker dependencies)

### 1. Deploy the Worker

```bash
cd worker
bun install
# Set secrets
wrangler secret put SHARED_SECRET
wrangler secret put APNS_PRIVATE_KEY  # paste .p8 key content
wrangler deploy
```

### 2. Build the iOS App

```bash
xcodegen generate
open Pager.xcodeproj
```

Build and run on a physical device (push notifications require a real device).
The first build must happen in Xcode so it can register the *Communication
Notifications* capability on the App ID — see
[docs/multi-cli-setup.md](docs/multi-cli-setup.md#one-time-xcode-setup).

### 3. Configure the App

1. Open Pager on your iPhone
2. Tap the gear icon → enter the Worker URL and shared secret (the secret is stored in Keychain, not UserDefaults)
3. Tap "Register Device"
4. Send a test notification to verify

### 4. Configure Hooks

Set environment variables in your shell profile or CLI settings:

```bash
export PAGER_WORKER_URL="https://your-worker.workers.dev"
export PAGER_SECRET="your-shared-secret"
```

Add hooks in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "/path/to/hooks/permission-request.sh" }]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "/path/to/hooks/notify-notification.sh", "async": true }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "/path/to/hooks/notify-stop.sh", "async": true }]
      }
    ]
  }
}
```

For Codex / Cursor wiring, see [docs/multi-cli-setup.md](docs/multi-cli-setup.md).

## Project Structure

```
Sources/
  Pager/                              # Main iOS app target
    PagerApp.swift                    # @main entry point
    AppDelegate.swift                 # APNs registration, notification categories,
                                      #   NotificationDelegate (action handling)
    AppState.swift                    # @Published navigation state shared with ContentView
    ContentView.swift                 # NavigationStack root + Settings form
    HistoryView.swift                 # History list, detail view, source avatars
    NetworkService.swift              # HTTP client (/register, /response, /test)
    KeychainHelper.swift              # Shared-secret storage in Keychain
    Pager.entitlements                # aps-environment, app group, communication usernotifications

  PagerNotificationService/           # Notification Service Extension target
    NotificationService.swift         # Donates INSendMessageIntent for sender avatars,
                                      #   appends to HistoryStore, attachment fallback
    Avatars/{claude,codex,cursor}.png # 256×256 sender avatars

  Shared/                             # Compiled into BOTH targets
    HistoryStore.swift                # JSON-per-entry store in App Group container
    HistoryUpdateBridge.swift         # Darwin notification bridge (NSE → main app)
    NotificationHistoryItem.swift     # Codable payload type

worker/
  src/index.ts                        # Cloudflare Worker (APNs JWT, KV state, routes)
  wrangler.toml                       # Worker configuration

hooks/
  permission-request.sh               # PermissionRequest hook → /request, polls /status
  notify-notification.sh              # Notification hook → /notify
  notify-stop.sh                      # Stop hook for Claude / Codex / Cursor (--source)

scripts/
  refresh-avatars.sh                  # Re-extract avatars from locally installed Mac apps
```

## Bundle ID

`sh.saqoo.Pager` (extension: `sh.saqoo.Pager.NotificationService`)
