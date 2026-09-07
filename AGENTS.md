# AGENTS.md — Pager

`CLAUDE.md` in this repo is a symlink to this file; edit only this one.

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
- **Markdown**: [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) for rendering notification body in History detail view

## Targets

- `Pager` — main app, bundle id `sh.saqoo.pager-app`
- `PagerNotificationService` — `UNNotificationServiceExtension`, bundle id `sh.saqoo.pager-app.NotificationService`
- App Group: `group.sh.saqoo.pager-app` (both targets)

## Build Commands

```bash
# Generate Xcode project
xcodegen generate

# Build for device "S"
xcodebuild -project Pager.xcodeproj -scheme Pager \
  -destination "platform=iOS,name=S" -allowProvisioningUpdates build

# Archive for App Store Connect/TestFlight
BUILD_NUMBER=$(date +%Y%m%d%H%M)
ARCHIVE_DIR="/tmp/pager-testflight-$BUILD_NUMBER"
xcodebuild archive -project Pager.xcodeproj -scheme Pager \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_DIR/Pager.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates

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
- APNs sandbox vs production is **auto-detected per device token**. `sendPush()` first tries the cached environment for that token (or `APNS_USE_SANDBOX` as the seed when nothing is cached) and, on a `BadDeviceToken` 400, retries against the opposite host and updates the cache (`apns_env:<deviceToken>` KV key). Routes can still pass an explicit `sandbox` boolean in the POST body to bypass auto-detect — the hooks honor `PAGER_SANDBOX` for backward compatibility, but it's no longer required: omitting the flag lets the worker figure it out. The `/test` endpoint relies entirely on auto-detect, so a debug build (sandbox token) and a TestFlight build (production token) can share the same registered device entry without manual reconfiguration.
- Worker stores pending requests in KV with 5-minute TTL; decided requests get 60-second TTL (let TTL expire rather than delete-on-read so the poller doesn't miss the decision if its HTTP response is lost)
- `/notify` pushes include a `messageFull` custom key in the APNs payload with the original message (up to 3000 chars, capped at the Worker). The Notification Service Extension reads it (falling back to `aps.alert.body` if absent) and stores it as `NotificationHistoryItem.body`. The iOS history detail view renders it with MarkdownUI so formatting (bold, italic, code blocks, lists, links, headers, tables) is preserved. The lock-screen banner uses an LLM-shortened plain-text version for Apple Watch legibility.
- TestFlight/App Store Connect uploads require the App Store Connect app record to exist first. The public ASC name is **Saqoosha Pager** because `Pager` is already taken globally; the installed app display name remains `Pager`.
- Export compliance is declared in both Info.plists with `ITSAppUsesNonExemptEncryption = false`. This is valid for the current app because it only uses standard `URLSession` HTTPS and Keychain storage, with no custom cryptography.

## Hooks

Three hook scripts in `hooks/` directory:
- `permission-request.sh` — sends permission request to worker, polls for decision (120s timeout). Wired (per-project or globally) via `settings.json` `PermissionRequest` hook. Returns `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny",...}}}` so Claude Code honors the watch decision instead of falling through to the inline prompt. Tool-input preview is rendered tool-by-tool (Bash → command, Read/Write/Edit → file_path, etc.) so the lock-screen banner is human-readable
- `notify-notification.sh` — user-global Claude Code `Notification` hook. Skips `permission_prompt` (already covered by the richer permission-request hook) and `observer-sessions` (claude-mem noise). Title is `[<project>] Waiting / Notification`. Always sends `source: "claude"`
- `notify-stop.sh` — Stop hook for **Claude Code, Codex, and Cursor**. Accepts `--source <claude|codex|cursor>` (defaults to `claude`). Claude/Codex extract the body from `last_assistant_message` with a transcript fallback (Claude `.jsonl` shape — Codex transcripts don't match, so an empty `last_assistant_message` falls through to `"Done"`; the Claude branch waits up to ~2s for the final assistant block to land on disk before parsing, since Stop can fire before the file is flushed). Codex review subagents return their result as a JSON object (`findings[]` / `overall_correctness` / `overall_explanation`, or `{title, body}` / `{summary}`); `flatten_codex_json` summarizes that to readable text before `clean_text` runs, otherwise the lock-screen banner shows raw `{ "findings": [...]`. Cursor uses `workspace_roots[]` + `status` for the title verb, and pulls the body from its JSONL transcript using the Anthropic Messages shape (`role:"assistant", message.content[].text`). Falls back to the status verb when the transcript yields nothing. PPID-walking guard suppresses the duplicate Claude notification when Cursor invokes Claude's hook directly via `~/.claude/settings.json`. Two Canopy-specific stand-downs also live here, and they cover
different things: `$CANOPY_PANE` (set only when Canopy will push for that
session) suppresses the whole Stop notification, while `is_canopy_keepalive_turn`
suppresses just the hourly prompt-cache keep-alive turn Canopy injects — a real
turn on the main conversation whose reply is the single word `OK`, so it fires
Stop like any other turn and Canopy cannot suppress it from its side (its own
swallow runs on the webview bridge, downstream of the CLI process this hook lives
in). Detection reads the transcript's last user prompt for the `[Canopy
keep-alive]` tag, which Canopy holds as `KeepAliveGate.promptPrefix`. Three
properties are load-bearing: every failure path falls through to notifying (a
missed suppression is one spurious buzz, a wrong one silently eats a completion
someone was waiting for); a prompt is identified structurally rather than by
whether it produced text, because a record that gets *skipped* lets an older
keep-alive stand in as the apparent last prompt — an uncaptioned screenshot is
written as `content:[{"type":"image"}]` with no text block, and a record can
carry a `tool_result` block alongside a genuine follow-up comment; and `jq -R` +
`fromjson?` parses each line alone so one corrupt line cannot hide every record
after it

All three hit the worker's `/notify` or `/request` endpoint. `notify-*.sh` must be installed to `~/.claude/hooks/` and wired via `~/.claude/settings.json` to fire for every project — symlink from this repo to keep both in sync. Codex/Cursor wiring lives in `~/.codex/hooks.json` and `~/.cursor/hooks.json`; see [docs/multi-cli-setup.md](docs/multi-cli-setup.md).

Hook activity is logged to `~/Library/Logs/Pager/{permission-request,notify-stop}.log` (override directory with `PAGER_LOG_DIR`).

## Communication Notifications

The notification service extension donates an `INSendMessageIntent` per push so iOS renders the lock-screen banner with a sender avatar. APNs payload carries `source: "claude" | "codex" | "cursor"`; the extension picks the matching PNG from `Sources/PagerNotificationService/Avatars/`. The avatar list is mirrored in three places — keep them in sync when adding a new source:
1. `worker/src/index.ts` (`VALID_SOURCES`)
2. `Sources/PagerNotificationService/NotificationService.swift` (`NotificationSource`)
3. `Sources/Pager/HistoryView.swift` (`SourceAvatar.assetName`)

This requires the `com.apple.developer.usernotifications.communication` entitlement on the main app target only — the Service Extension does not need it (and Xcode does not expose the capability for extension targets). **No Apple approval form is needed** — it's a free capability — but `xcodebuild -allowProvisioningUpdates` cannot enable it via CLI alone. Open the project in Xcode once and add *Communication Notifications* capability to the **Pager** target via Signing & Capabilities; Xcode then registers it on the App ID and subsequent CLI builds succeed. If the entitlement is missing the extension still works — it falls back to a `UNNotificationAttachment` thumbnail.

## TestFlight

See [docs/testflight.md](docs/testflight.md) for the end-to-end distribution
workflow, export options, and troubleshooting notes. The first successful upload
used version `1.0.0`, build `202605011954`.

## Credentials

**1Password (Personal vault) is the source of truth for every secret.** A
Cloudflare Worker cannot resolve `op://` at the edge, so each Worker secret is
necessarily a *copy*; the 1Password item is the record of what was put there and
the only way to restore it. Item names are not evidence of contents — verify
before using one (see ハマりどころ below).

