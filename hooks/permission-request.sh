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
  echo "WARNING: CANOPY_COMPANION_WORKER_URL or CANOPY_COMPANION_SECRET not set. Falling back to interactive prompt." >&2
  exit 0
fi

# Send request to worker
SEND_RESULT=$(curl -s --max-time 10 -X POST "$WORKER_URL/request" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SECRET" \
  -d "$(jq -n --arg rid "$REQUEST_ID" --arg tn "$TOOL_NAME" --arg ti "$TOOL_INPUT" --arg p "$PROJECT" \
    '{requestId: $rid, toolName: $tn, toolInput: $ti, project: $p}')")

# Check if send succeeded
if ! echo "$SEND_RESULT" | jq -e '.ok' > /dev/null 2>&1; then
  ERROR_DETAIL=$(echo "$SEND_RESULT" | jq -r '.error // "unknown error"' 2>/dev/null || echo "request failed")
  echo "WARNING: Canopy Companion request failed: $ERROR_DETAIL. Falling back to interactive prompt." >&2
  exit 0
fi

# Poll for response
ELAPSED=0
CONSECUTIVE_FAILURES=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  RESULT=$(curl -s --max-time 5 "$WORKER_URL/status/$REQUEST_ID" -H "Authorization: Bearer $SECRET")
  CURL_EXIT=$?

  if [ $CURL_EXIT -ne 0 ]; then
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    if [ $CONSECUTIVE_FAILURES -ge 3 ]; then
      echo "WARNING: Canopy Companion polling failed 3 times consecutively. Falling back to interactive prompt." >&2
      exit 0
    fi
  else
    CONSECUTIVE_FAILURES=0
    STATUS=$(echo "$RESULT" | jq -r '.status // empty')

    if [ "$STATUS" = "decided" ]; then
      DECISION=$(echo "$RESULT" | jq -r '.decision // empty')
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
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# Timeout — fall through to normal permission prompt
echo "WARNING: Canopy Companion timed out after ${TIMEOUT}s waiting for decision. Falling back to interactive prompt." >&2
exit 0
