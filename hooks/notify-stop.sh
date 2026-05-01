#!/bin/bash
# Stop hook for Claude Code, Codex, and Cursor. See docs/multi-cli-setup.md.

SOURCE="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE="${2:-claude}"
      shift
      [ $# -gt 0 ] && shift
      ;;
    *) shift ;;
  esac
done

# Persistent log so failures from Codex/Cursor (whose stderr handling varies)
# can be diagnosed after the fact. Claude Code already captures stderr in its
# own hook log, so this is mostly a belt-and-braces for the other two.
LOG_DIR="${PAGER_LOG_DIR:-$HOME/Library/Logs/Pager}"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_FILE="$LOG_DIR/notify-stop.log"
log() {
  # Subshell wrap so bash's redirect-open errors (e.g. no $HOME) don't leak to
  # the caller's stderr — logging is best-effort.
  ( printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SOURCE" "$*" >> "$LOG_FILE" ) 2>/dev/null
}

case "$SOURCE" in
  claude|codex|cursor) ;;
  *)
    msg="unknown --source '$SOURCE'; falling back to claude"
    echo "notify-stop: $msg" >&2
    log "WARN $msg"
    SOURCE="claude"
    ;;
esac

# Cursor invokes the `claude` CLI internally for some agent operations, which
# in turn fires Claude Code's Stop hook. Without this guard the user gets two
# notifications per Cursor agent run — one for Claude's nested turn, one for
# Cursor's outer turn. Two ways to detect it:
#   1. Cursor's hook env (CURSOR_* vars) — only set when claude is invoked
#      inside a Cursor hook command.
#   2. Process ancestry — set when claude is invoked anywhere under Cursor.app.
# Either signal means "Cursor's own hook will already fire with --source cursor",
# so suppress the nested Claude notification.
running_under_cursor() {
  if [ -n "${CURSOR_PROJECT_DIR:-}" ] || [ -n "${CURSOR_VERSION:-}" ] || [ -n "${CURSOR_TRACE_ID:-}" ]; then
    return 0
  fi
  local pid=$PPID
  for _ in 1 2 3 4 5 6 7 8; do
    [ -z "$pid" ] || [ "$pid" -le 1 ] && return 1
    local pname
    pname=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$pname" in
      *Cursor*|*cursor*) return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}
if [ "$SOURCE" = "claude" ] && running_under_cursor; then
  log "SKIP claude under Cursor (PPID chain)"
  exit 0
fi

INPUT=$(cat)

clean_text() {
  sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    | sed -E 's/^#{1,6} //g' \
    | sed 's/\*\*//g' \
    | sed 's/[*`_~]//g' \
    | sed -E 's/^[>-] //g' \
    | sed 's/|//g' \
    | sed -E 's/^[[:space:]]*---*[[:space:]]*$//g' \
    | tr '\n' ' ' \
    | sed -E 's/ +/ /g' \
    | sed 's/^ //;s/ $//' \
    | jq -Rrs '.[:200]'
}