| Worker secret | Purpose | 1Password item (Personal) |
|---|---|---|
| `SHARED_SECRET` | Bearer auth between hooks and Worker | `Pager` (LOGIN) → `password`. `username` field = Worker URL |
| `ANTHROPIC_API_KEY` | Haiku one-line summary for the Watch/lock-screen banner | `Pager — Anthropic API Key` (API_CREDENTIAL) → `password` |
| `APNS_PRIVATE_KEY` | APNs ES256 push signing | `Pager — APNs Auth Key (SRH3669YH6)` (DOCUMENT) → `.p8` file |

Plaintext Worker vars live in `worker/wrangler.toml` and are not secrets:
`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_USE_SANDBOX`.
`Pager — Cloudflare & APNs Config` (SECURE_NOTE) holds account_id, KV namespace
id and bundle ids for reference only — no live credential resolves from it.
`worker/wrangler.toml` is committed; `credentials/AuthKey_*.p8` is gitignored.

- **Hook credentials resolve in three steps, in `hooks/pager-env.sh`:** the
  environment, then a mounted 1Password Environment, then the `op` CLI. All
  three hooks source this file, so there is one place to change.
  - The mount is the 1Password Environment named **Pager**, at
    `~/.claude/1p-mounts/pager.env` (override with `PAGER_ENV_MOUNT`). It is a
    FIFO, so reading it is ordinary file I/O — no biometric prompt, and it works
    from inside an agent sandbox.
  - **The mount exists for latency.** Measured 2026-08-07: the mount resolves
    both `PAGER_*` values in ~63ms, against ~1814ms per `op item get` — and the
    `op` tier issues two of them, so falling through costs ~3.6s. `notify-*.sh`
    are async and would only lag, but `permission-request.sh` is **synchronous**,
    so every permission prompt would stall for that.
  - A `timeout` guards the mount read, because a locked 1Password would
    otherwise block forever. With no mount and no `op`, resolution fails cleanly
    and the hooks skip with `exit 0` rather than sending an unauthenticated call.
