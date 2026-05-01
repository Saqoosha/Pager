#!/bin/bash
# Load Pager hook credentials from the environment, or fall back to 1Password.
# The "Pager" login item stores the current Worker URL and shared secret.

load_pager_env() {
  if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
    return 0
  fi

  command -v op >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local _op_timeout="${PAGER_OP_TIMEOUT:-10}"
  _op_get() {
    if command -v timeout >/dev/null 2>&1; then
      timeout "${_op_timeout}s" op item get "$@"
    else
      op item get "$@"
    fi
  }

  local login_item="${PAGER_1PASSWORD_LOGIN_ITEM:-ujd5nkrgzat5pa3jjqsyygm3ba}"
  if [ -z "${PAGER_WORKER_URL:-}" ]; then
    local _url
    _url=$(_op_get "$login_item" --fields username 2>/dev/null) || {
      printf 'pager-env: op item get %s username failed\n' "$login_item" >&2
    }
    [ -n "$_url" ] && { PAGER_WORKER_URL="$_url"; export PAGER_WORKER_URL; }
  fi

  if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
    return 0
  fi

  if [ -z "${PAGER_SECRET:-}" ]; then
    local _secret
    _secret=$(_op_get "$login_item" --fields password --reveal 2>/dev/null) || {
      printf 'pager-env: op item get %s password failed\n' "$login_item" >&2
    }
    [ -n "$_secret" ] && { PAGER_SECRET="$_secret"; export PAGER_SECRET; }
  fi

  if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
    return 0
  fi

  local item="${PAGER_1PASSWORD_CONFIG_ITEM:-wothihpxju73pb4qa4yx5wkg24}"
  local notes
  notes=$(_op_get "$item" --format json 2>/dev/null \
    | jq -r '.fields[]? | select(.id == "notesPlain") | .value // ""' 2>/dev/null) || {
    printf 'pager-env: op item get %s notes failed\n' "$item" >&2
    return 1
  }

  if [ -z "${PAGER_WORKER_URL:-}" ]; then
    local _url
    _url=$(printf '%s\n' "$notes" | grep -Eo 'https://[A-Za-z0-9./_-]*workers\.dev[A-Za-z0-9./_-]*' | head -n 1)
    [ -n "$_url" ] && { PAGER_WORKER_URL="$_url"; export PAGER_WORKER_URL; }
  fi

  [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]
}

load_pager_env