# Codex review subagents return their final result as a JSON object — most
# commonly {findings[], overall_correctness, overall_explanation}, sometimes
# {title, body} or {summary}. Without flattening, that JSON arrives verbatim
# on the lock screen as `{ "findings": [...]`. Detect any leading `{` or `[`,
# extract a readable summary, and fall back to the raw payload only when no
# known field is populated. Currently invoked only for source=codex (see the
# dispatch in the codex|claude case branch below).
flatten_codex_json() {
  local raw="$1"
  # Trim leading whitespace including newlines — `sed -E '^[[:space:]]+'` is
  # line-oriented and silently misses payloads that start with "\n{...".
  local stripped="${raw#"${raw%%[![:space:]]*}"}"
  case "${stripped:0:1}" in
    '{'|'[') ;;
    *) printf '%s' "$raw"; return ;;
  esac
  local rendered
  rendered=$(printf '%s' "$raw" | jq -r '
    def render_findings(fs):
      (fs | length) as $n
      | if $n == 0 then ""
        else "\($n) finding\(if $n == 1 then "" else "s" end): "
             + ([fs[]? | (.title // .summary // "untitled") | tostring] | join("; "))
        end;
    if type == "object" then
      (if (.findings | type) == "array" then render_findings(.findings) else "" end) as $f
      | ((.title // "") | tostring) as $t
      | ((.summary // "") | tostring) as $s
      | ((.body // "") | tostring) as $b
      | ((.overall_explanation // .overallexplanation // "") | tostring) as $oe
      | ((.overall_correctness // .overallcorrectness // "") | tostring) as $oc
      | if $f != "" then $f
        elif $t != "" then $t + (if $b != "" then ": " + $b else "" end)
        elif $s != "" then $s
        elif $oe != "" then $oe
        elif $oc != "" then $oc
        else "" end
    elif type == "array" then render_findings(.)
    else "" end
  ' 2>/dev/null)
  # jq prints literal "null" when the filter resolves to null; treat as empty.
  [ "$rendered" = "null" ] && rendered=""
  if [ -n "$rendered" ]; then
    printf '%s' "$rendered"
  else
    printf '%s' "$raw"
  fi
}

# Filter values that mean "the model produced no real assistant text" — these
# show up in both the Claude Code transcript and the Codex `last_assistant_message`
# payload when the turn was a no-op (e.g. response-not-requested cases). Treating
# them as empty makes the body fall through to the `Done` default.
is_placeholder_message() {
  case "$1" in
    ""|null|"No response requested.") return 0 ;;
    *) return 1 ;;
  esac
}

TITLE_VERB="Done"

case "$SOURCE" in
  cursor)
    PROJECT=$(echo "$INPUT" | jq -r '(.workspace_roots // [])[0] // "" | split("/") | last')
    if [ "$PROJECT" = "observer-sessions" ]; then
      exit 0
    fi
    STATUS=$(echo "$INPUT" | jq -r '.status // "unknown"')
    case "$STATUS" in
      completed) TITLE_VERB="Done" ;;
      aborted)   TITLE_VERB="Aborted" ;;
      error)     TITLE_VERB="Error" ;;
      unknown)   TITLE_VERB="Done?" ;;
      *)         TITLE_VERB="$STATUS" ;;
    esac
    TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
    MSG=""
    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      # Cursor's agent transcript is JSONL with the Anthropic Messages shape:
      # `{"role": "assistant"|"user", "message": {"content": [{"type":"text","text":"..."}, ...]}}`.
      # We pull the text blocks from the last assistant turn — schema-locked,
      # so it doesn't leak arbitrary internals like the earlier `.. | strings`
      # approach did.
      MSG=$(jq -rs '
        [.[] | select(.role == "assistant")
             | .message.content[]?
             | select(.type == "text")
             | .text]
        | last // ""
      ' "$TRANSCRIPT" 2>/dev/null | clean_text)
    fi
    is_placeholder_message "$MSG" && MSG=""
    [ -z "$MSG" ] && MSG="$TITLE_VERB"
    ;;

  codex|claude)
    PROJECT=$(echo "$INPUT" | jq -r '.cwd // "" | split("/") | last')
    if [ "$PROJECT" = "observer-sessions" ]; then
      exit 0
    fi
    TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
    LAST_FROM_PAYLOAD=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')
    MSG=""
    if ! is_placeholder_message "$LAST_FROM_PAYLOAD"; then
      if [ "$SOURCE" = "codex" ]; then
        LAST_FROM_PAYLOAD=$(flatten_codex_json "$LAST_FROM_PAYLOAD")
      fi
      MSG=$(printf '%s' "$LAST_FROM_PAYLOAD" | clean_text)
    elif [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      # Stop can fire before the final turn's text lands on disk. A completed turn
      # always ends with an assistant entry containing a text block, so poll briefly
      # until that invariant holds before parsing.
      DEADLINE=$(( $(date +%s) + 2 ))
      HAS_TEXT=false
      while :; do
        HAS_TEXT=$(jq -rs '(([.[] | select(.type == "assistant")] | last) // {}) | .message.content | if type == "string" then . != "" elif type == "array" then any(.type == "text") else false end' "$TRANSCRIPT" 2>/dev/null)
        [ "$HAS_TEXT" = "true" ] && break
        [ "$(date +%s)" -ge "$DEADLINE" ] && break
        sleep 0.15
      done
      if [ "$HAS_TEXT" = "true" ]; then
        MSG=$(jq -rs '[.[] | select(.type == "assistant") | .message.content | if type == "string" then [{type: "text", text: .}] else (. // []) end | map(select(.type == "text") | .text) | map(select(. != "No response requested.")) | join(" ")] | map(select(. != "")) | last // ""' "$TRANSCRIPT" 2>/dev/null | clean_text)
      fi
    fi
    is_placeholder_message "$MSG" && MSG=""
    [ -z "$MSG" ] && MSG="Done"
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

if [ -z "$WORKER_URL" ] || [ -z "$SECRET" ]; then
  echo "notify-stop: PAGER_WORKER_URL or _SECRET not set; skipping" >&2
  log "SKIP env PAGER_WORKER_URL or _SECRET unset (project=${PROJECT:-?})"
  exit 0
fi

HTTP_BODY=$(mktemp)
trap 'rm -f "$HTTP_BODY"' EXIT
HTTP_CODE=$(curl -sS --max-time 5 -o "$HTTP_BODY" -w '%{http_code}' \
  -X POST "$WORKER_URL/notify" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SECRET" \
  -d "$(jq -n --arg t "[$PROJECT] $TITLE_VERB" --arg m "$MSG" --arg s "$SOURCE" \
        '{title: $t, message: $m, source: $s}')")
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ] || [ "$HTTP_CODE" != "200" ]; then
  body=$(cat "$HTTP_BODY" 2>/dev/null)
  echo "notify-stop: curl exit=$CURL_EXIT http=$HTTP_CODE body=$body" >&2
  log "ERR curl exit=$CURL_EXIT http=$HTTP_CODE body=$body title=[$PROJECT] $TITLE_VERB msg=$(printf %s "$MSG" | head -c 80)"
else
  log "OK title=[$PROJECT] $TITLE_VERB msg=$(printf %s "$MSG" | head -c 80)"
fi
