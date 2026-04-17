# Canopy Companion

## Project Overview

iOS app + Cloudflare Worker for managing Claude Code permission requests via push notifications.
Users approve/deny tool permissions from iPhone lock screen or Apple Watch.

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
- `notify-stop.sh` — user-global Claude Code `Stop` hook. Body is the last assistant text from the transcript (first 200 chars). Falls back to `"Done"` when the transcript has no text block

All three hit the worker's `/notify` or `/permission-request` endpoint. `notify-*.sh` must be installed to `~/.claude/hooks/` and wired via `~/.claude/settings.json` to fire for every project — symlink from this repo to keep both in sync.

## Credentials

- APNs key: `credentials/AuthKey_<your-apns-key-id>.p8` (do NOT commit)
- Worker secrets: `SHARED_SECRET`, `APNS_PRIVATE_KEY` (set via `wrangler secret put`)

## Environment Variables

- `CANOPY_COMPANION_WORKER_URL` — Worker endpoint URL
- `CANOPY_COMPANION_SECRET` — Shared secret for auth
