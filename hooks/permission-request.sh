#!/bin/bash
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input | tostring' | head -c 500)
PROJECT=$(echo "$INPUT" | jq -r '.cwd // "" | split("/") | last')
REQUEST_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

WORKER_URL="${CANOPY_COMPANION_WORKER_URL}"
SECRET="${CANOPY_COMPANION_SECRET}"
TIMEOUT=120

if [ -z "$WORKER_URL" ] || [ -z "$SECRET" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

# Send request to worker
SEND_RESULT=$(curl -s -X POST "$WORKER_URL/request" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SECRET" \
  -d "$(jq -n --arg rid "$REQUEST_ID" --arg tn "$TOOL_NAME" --arg ti "$TOOL_INPUT" --arg p "$PROJECT" \
    '{requestId: $rid, toolName: $tn, toolInput: $ti, project: $p}')")

# Check if send succeeded
if ! echo "$SEND_RESULT" | jq -e '.ok' > /dev/null 2>&1; then
  # Failed to send — fall through to normal permission prompt
  exit 0
fi

# Poll for response
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  RESULT=$(curl -s "$WORKER_URL/status/$REQUEST_ID" -H "Authorization: Bearer $SECRET")
  DECISION=$(echo "$RESULT" | jq -r '.decision // empty')

  if [ -n "$DECISION" ]; then
    case "$DECISION" in
      allow)
        cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
EOF
        ;;
      allowAlways)
        cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allowAlways"}}
EOF
        ;;
      deny)
        cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied via Canopy Companion"}}
EOF
        ;;
    esac
    exit 0
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# Timeout — fall through to normal permission prompt
exit 0
