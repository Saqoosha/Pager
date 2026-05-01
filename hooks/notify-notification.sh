#!/bin/bash
INPUT=$(cat)
TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
MSG=$(echo "$INPUT" | jq -r '.message // "Claude needs attention"' | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | sed -E 's/^#{1,6} //g' | sed 's/\*\*//g' | sed 's/[*`_~]//g' | sed -E 's/^[>-] //g' | sed 's/|//g' | sed -E 's/^[[:space:]]*---*[[:space:]]*$//g' | tr '\n' ' ' | sed -E 's/ +/ /g' | sed 's/^ //;s/ $//')
PROJECT=$(echo "$INPUT" | jq -r '.cwd | split("/") | last')

# Skip claude-mem's background observer sessions — their notifications are noise.
if [ "$PROJECT" = "observer-sessions" ]; then
  exit 0
fi

# permission-request.sh already sends a richer notification (with Allow / Deny
# action buttons) for permission prompts — skip the duplicate here.
if [ "$TYPE" = "permission_prompt" ]; then
  exit 0
fi

case "$TYPE" in
  idle_prompt)
    TITLE="[$PROJECT] Waiting"
    ;;
  *)
    TITLE="[$PROJECT] Notification"
    ;;
esac

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
if [ ! -f "$SCRIPT_DIR/pager-env.sh" ] && command -v realpath >/dev/null 2>&1; then
  SCRIPT_REALPATH="$(realpath "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$SCRIPT_SOURCE")"
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_REALPATH")" && pwd)"
fi
if [ -f "$SCRIPT_DIR/pager-env.sh" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/pager-env.sh"
fi
WORKER_URL="${PAGER_WORKER_URL}"
SECRET="${PAGER_SECRET}"

LOG_DIR="${PAGER_LOG_DIR:-$HOME/Library/Logs/Pager}"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_FILE="$LOG_DIR/notify-notification.log"
log() { ( printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" ) 2>/dev/null; }

if [ -z "$WORKER_URL" ] || [ -z "$SECRET" ]; then
  echo "notify-notification: PAGER_WORKER_URL or _SECRET not set; skipping" >&2
  log "SKIP env PAGER_WORKER_URL or _SECRET unset (project=${PROJECT:-?} type=${TYPE:-?})"
  exit 0
fi

HTTP_BODY=$(mktemp)
trap 'rm -f "$HTTP_BODY"' EXIT
HTTP_CODE=$(curl -sS --max-time 5 -o "$HTTP_BODY" -w '%{http_code}' \
  -X POST "$WORKER_URL/notify" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SECRET" \
  -d "$(jq -n --arg t "$TITLE" --arg m "$MSG" '{title: $t, message: $m, source: "claude"}')")
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ] || [ "$HTTP_CODE" != "200" ]; then
  body=$(cat "$HTTP_BODY" 2>/dev/null)
  echo "notify-notification: curl exit=$CURL_EXIT http=$HTTP_CODE body=$body" >&2
  log "ERR curl exit=$CURL_EXIT http=$HTTP_CODE body=$body title=$TITLE"
else
  log "OK title=$TITLE msg=$(printf %s "$MSG" | head -c 80)"
fi
