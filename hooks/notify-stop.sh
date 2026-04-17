#!/bin/bash
INPUT=$(cat)
PROJECT=$(echo "$INPUT" | jq -r '.cwd | split("/") | last')

# Skip claude-mem's background observer sessions — their notifications are noise.
if [ "$PROJECT" = "observer-sessions" ]; then
  exit 0
fi

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
MSG=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
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
    MSG=$(jq -rs '[.[] | select(.type == "assistant") | .message.content | if type == "string" then [{type: "text", text: .}] else (. // []) end | map(select(.type == "text") | .text) | map(select(. != "No response requested.")) | join(" ")] | map(select(. != "")) | last // ""' "$TRANSCRIPT" 2>/dev/null \
      | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | sed -E 's/^#{1,6} //g' | sed 's/\*\*//g' | sed 's/[*`_~]//g' | sed -E 's/^[>-] //g' | sed 's/|//g' | sed -E 's/^[[:space:]]*---*[[:space:]]*$//g' | tr '\n' ' ' | sed -E 's/ +/ /g' | sed 's/^ //;s/ $//' | cut -c1-200)
  fi
fi

[ -z "$MSG" ] && MSG="Done"

WORKER_URL="${CANOPY_COMPANION_WORKER_URL}"
SECRET="${CANOPY_COMPANION_SECRET}"

curl -s --max-time 5 -X POST "$WORKER_URL/notify" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SECRET" \
  -d "$(jq -n --arg t "[$PROJECT] Done" --arg m "$MSG" '{title: $t, message: $m}')"
