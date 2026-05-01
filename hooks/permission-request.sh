#!/bin/bash
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
PROJECT=$(echo "$INPUT" | jq -r '.cwd // "" | split("/") | last')
REQUEST_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Tool-specific human-readable preview. Falls back to compact JSON for unknown
# tools so we never lose information, just trim it. Truncation happens inside
# jq (character-aware) — `head -c` would slice UTF-8 mid-byte and break JSON.
TOOL_INPUT=$(echo "$INPUT" | jq -r --arg t "$TOOL_NAME" '
  .tool_input as $i |
  ( if   $t == "Bash"        then ($i.command // "")
    elif $t == "Read"        then ($i.file_path // "")
    elif $t == "Write"       then ($i.file_path // "")
    elif $t == "Edit"        then ($i.file_path // "")
    elif $t == "NotebookEdit" then ($i.notebook_path // "")
    elif $t == "Glob"        then (($i.pattern // "") + (if $i.path then "  in " + $i.path else "" end))
    elif $t == "Grep"        then (($i.pattern // "") + (if $i.path then "  in " + $i.path else "" end))
    elif $t == "WebFetch"    then ($i.url // "")
    elif $t == "WebSearch"   then ($i.query // "")
    elif $t == "Task"        then (($i.description // "") + (if $i.subagent_type then "  (" + $i.subagent_type + ")" else "" end))
    elif $t == "TodoWrite"   then (($i.todos // []) | map("• " + (.content // "")) | join("\n"))
    elif $t == "ExitPlanMode" then ($i.plan // "")
    elif $t == "AskUserQuestion" then
      (($i.questions // [])
       | to_entries
       | map(
           ((.value.header // ("Q" + ((.key + 1) | tostring))) + ": " + (.value.question // ""))
           + "\n"
           + (((.value.options // []) | map("• " + (.label // "")) | join("\n")))
         )
       | join("\n\n"))
    else ($i | tostring)
    end
  ) | if length > 800 then .[:800] + "…" else . end
')

TIMEOUT="${PAGER_PERMISSION_TIMEOUT:-120}"
case "$TIMEOUT" in
  ''|*[!0-9]*) TIMEOUT=120 ;;
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

LOG="${PAGER_LOG_DIR:-$HOME/Library/Logs/Pager}/permission-request.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$REQUEST_ID" "$*" >> "$LOG"; }
log "fired tool=$TOOL_NAME project=$PROJECT worker_set=$([ -n "$WORKER_URL" ] && echo y || echo n)"

if [ -z "$WORKER_URL" ] || [ -z "$SECRET" ]; then
  log "SKIP env unset"
  echo "WARNING: PAGER_WORKER_URL or PAGER_SECRET not set. Falling back to interactive prompt." >&2
  exit 0
fi

# Send request to worker
SEND_BODY=$(mktemp)
trap 'rm -f "$SEND_BODY"' EXIT
SEND_HTTP=$(curl -s --max-time 10 -o "$SEND_BODY" -w '%{http_code}' \
  -X POST "$WORKER_URL/request" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SECRET" \
  -d "$(jq -n --arg rid "$REQUEST_ID" --arg tn "$TOOL_NAME" --arg ti "$TOOL_INPUT" --arg p "$PROJECT" \
    '{requestId: $rid, toolName: $tn, toolInput: $ti, project: $p}')")
SEND_RESULT=$(cat "$SEND_BODY" 2>/dev/null)

# Check if send succeeded
if [ "$SEND_HTTP" != "200" ] || ! echo "$SEND_RESULT" | jq -e '.ok' > /dev/null 2>&1; then
  ERROR_DETAIL=$(echo "$SEND_RESULT" | jq -r '.error // "unknown error"' 2>/dev/null || echo "request failed")
  log "SEND failed: http=$SEND_HTTP err=$ERROR_DETAIL"
  echo "WARNING: Pager request failed (http=$SEND_HTTP): $ERROR_DETAIL. Falling back to interactive prompt." >&2
  exit 0
fi
log "SEND ok, polling..."

# Poll for response
ELAPSED=0
CONSECUTIVE_FAILURES=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  RESULT=$(curl -s --max-time 5 "$WORKER_URL/status/$REQUEST_ID" -H "Authorization: Bearer $SECRET")
  CURL_EXIT=$?

  if [ $CURL_EXIT -ne 0 ]; then
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    log "POLL curl_exit=$CURL_EXIT (consecutive=$CONSECUTIVE_FAILURES)"
    if [ $CONSECUTIVE_FAILURES -ge 3 ]; then
      log "POLL gave up after 3 consecutive failures"
      echo "WARNING: Pager polling failed 3 times consecutively. Falling back to interactive prompt." >&2
      exit 0
    fi
  else
    CONSECUTIVE_FAILURES=0
    STATUS=$(echo "$RESULT" | jq -r '.status // empty')

    if [ "$STATUS" = "expired" ]; then
      log "POLL got status=expired"
      echo "WARNING: Pager request expired on worker. Falling back to interactive prompt." >&2
      exit 0
    fi

    if [ "$STATUS" = "decided" ]; then
      DECISION=$(echo "$RESULT" | jq -r '.decision // empty')
      log "DECIDED $DECISION (after ${ELAPSED}s)"
      case "$DECISION" in
        allow|allowAlways)
          cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
EOF
          ;;
        deny)
          cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied via Pager"}}}
EOF
          ;;
        *)
          log "UNKNOWN decision value: '$DECISION'"
          echo "WARNING: Pager returned unknown decision '$DECISION'. Falling back to interactive prompt." >&2
          ;;
      esac
      exit 0
    fi
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# Timeout — fall through to normal permission prompt
log "TIMEOUT after ${TIMEOUT}s"
echo "WARNING: Pager timed out after ${TIMEOUT}s waiting for decision. Falling back to interactive prompt." >&2
exit 0
