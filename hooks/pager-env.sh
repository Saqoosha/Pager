#!/bin/bash
# Load Pager hook credentials from the environment, or fall back to 1Password.
# The "Pager" login item stores the current Worker URL and shared secret.

load_pager_env() {
  if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
    return 0
  fi

  command -v op >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local login_item="${PAGER_1PASSWORD_LOGIN_ITEM:-ujd5nkrgzat5pa3jjqsyygm3ba}"
  if [ -z "${PAGER_WORKER_URL:-}" ]; then
    local _url
    _url=$(op item get "$login_item" --fields username 2>/dev/null)
    [ -n "$_url" ] && { PAGER_WORKER_URL="$_url"; export PAGER_WORKER_URL; }
  fi

  if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
    return 0
  fi

  if [ -z "${PAGER_SECRET:-}" ]; then
    local _secret
    _secret=$(op item get "$login_item" --fields password --reveal 2>/dev/null)
    [ -n "$_secret" ] && { PAGER_SECRET="$_secret"; export PAGER_SECRET; }
  fi

  if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
    return 0
  fi

  local item="${PAGER_1PASSWORD_CONFIG_ITEM:-wothihpxju73pb4qa4yx5wkg24}"
  local notes
  notes=$(op item get "$item" --format json 2>/dev/null \
    | jq -r '.fields[]? | select(.id == "notesPlain") | .value // ""' 2>/dev/null) || return 1

  if [ -z "${PAGER_WORKER_URL:-}" ]; then
    local _url
    _url=$(printf '%s\n' "$notes" | grep -Eo 'https://[A-Za-z0-9./_-]*workers\.dev[A-Za-z0-9./_-]*' | head -n 1)
    [ -n "$_url" ] && { PAGER_WORKER_URL="$_url"; export PAGER_WORKER_URL; }
  fi

  [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]
}

load_pager_env
