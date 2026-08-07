#!/bin/bash
# Load Pager hook credentials, in order: the environment, a mounted 1Password
# Environment, then the "Pager" login item via the `op` CLI.

load_pager_env() {
  if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
    return 0
  fi

  # --- Source 2: a mounted 1Password Environment -----------------------------
  # The mount is a FIFO served by 1Password.app, so reading it is ordinary file
  # I/O — milliseconds, no biometric prompt, no IPC.
  #
  # This exists for latency, not just tidiness. Measured 2026-08-07 on this Mac:
  # a single `op item get` costs ~1814ms (5 runs, 1791-1840ms), and source 3
  # below issues TWO of them — URL then password — so falling through to `op`
  # costs ~3.6s per hook fire. notify-*.sh are async and would only lag, but
  # permission-request.sh is SYNCHRONOUS: every permission prompt would stall
  # for those 3.6s. The mount is what makes it viable to keep PAGER_SECRET out
  # of ~/.claude/settings.json, where it used to sit in plaintext and get
  # exported into every subprocess Claude Code spawned.
  #
  # `timeout` guards a locked 1Password, where the read would block forever.
  # Keep it short for the sake of the synchronous hook.
  local _mount="${PAGER_ENV_MOUNT:-$HOME/.claude/1p-mounts/pager.env}"
  if [ -r "$_mount" ]; then
    local _blob=""
    if command -v timeout >/dev/null 2>&1; then
      _blob=$(timeout "${PAGER_MOUNT_TIMEOUT:-3}" cat "$_mount" 2>/dev/null)
    else
      _blob=$(cat "$_mount" 2>/dev/null)
    fi

    # Pull one KEY=value out of the blob. Values may be quoted; strip one layer.
    _from_mount() {
      [ -n "$_blob" ] || return 1
      local _v
      _v=$(printf '%s\n' "$_blob" \
        | awk -v k="$1" -F= '$1==k {sub(/^[^=]*=/, ""); print; f=1; exit} END{exit !f}') || return 1
      case "$_v" in
        \"*\") _v="${_v#\"}"; _v="${_v%\"}" ;;
        \'*\') _v="${_v#\'}"; _v="${_v%\'}" ;;
      esac
      [ -n "$_v" ] || return 1
      printf '%s' "$_v"
    }

    if [ -z "${PAGER_WORKER_URL:-}" ]; then
      local _mu
      _mu=$(_from_mount PAGER_WORKER_URL) \
        && { PAGER_WORKER_URL="$_mu"; export PAGER_WORKER_URL; }
    fi
    if [ -z "${PAGER_SECRET:-}" ]; then
      local _ms
      _ms=$(_from_mount PAGER_SECRET) \
        && { PAGER_SECRET="$_ms"; export PAGER_SECRET; }
    fi

    if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
      return 0
    fi
  fi

  # --- Source 3: the `op` CLI ------------------------------------------------
  # Works in an interactive shell and on a fresh machine; expected to fail
  # inside an agent sandbox, which is why the mount above comes first.
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

# APNs sandbox toggle for local development.
# Set PAGER_SANDBOX=true to target the development APNs server
# (matching local Xcode builds). Leave unset for production.
PAGER_SANDBOX="${PAGER_SANDBOX:-false}"
export PAGER_SANDBOX
