# Multi-CLI Setup (Claude Code / Codex / Cursor)

`hooks/notify-stop.sh` is a single hook that handles Stop events from all three
CLIs. Pick the source with `--source <claude|codex|cursor>`; the iOS extension
picks the matching avatar and renders the notification Slack-style via Apple's
Communication Notifications API.

## Prerequisites

- `notify-stop.sh` reachable from each CLI — the canonical path used in the
  examples is `~/.claude/hooks/notify-stop.sh` (symlinked from this repo).
- Credentials — choose one:
  - **1Password (recommended):** store the Worker URL in the `username` field
    and the shared secret in the `password` field of a login item named
    `Pager`. The hooks source `pager-env.sh` automatically, which fetches
    credentials at runtime via `op item get` (requires the 1Password CLI and
    an unlocked vault). Override the item ID with `PAGER_1PASSWORD_LOGIN_ITEM`.
  - **Environment variables:** export `PAGER_WORKER_URL` and `PAGER_SECRET`
    in the shell the CLI launches (`~/.zshenv`, `~/.config/fish/config.fish`,
    etc.). Environment variables take precedence over 1Password when set.
- iOS app installed via Xcode with the *Communication Notifications* capability
  enabled on the App ID — see "One-time Xcode setup" below.
- For a TestFlight-installed app, deploy the Worker with
  `APNS_USE_SANDBOX = "false"` because TestFlight uses production APNs tokens.
  Local Xcode development builds use the sandbox endpoint.

## One-time Xcode setup

`com.apple.developer.usernotifications.communication` is a free capability
(no Apple approval form required), but `xcodebuild -allowProvisioningUpdates`
on the command line cannot enable it automatically. Do this once:

1. `xcodegen generate`
2. Open `Pager.xcodeproj` in Xcode.
3. Select the **Pager** target → *Signing & Capabilities* →
   `+ Capability` → **Communication Notifications**.
   *(Only the main app target. The Service Extension does not have a
   Communication Notifications capability — the entitlement on the host app
   is sufficient.)*
4. Xcode pushes the capability to the App ID in the Apple Developer Portal
   automatically. Subsequent CLI builds succeed.

If you skip this step the build fails with:
> Entitlement com.apple.developer.usernotifications.communication not found
> and could not be included in profile

Without the entitlement enabled, the extension falls back to a
`UNNotificationAttachment` thumbnail in the corner instead of the prominent
left-side avatar.

## Claude Code

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/notify-stop.sh" }
        ]
      }
    ]
  }
}
```

`--source` defaults to `claude`, so no extra flag is needed.

## Codex CLI

Codex hooks must opt in via the `codex_hooks` feature flag. Verified on Codex
CLI versions where `~/.codex/hooks.json` is loaded; the flag may become a
no-op once Codex hooks reach GA.

`~/.codex/config.toml`:

```toml
[features]
codex_hooks = true
```

`~/.codex/hooks.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify-stop.sh --source codex",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

Codex sends `cwd`, `transcript_path`, and `last_assistant_message` on stdin —
the same fields the Claude Code branch consumes. The transcript fallback uses
Claude's `.jsonl` shape, so if a Codex turn has an empty
`last_assistant_message`, the body will fall through to `Done`.

Codex review subagents return their final result as a JSON object — most
commonly `{findings[], overall_correctness, overall_explanation}`, sometimes
`{title, body}` or `{summary}`. `notify-stop.sh` runs `flatten_codex_json` on
the Codex payload before the shared `clean_text` pass, so the lock-screen
banner shows e.g. `2 findings: [P1] foo; [P2] bar` instead of raw
`{ "findings": [...]`. Plain-text payloads pass through untouched.

## Cursor (IDE Agent only)

Cursor 1.7+ exposes hooks for the in-IDE Agent / Composer chat. **The Cursor
CLI / background agent is not covered** — Cursor only fires Stop hooks for
interactive Agent sessions. The schema is still pre-1.0; check Cursor's docs
for breaking changes.

`~/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      {
        "command": "~/.claude/hooks/notify-stop.sh --source cursor",
        "timeout": 30
      }
    ]
  }
}
```

Cursor's stdin includes `status` (`completed` | `aborted` | `error`) and
`workspace_roots[]`. The hook also extracts the last assistant turn from
Cursor's JSONL transcript (Anthropic Messages shape:
`{role:"assistant", message:{content:[{type:"text", text:"…"}]}}`), so the
notification body shows the actual model response. If transcript parsing
yields nothing the body falls back to the status verb
(`Done` / `Aborted` / `Error`).

## Logs

Per-CLI hook activity is appended to
`~/Library/Logs/Pager/notify-stop.log` (override with
`PAGER_LOG_DIR`). One line per Stop event:

```
2026-04-27T06:55:31Z [claude] OK title=[myproj] Done msg=Refactored auth flow
2026-04-27T06:55:32Z [codex]  ERR curl exit=6 http=000 body= title=[myproj] Done msg=Pushed PR
2026-04-27T06:55:32Z [cursor] SKIP env PAGER_WORKER_URL or _SECRET unset (project=myproj)
```

Useful when investigating "why didn't I get a notification" after the fact —
Claude Code captures stderr in its own hook log, but Codex and Cursor route
hook stderr inconsistently. The log file is the one place all three converge.

Other layers worth knowing about:

| Layer | Where to look |
|---|---|
| Hook (this script) | `~/Library/Logs/Pager/notify-stop.log` |
| Worker | `wrangler tail` (live) or Cloudflare dashboard → Workers Logs |
| iOS Notification Service Extension | Mac Console.app → select device → filter `PagerNotificationService` |
| iOS app (per-notification history) | Tap any notification → opens the app's History view |

## Avatar assets

`Sources/PagerNotificationService/Avatars/` holds 256×256 PNGs extracted from
the locally installed Mac apps. Rebuild them after an upstream icon redesign:

```bash
./scripts/refresh-avatars.sh
```

The script reads each app's `CFBundleIconFile`, runs `iconutil`, and downscales
to 256×256 (the cap iOS uses for the Communication Notifications avatar slot).
