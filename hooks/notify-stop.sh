#!/bin/bash
INPUT=$(cat)
PROJECT=$(echo "$INPUT" | jq -r '.cwd | split("/") | last')

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
MSG=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  MSG=$(jq -rs '[.[] | select(.type == "assistant") | .message.content | map(select(.type == "text") | .text) | join(" ")] | map(select(. != "")) | last // ""' "$TRANSCRIPT" \
    | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | sed -E 's/^#{1,6} //g' | sed 's/\*\*//g' | sed 's/[*`_~]//g' | sed -E 's/^[>-] //g' | sed 's/|//g' | sed -E 's/^[[:space:]]*---*[[:space:]]*$//g' | tr '\n' ' ' | sed -E 's/ +/ /g' | sed 's/^ //;s/ $//' | cut -c1-200)
fi

[ -z "$MSG" ] && MSG="Done"

WORKER_URL="${CANOPY_COMPANION_WORKER_URL}"
SECRET="${CANOPY_COMPANION_SECRET}"

curl -s --max-time 5 -X POST "$WORKER_URL/notify" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SECRET" \
  -d "$(jq -n --arg t "[$PROJECT] Done" --arg m "$MSG" '{title: $t, message: $m}')"
