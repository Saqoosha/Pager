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
  #
  # 45s, not 3s. Opening the FIFO while 1Password is locked raises its own
  # "Developer Environment file mount auth" prompt, and no human types a master
  # password in three seconds -- so a 3s ceiling GUARANTEED this read failed on
  # every cold start and fell through to `op` below, which then raised a SECOND,
  # unrelated authorization. Two windows, two password entries, one hook fire.
  # Measured 2026-08-26 in 1Password_rCURRENT.log: prompts at 11:11:06 and
  # 11:11:09, and again at 11:23:04 and 11:23:08 -- 3.0s apart both times, i.e.
  # exactly this timeout. Waiting instead lets the human unlock once and the
  # still-open `cat` receive the value, so the notification is not lost either.
  # On an unlocked 1Password the read is ~63ms and the ceiling never applies.
  #
  # Why 45 and not 20: an unlock measured end to end on 2026-08-26 took 16s from
  # the window appearing to the value arriving (window 11:35:31, unlocked
  # 11:35:45, notify-stop OK 11:35:47) -- 80% of a 20s budget, which leaves no
  # room for a typo or a glance away. 45s is ~3x the observed figure and still
  # inside Claude Code's 60s default hook timeout.
  #
  # Raising it is close to free, because the ceiling is NOT what handles a user
  # who declines: denying the prompt makes the read return immediately at 0
  # bytes (measured 2026-08-26 -- denied 11:40:16.460, `cat` returned the same
  # second, rc 0, `timeout` never fired). So "not now" already exits fast, and
  # the ceiling only ever governs the cases with no producer and no answer at
  # all: 1Password quit, the destination disabled, or the window ignored. In
  # every one of those the notification was unsendable regardless.
  local _mount="${PAGER_ENV_MOUNT:-$HOME/.claude/1p-mounts/pager.env}"
  if [ -r "$_mount" ]; then
    local _blob=""
    if command -v timeout >/dev/null 2>&1; then
      _blob=$(timeout "${PAGER_MOUNT_TIMEOUT:-45}" cat "$_mount" 2>/dev/null)
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

    # A live mount is authoritative -- do NOT fall through to `op`.
    #
    # Reaching here with the FIFO present means 1Password is locked (or the read
    # was denied); it never means the values are missing from the Environment.
    # `op` would ask for the very same master password through a different
    # transport, so the only thing the fallback adds is a second prompt for a
    # secret the first prompt already covers. That is the actual cause of the
    # doubled unlock window, distinct from the two same-item `op` calls merged
    # on 2026-08-19 and the ungated notes read gated on 2026-08-23.
    #
    # Cost of returning early: this one notification is skipped (the hooks
    # already log SKIP and exit 0). The next fire reads the mount in ~63ms.
    if [ -p "$_mount" ]; then
      printf 'pager-env: mount %s yielded nothing (1Password locked?); not falling back to op\n' "$_mount" >&2
      return 1
    fi
  fi

  # --- Source 3: the `op` CLI ------------------------------------------------
  # Works in an interactive shell and on a fresh machine; expected to fail
  # inside an agent sandbox, which is why the mount above comes first.
  command -v op >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # 20s, not 10s: this call can be the one that raises 1Password's unlock
  # prompt, so the ceiling has to cover a human reaching for the approval.
  # Measured 2026-08-19: a cold `op item get --format json --reveal` took
  # 10.9s wall clock including the approval, which the old 10s ceiling would
  # have killed. Only ever reached on a cold start; the mount handles the
  # warm path in ~63ms.
  local _op_timeout="${PAGER_OP_TIMEOUT:-20}"
  _op_get() {
    if command -v timeout >/dev/null 2>&1; then
      timeout "${_op_timeout}s" op item get "$@"
    else
      op item get "$@"
    fi
  }

  local login_item="${PAGER_1PASSWORD_LOGIN_ITEM:-ujd5nkrgzat5pa3jjqsyygm3ba}"

  # ONE `op` invocation, never two.
  #
  # This used to be `--fields username` followed by `--fields password`. Each
  # `op` invocation authorizes independently, so on a cold start -- when
  # 1Password is still locked and the mount above therefore returns nothing --
  # a single hook fire asked the human to unlock TWICE. Observed 2026-08-19 at
  # first launch, and the file's own comment above had already noticed the
  # doubled latency without noticing the doubled prompt.
  #
  # `--format json --reveal` returns username and password from one call, so
  # the cold start costs one approval instead of two. Measured 2026-08-19 on
  # this Mac, steady state: `--fields <one>` ~1560/1572ms, `--format json
  # --reveal` ~1357/1383/1418ms -- so the single call is also slightly cheaper
  # than either of the two it replaces, taking Source 3 from ~3.1s to ~1.4s.
  # This is also what ~/.claude/rules/1password.md requires: never spread `op`
  # reads across separate invocations, batch them.
  if [ -z "${PAGER_WORKER_URL:-}" ] || [ -z "${PAGER_SECRET:-}" ]; then
    local _json
    _json=$(_op_get "$login_item" --format json --reveal 2>/dev/null) || {
      printf 'pager-env: op item get %s failed\n' "$login_item" >&2
    }
    if [ -n "${_json:-}" ]; then
      if [ -z "${PAGER_WORKER_URL:-}" ]; then
        local _url
        _url=$(printf '%s' "$_json" | jq -r '.fields[]? | select(.id == "username") | .value // empty' 2>/dev/null)
        [ -n "$_url" ] && { PAGER_WORKER_URL="$_url"; export PAGER_WORKER_URL; }
      fi
      if [ -z "${PAGER_SECRET:-}" ]; then
        local _secret
        _secret=$(printf '%s' "$_json" | jq -r '.fields[]? | select(.id == "password") | .value // empty' 2>/dev/null)
        [ -n "$_secret" ] && { PAGER_SECRET="$_secret"; export PAGER_SECRET; }
      fi
    fi
  fi

  if [ -n "${PAGER_WORKER_URL:-}" ] && [ -n "${PAGER_SECRET:-}" ]; then
    return 0
  fi

  # SECOND `op` invocation — gated, because it is a second authorization.
  #
  # The notes fallback below can only ever supply PAGER_WORKER_URL; there is no
  # secret in those notes. So when PAGER_SECRET is still empty -- which is the
  # case whenever the login-item read above failed outright -- this call is
  # provably useless: the final check needs both values and will fail no matter
  # what the notes contain. Running it anyway cost one extra 1Password approval
  # prompt on EVERY hook fire, which is why a locked 1Password made Pager ask
  # twice per notification. Observed 2026-08-23 in the VDGS session log: six
  # Stop-hook fires, each logging `op item get <login> failed` and then silently
  # issuing this second call.
  #
  # Related but distinct from the 2026-08-19 fix above, which merged two
  # `--fields` reads of the SAME item into one. This is a different item.
  [ -n "${PAGER_SECRET:-}" ] || return 1

  local item="${PAGER_1PASSWORD_CONFIG_ITEM:-wothihpxju73pb4qa4yx5wkg24}"
  local notes _notes_rc
  # `_op_get | jq` would report jq's status, not op's, so an `op` failure used
  # to slip through as a silent empty read. Check the producer explicitly.
  notes=$(_op_get "$item" --format json 2>/dev/null)
  _notes_rc=$?
  if [ $_notes_rc -ne 0 ]; then
    printf 'pager-env: op item get %s notes failed\n' "$item" >&2
    return 1
  fi
  notes=$(printf '%s' "$notes" \
    | jq -r '.fields[]? | select(.id == "notesPlain") | .value // ""' 2>/dev/null)

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