- **`PAGER_SECRET` must not be put back into `~/.claude/settings.json`.** It was
  removed 2026-08-07: `env` there is exported into every subprocess Claude Code
  spawns, so one `env` dump puts the shared secret in a transcript permanently.
  Codex's `~/.codex/config.toml` copy was removed at the same time — its value
  had drifted and no longer matched the Worker, so codex-sourced notifications
  were silently failing auth until they started resolving from the mount.

- **`PAGER_SECRET` must not be put back into `~/.claude/settings.json`.** It was
  removed 2026-08-07: `env` there is exported into every subprocess Claude Code
  spawns, so one `env` dump puts the shared secret in a transcript permanently.
  Codex's `~/.codex/config.toml` copy was removed at the same time — its value
  had drifted and no longer matched the Worker, so codex-sourced notifications
  were silently failing auth until they started resolving from the mount.

Restore or rotate a Worker secret without the value passing through a shell
argument or a transcript:

```bash
# SHARED_SECRET
op read 'op://Personal/Pager/password' | wrangler secret put SHARED_SECRET

# ANTHROPIC_API_KEY — the item name contains an em dash, which op:// rejects,
# so resolve the item by id (see ハマりどころ)
op item get <id> --fields label=password --reveal | tr -d '\n' \
  | wrangler secret put ANTHROPIC_API_KEY

# APNs key
op read 'op://Personal/Pager — APNs Auth Key (SRH3669YH6)/AuthKey_SRH3669YH6.p8' \
  > credentials/AuthKey_SRH3669YH6.p8
```

