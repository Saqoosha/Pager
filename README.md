# Canopy Companion

iOS app for managing Claude Code permission requests from your iPhone and Apple Watch.

Receive push notifications when Claude Code needs permission to run a tool, and approve or deny directly from the lock screen or Watch — no need to switch to the terminal.

## Features

- **Lock screen actions**: Allow / Deny / Always Allow buttons on notifications
- **Apple Watch support**: Action buttons mirrored automatically via iOS notification system
- **Plain notifications**: Receive "task done" and "waiting for input" alerts
- **Cloudflare Worker relay**: APNs push via lightweight edge worker with KV state

## Architecture

```
Claude Code hooks  ──→  Cloudflare Worker  ──→  APNs  ──→  iPhone/Watch
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
open CanopyCompanion.xcodeproj
```

Build and run on a physical device (push notifications require a real device).

### 3. Configure the App

1. Open Canopy Companion on your iPhone
2. Enter the Worker URL and shared secret
3. Tap "Register Device"
4. Send a test notification to verify

### 4. Configure Claude Code Hooks

Set environment variables in your shell profile or Claude Code settings:

```bash
export CANOPY_COMPANION_WORKER_URL="https://your-worker.workers.dev"
export CANOPY_COMPANION_SECRET="your-shared-secret"
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

## Project Structure

```
Sources/CanopyCompanion/
  CanopyCompanionApp.swift    # App entry point
  AppDelegate.swift           # APNs registration, notification categories & delegate
  ContentView.swift           # Settings UI (worker URL, secret, register, test)
  NetworkService.swift        # HTTP client for worker communication
worker/
  src/index.ts                # Cloudflare Worker (APNs JWT, request lifecycle)
  wrangler.toml               # Worker configuration
hooks/
  permission-request.sh       # Claude Code PermissionRequest hook
```

## Bundle ID

`sh.saqoo.CanopyCompanion`
