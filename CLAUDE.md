# Pager

## Project Overview

iOS app + Cloudflare Worker for managing AI coding agent permission requests
via push notifications. Users approve/deny tool permissions from iPhone lock
screen or Apple Watch.

Stop/done notifications are also supported for **Codex CLI** and **Cursor**
(IDE Agent only). Per-CLI sender avatars are rendered as Apple Communication
Notifications, giving the lock-screen banner a Slack-style "from Claude Code"
/ "from Codex" / "from Cursor" header.

A History view inside the app lists every received notification (push payload
+ decision) by reading a JSON-per-entry store in the App Group container that
both the main app and the Notification Service Extension write into.

## Tech Stack

- **iOS app**: Swift 6, SwiftUI, iOS 17.0+, strict concurrency (`SWIFT_STRICT_CONCURRENCY=complete`)
- **Notification Service Extension**: same Swift 6 settings; shares an App Group with the main app
- **Worker**: TypeScript, Cloudflare Workers, KV namespace
- **Build**: XcodeGen for Xcode project generation
- **Push**: APNs with ES256 JWT authentication (Web Crypto)

## Targets

- `Pager` — main app, bundle id `sh.saqoo.Pager`
- `PagerNotificationService` — `UNNotificationServiceExtension`, bundle id `sh.saqoo.Pager.NotificationService`
- App Group: `group.sh.saqoo.Pager` (both targets)

## Build Commands

```bash
# Generate Xcode project
xcodegen generate

# Build for device "S"
xcodebuild -project Pager.xcodeproj -scheme Pager \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build

# Install to device
xcrun devicectl device install app --device "<your-iphone-udid>" "$APP_PATH"

# Deploy worker
cd worker && wrangler deploy

# Re-extract sender avatars from locally installed Mac apps
./scripts/refresh-avatars.sh
```

## Key Design Decisions

- `NotificationDelegate` is a separate class from `AppDelegate` to satisfy Swift 6 nonisolated requirements for `UNUserNotificationCenterDelegate`
- `NetworkService` is `@MainActor` with `nonisolated` on `sendDecision()` since it's called from the notification delegate. After `completionHandler` is called, `sendDecision` runs under a `beginBackgroundTask` assertion so iOS keeps the app alive long enough to POST the watch decision
- Action buttons (`ALLOW_ACTION`, `DENY_ACTION`, `ALLOW_ALWAYS_ACTION`) are **not** marked `authenticationRequired`. With that flag, taps on a locked iPhone (including ones forwarded from Apple Watch) get queued until unlock and never reach the delegate. Trade-off: anyone holding the unlocked phone could tap Allow
- Shared secret is stored in Keychain (`KeychainHelper`, kSecAttrAccessibleAfterFirstUnlock). Items first stored without that attribute are inaccessible while the device is locked, which silently 401s the watch-decision POST — the AppDelegate re-saves the secret at launch to migrate legacy entries
- `HistoryStore` writes one JSON file per notification into the App Group container. NSE writes on append; main app overwrites on `updateDecision`. They never target the same file at the same time. `HistoryUpdateBridge` posts a Darwin notification so the main app can refresh the SwiftUI list live when the NSE writes a new entry
- APNs sandbox is controlled by `APNS_USE_SANDBOX` worker var. Must match the app's `aps-environment` entitlement (currently `development`)
- Worker stores pending requests in KV with 5-minute TTL; decided requests get 60-second TTL (let TTL expire rather than delete-on-read so the poller doesn't miss the decision if its HTTP response is lost)

## Hooks

Three hook scripts in `hooks/` directory:
- `permission-request.sh` — sends permission request to worker, polls for decision (120s timeout). Wired (per-project or globally) via `settings.json` `PermissionRequest` hook. Returns `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny",...}}}` so Claude Code honors the watch decision instead of falling through to the inline prompt. Tool-input preview is rendered tool-by-tool (Bash → command, Read/Write/Edit → file_path, etc.) so the lock-screen banner is human-readable
- `notify-notification.sh` — user-global Claude Code `Notification` hook. Skips `permission_prompt` (already covered by the richer permission-request hook) and `observer-sessions` (claude-mem noise). Title is `[<project>] Waiting / Notification`. Always sends `source: "claude"`
- `notify-stop.sh` — Stop hook for **Claude Code, Codex, and Cursor**. Accepts `--source <claude|codex|cursor>` (defaults to `claude`). Claude/Codex extract the body from `last_assistant_message` with a transcript fallback (Claude `.jsonl` shape — Codex transcripts don't match, so an empty `last_assistant_message` falls through to `"Done"`; the Claude branch waits up to ~2s for the final assistant block to land on disk before parsing, since Stop can fire before the file is flushed). Cursor uses `workspace_roots[]` + `status` for the title verb, and pulls the body from its JSONL transcript using the Anthropic Messages shape (`role:"assistant", message.content[].text`). Falls back to the status verb when the transcript yields nothing. PPID-walking guard suppresses the duplicate Claude notification when Cursor invokes Claude's hook directly via `~/.claude/settings.json`

All three hit the worker's `/notify` or `/request` endpoint. `notify-*.sh` must be installed to `~/.claude/hooks/` and wired via `~/.claude/settings.json` to fire for every project — symlink from this repo to keep both in sync. Codex/Cursor wiring lives in `~/.codex/hooks.json` and `~/.cursor/hooks.json`; see [docs/multi-cli-setup.md](docs/multi-cli-setup.md).

Hook activity is logged to `~/Library/Logs/Pager/{permission-request,notify-stop}.log` (override directory with `PAGER_LOG_DIR`).

## Communication Notifications

The notification service extension donates an `INSendMessageIntent` per push so iOS renders the lock-screen banner with a sender avatar. APNs payload carries `source: "claude" | "codex" | "cursor"`; the extension picks the matching PNG from `Sources/PagerNotificationService/Avatars/`. The avatar list is mirrored in three places — keep them in sync when adding a new source:
1. `worker/src/index.ts` (`VALID_SOURCES`)
2. `Sources/PagerNotificationService/NotificationService.swift` (`NotificationSource`)
3. `Sources/Pager/HistoryView.swift` (`SourceAvatar.assetName`)

This requires the `com.apple.developer.usernotifications.communication` entitlement on the main app target only — the Service Extension does not need it (and Xcode does not expose the capability for extension targets). **No Apple approval form is needed** — it's a free capability — but `xcodebuild -allowProvisioningUpdates` cannot enable it via CLI alone. Open the project in Xcode once and add *Communication Notifications* capability to the **Pager** target via Signing & Capabilities; Xcode then registers it on the App ID and subsequent CLI builds succeed. If the entitlement is missing the extension still works — it falls back to a `UNNotificationAttachment` thumbnail.

## Credentials

- APNs key: `credentials/AuthKey_<your-apns-key-id>.p8` (do NOT commit)
- Worker secrets: `SHARED_SECRET`, `APNS_PRIVATE_KEY` (set via `wrangler secret put`)
- Worker plaintext vars (see `wrangler.toml`): `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_USE_SANDBOX`

## Environment Variables

- `PAGER_WORKER_URL` — Worker endpoint URL
- `PAGER_SECRET` — Shared secret for auth
- `PAGER_LOG_DIR` — Optional override for hook log location (default `~/Library/Logs/Pager`)