`SHARED_SECRET` additionally exists as `PAGER_SECRET` in the 1Password
**Environment** named `Pager`, which is a separate copy feeding the hooks'
mount — editing the vault item does *not* update it. So the value lives in three
places and all three must move together. **Two copies is not a design flaw to
remove:** a Cloudflare Worker cannot resolve `op://` at the edge, so its secret
is necessarily a copy. The fix is naming one source of truth, which the table
above does — **when a local copy disagrees with `op://Personal/Pager/password`,
that copy is the stale one.**

Rotate in this order — vault item, then the Environment (Developer → View
Environments → Import .env file), then `wrangler secret put`. Doing the Worker
first takes notifications down while they are the only channel that would report
it.

A Worker secret cannot be read back. To find out which value the Worker actually
holds, use the 401/400 probe below — it answers without sending a push.
The Anthropic key has no such probe; the Worker degrades to `fallbackBanner()`
on any non-OK response, so a dead key costs the LLM-shortened banner but never a
notification. To tell whether the Worker's copy still works, send one real
notification and check whether the banner is summarized or mechanically
truncated — the Anthropic Console has no "last used" column, but the Cost column
moves for the key that was used.

## Environment Variables

- `PAGER_WORKER_URL` — Worker endpoint URL
- `PAGER_SECRET` — Shared secret for auth
- `PAGER_SANDBOX` — Optional. Force-overrides the per-token auto-detect by passing `sandbox: true|false` in the request body. Leave unset to let the worker auto-detect from the device token (recommended)
- `PAGER_LOG_DIR` — Optional override for hook log location (default `~/Library/Logs/Pager`)

## ハマりどころ（実体験）

- **秘密リファレンスの名前は中身の証拠にならない。使う前に実物で検証する。**
  `op://Personal/Pager API Key/password` は名前に反して Anthropic API キー
  (`sk-ant-…`) で、Worker の `SHARED_SECRET` ではなかった。名前だけを見て
  Environment に import した結果、`PAGER_SECRET` が重複し、危うく Worker の
  共有シークレットを Anthropic キーで上書きするところだった（全通知が停止する）。
  アイテムは `Pager — Anthropic API Key` に改名済み。**書く前に Worker へ投げて
  受理されるか見れば一手で分かった** — 実際そうしたら即座に判明した。
- **Worker の秘密が生きているかは 401/400 プローブで判定できる。通知は飛ばない。**
  `checkAuth` は全ルートの手前にあり、`/notify` は認証通過後・プッシュ送信前に
  `source` を検証する。だから不正な `source` を送れば、**401 = 認証失敗 /
  400 = 認証成功**として切り分けられ、iPhone は鳴らない。
  ```bash
  umask 077; CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
  printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$SECRET" > "$CFG"
  curl -sS -o /dev/null -w '%{http_code}' -X POST "$PAGER_WORKER_URL/notify" \
    --config "$CFG" -d '{"title":"probe","message":"probe","source":"__invalid__"}'
  ```
  秘密を `-H` で渡すと `argv` に載るので `--config` を使う。ローテーション後は
  新しい値が 400、古い値が 401 になることを両方確認する — 後者が失効の証明。
- **`bash -x` でフックをトレースすると `PAGER_SECRET` が平文で出る。**
  `pager-env.sh` はマウントから値を解決するので、トレースがその代入行を展開して
  しまう。Claude Code のトランスクリプト (`~/.claude/projects/**/*.jsonl`) は
  永続するため、これは取り消せない漏洩であり、ローテーション以外に復旧手段がない
  （2026-09-07 に実際に発生し、共有シークレットをローテーションした）。
  デバッグは `bash -x` ではなく、`sed -E 's/=.*/=<redacted>/'` や、値を出さずに
  真偽だけ出すスクリプトで行う。
- **`op://` リファレンスに em ダッシュ (`—`) を含むアイテム名は使えない。**
  `invalid character in secret reference` で失敗する。`op item list --format json`
  で id を引いて `op item get <id>` を使う。
