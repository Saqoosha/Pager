#!/bin/bash
# Re-extract per-CLI sender avatars from the locally installed Mac apps and
# overwrite the bundled PNGs the iOS extension uses for Communication
# Notifications. Run after a Cursor/Codex/Claude app upgrade if their icons
# changed and you want the on-device avatar to match.
#
# Reads CFBundleIconFile from each app's Info.plist rather than the first .icns
# that `find` returns — Cursor's Resources directory ships per-language icons
# (javascript.icns, c.icns, …) that look very wrong on a notification.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$REPO_ROOT/Sources/CanopyNotificationService/Avatars"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

extract() {
  local app="$1"
  local out_name="$2"
  local plist="/Applications/$app.app/Contents/Info.plist"
  if [ ! -f "$plist" ]; then
    echo "refresh-avatars: /Applications/$app.app missing — skipping" >&2
    return 0
  fi
  local icon
  icon=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$plist" 2>/dev/null || true)
  if [ -z "$icon" ]; then
    echo "refresh-avatars: $app has no CFBundleIconFile — skipping" >&2
    return 0
  fi
  case "$icon" in *.icns) ;; *) icon="$icon.icns" ;; esac
  local icns="/Applications/$app.app/Contents/Resources/$icon"
  if [ ! -f "$icns" ]; then
    echo "refresh-avatars: $icns missing — skipping" >&2
    return 0
  fi
  iconutil -c iconset -o "$TMP/$app.iconset" "$icns"
  local picked=""
  for size in icon_512x512@2x.png icon_512x512.png icon_256x256@2x.png icon_256x256.png; do
    if [ -f "$TMP/$app.iconset/$size" ]; then
      picked="$TMP/$app.iconset/$size"
      break
    fi
  done
  if [ -z "$picked" ]; then
    echo "refresh-avatars: $app has no usable size — skipping" >&2
    return 0
  fi
  # Downscale to 256x256 — that's the cap iOS uses for the avatar slot, and
  # shipping 1024x1024 wastes ~700 KB per image inside the extension bundle
  # (which has a 24 MB memory limit at runtime).
  sips -Z 256 "$picked" --out "$OUT/$out_name" >/dev/null
  echo "refresh-avatars: $out_name <- $picked"
}

extract Claude claude.png
extract Codex  codex.png
extract Cursor cursor.png
