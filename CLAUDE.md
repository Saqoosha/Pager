# Canopy Companion

## Project Overview

iOS app + Cloudflare Worker for managing Claude Code permission requests via push notifications.
Users approve/deny tool permissions from iPhone lock screen or Apple Watch.

Stop/done notifications are also supported for **Codex CLI** and **Cursor**
(IDE Agent only). Per-CLI sender avatars are rendered as Apple Communication
Notifications, giving the lock-screen banner a Slack-style "from Claude Code"
/ "from Codex" / "from Cursor" header.

## Tech Stack

- **iOS app**: Swift 6, SwiftUI, iOS 17.0+, strict concurrency
- **Worker**: TypeScript, Cloudflare Workers, KV namespace
- **Build**: XcodeGen for Xcode project generation
- **Push**: APNs with ES256 JWT authentication

## Build Commands

```bash
# Generate Xcode project
xcodegen generate

# Build for device "S"
xcodebuild -project CanopyCompanion.xcodeproj -scheme CanopyCompanion \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build

# Install to device
xcrun devicectl device install app --device "<your-iphone-udid>" "$APP_PATH"

# Deploy worker
cd worker && wrangler deploy
```

## Key Design Decisions

- `NotificationDelegate` is a separate class from `AppDelegate` to satisfy Swift 6 nonisolated requirements for `UNUserNotificationCenterDelegate`
- `NetworkService` is `@MainActor` with `nonisolated` on `sendDecision()` since it's called from the notification delegate
- APNs sandbox is controlled by `APNS_USE_SANDBOX` worker var. Must match the app's `aps-environment` entitlement (currently `development`)
- Worker stores pending requests in KV with 5-minute TTL; decided requests get 60-second TTL for polling pickup

## Hooks

Three hook scripts in `hooks/` directory:
- `permission-request.sh` — sends permission request to worker, polls for decision (120s timeout). Wired per-project via `.claude/settings.json` `PreToolUse` hook
- `notify-notification.sh` — user-global Claude Code `Notification` hook. Title is `[<project>] Permission Needed / Waiting / Notification`
- `notify-stop.sh` — Stop hook for **Claude Code, Codex, and Cursor**. Accepts `--source <claude|codex|cursor>` (defaults to `claude`). Claude/Codex extract the body from `last_assistant_message` with a transcript fallback (Claude `.jsonl` shape — Codex transcripts won't match, so an empty `last_assistant_message` falls through to `"Done"`). Cursor uses `workspace_roots[]` + `status` for the title verb, and pulls the body from its JSONL transcript using the Anthropic Messages shape (`role:"assistant", message.content[].text`). Falls back to the status verb when the transcript yields nothing. PPID-walking guard suppresses the duplicate Claude notification when Cursor invokes Claude's hook directly via `~/.claude/settings.json`.

All three hit the worker's `/notify` or `/permission-request` endpoint. `notify-*.sh` must be installed to `~/.claude/hooks/` and wired via `~/.claude/settings.json` to fire for every project — symlink from this repo to keep both in sync. Codex/Cursor wiring lives in `~/.codex/hooks.json` and `~/.cursor/hooks.json`; see [docs/multi-cli-setup.md](docs/multi-cli-setup.md).

## Communication Notifications

The notification service extension donates an `INSendMessageIntent` per push so iOS renders the lock-screen banner with a sender avatar. APNs payload carries `source: "claude" | "codex" | "cursor"`; the extension picks the matching PNG from `Sources/CanopyNotificationService/Avatars/`.

This requires the `com.apple.developer.usernotifications.communication` entitlement on the main app target only — the Service Extension does not need it (and Xcode does not expose the capability for extension targets). **No Apple approval form is needed** — it's a free capability — but `xcodebuild -allowProvisioningUpdates` cannot enable it via CLI alone. Open the project in Xcode once and add *Communication Notifications* capability to the **CanopyCompanion** target via Signing & Capabilities; Xcode then registers it on the App ID and subsequent CLI builds succeed. If the entitlement is missing the extension still works — it falls back to a `UNNotificationAttachment` thumbnail.

## Credentials

- APNs key: `credentials/AuthKey_<your-apns-key-id>.p8` (do NOT commit)
- Worker secrets: `SHARED_SECRET`, `APNS_PRIVATE_KEY` (set via `wrangler secret put`)

## Environment Variables

- `CANOPY_COMPANION_WORKER_URL` — Worker endpoint URL
- `CANOPY_COMPANION_SECRET` — Shared secret for auth
