#!/bin/bash
INPUT=$(cat)
TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
MSG=$(echo "$INPUT" | jq -r '.message // "Claude needs attention"' | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | sed -E 's/^#{1,6} //g' | sed 's/\*\*//g' | sed 's/[*`_~]//g' | sed -E 's/^[>-] //g' | sed 's/|//g' | sed -E 's/^[[:space:]]*---*[[:space:]]*$//g' | tr '\n' ' ' | sed -E 's/ +/ /g' | sed 's/^ //;s/ $//')
PROJECT=$(echo "$INPUT" | jq -r '.cwd | split("/") | last')

# Skip claude-mem's background observer sessions — their notifications are noise.
if [ "$PROJECT" = "observer-sessions" ]; then
  exit 0
fi

case "$TYPE" in
  permission_prompt)
    TITLE="[$PROJECT] Permission Needed"
    ;;
  idle_prompt)
    TITLE="[$PROJECT] Waiting"
    ;;
  *)
    TITLE="[$PROJECT] Notification"
    ;;
esac

WORKER_URL="${CANOPY_COMPANION_WORKER_URL}"
SECRET="${CANOPY_COMPANION_SECRET}"

curl -s --max-time 5 -X POST "$WORKER_URL/notify" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SECRET" \
  -d "$(jq -n --arg t "$TITLE" --arg m "$MSG" '{title: $t, message: $m}')"
