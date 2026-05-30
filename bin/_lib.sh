# _lib.sh — shared helpers sourced by backlog-infra/bin scripts.
# shellcheck shell=bash  # sourced, never executed — declare the dialect for SC2148.
# Source this at the top of each script (after set -euo pipefail):
#   LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$LIB_DIR/_lib.sh"

# Human-readable age string from seconds-since-epoch diff.
fmt_age() {
  local d=$1
  if   (( d < 60 ));    then printf '%ds ago' "$d"
  elif (( d < 3600 ));  then printf '%dm ago' $((d/60))
  elif (( d < 86400 )); then printf '%dh ago' $((d/3600))
  else                       printf '%dd ago' $((d/86400))
  fi
}

# Human-readable token count (abbreviates thousands as "k", millions as "M").
fmt_tok() {
  local n=$1
  if   (( n < 1000 ));    then printf '%d' "$n"
  elif (( n < 1000000 )); then awk -v n=$n 'BEGIN{printf "%.1fk", n/1000}'
  else                         awk -v n=$n 'BEGIN{printf "%.1fM", n/1000000}'
  fi
}

# XML-escape a string for safe interpolation into a plist heredoc.
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

# Check SSH connectivity to GitHub. Critical for cloning, pulling, and pushing.
# $1 = timeout in seconds (default 5). Returns 0 if healthy, non-zero if broken.
check_github_ssh() {
  local timeout="${1:-5}"
  local out
  out="$(ssh -o ConnectTimeout="$timeout" -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)" || true
  if echo "$out" | grep -qi "successfully authenticated"; then
    return 0
  fi
  return 1
}

# Diagnostic helper: if SSH to GitHub is broken, print actionable steps and
# return 1. Callers use this before operations that need GitHub access, passing
# the command name for the error header.
need_github_ssh() {
  local caller="${1:-$(basename "$0")}"
  if check_github_ssh; then
    return 0
  fi
  echo >&2
  echo "================================================================================" >&2
  echo "  SSH TO GITHUB IS BROKEN" >&2
  echo "  $caller requires SSH access to GitHub." >&2
  echo "================================================================================" >&2
  echo >&2
  echo "  Quick fix:" >&2
  echo "    1. Generate a key (if you don't have one):" >&2
  echo "       ssh-keygen -t ed25519 -C \"your-email@example.com\"" >&2
  echo >&2
  echo "    2. Start the SSH agent and add the key:" >&2
  echo "       eval \"\$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519" >&2
  echo >&2
  echo "    3. Copy the public key:" >&2
  echo "       pbcopy < ~/.ssh/id_ed25519.pub" >&2
  echo >&2
  echo "    4. Add it to GitHub:" >&2
  echo "       https://github.com/settings/ssh" >&2
  echo >&2
  echo "    5. Verify:" >&2
  echo "       ssh -T git@github.com" >&2
  echo >&2
  echo "================================================================================" >&2
  return 1
}

# --- Secret-scanning pre-push gate (W2; docs/secret-scan.md) ---
# Shared by the DRIVER (backlog-agent: ensure_prepush_hook + Guard 5) and the CLI
# (backlog-agents: install-hooks + doctor) so the version, marker, and hook stub
# have ONE definition. Bump PREPUSH_HOOK_VERSION when the stub changes — the next
# tick / `install-hooks` rewrites every clone's hook; doctor flags stale ones.
PREPUSH_HOOK_VERSION="1"
PREPUSH_HOOK_MARKER="backlog secret-scan pre-push gate"

# Emit the pre-push hook stub to stdout. $1 = absolute path to backlog-secret-scan.
# Tiny on purpose: it execs the standalone scanner (the regex set has ONE home).
# Fail-OPEN if the scanner can't be found (don't wedge a human's push); the
# scanner itself fails CLOSED on an actual secret (exit 1 -> git aborts the push).
prepush_hook_body() {
  local scanner="$1"
  cat <<EOF
#!/usr/bin/env bash
# ${PREPUSH_HOOK_MARKER} (version ${PREPUSH_HOOK_VERSION}) — auto-installed by backlog-agent; do not edit.
# Rejects a push (exit 1) if a commit being pushed adds a secret. docs/secret-scan.md.
SCANNER="${scanner}"
[[ -x "\$SCANNER" ]] && exec "\$SCANNER" --prepush "\$@"
command -v backlog-secret-scan >/dev/null 2>&1 && exec backlog-secret-scan --prepush "\$@"
echo "backlog secret-scan: scanner not found on PATH; allowing push (fail-open)" >&2
exit 0
EOF
}

# True if a pre-push hook file should be treated as a FOREIGN user hook we must
# not clobber: it exists, is NON-EMPTY, and lacks our marker. An empty (0-byte)
# or missing file is NOT foreign — it's a no-op git ignores, safe to overwrite.
# $1 = path to the hook file.
prepush_hook_is_foreign() {
  local hook="$1"
  [[ -s "$hook" ]] || return 1                      # missing/empty ⇒ not foreign
  grep -q "$PREPUSH_HOOK_MARKER" "$hook" 2>/dev/null && return 1   # ours ⇒ not foreign
  return 0
}

# True if the hook at $1 is ours AND current-version (no rewrite needed).
prepush_hook_is_current() {
  local hook="$1"
  [[ -s "$hook" ]] || return 1
  grep -q "${PREPUSH_HOOK_MARKER} (version ${PREPUSH_HOOK_VERSION})" "$hook" 2>/dev/null
}

# --- Outbound notify channel (W2; docs/dead-mans-switch.md, docs/fleet-digest.md) ---
# ONE shared sender for every surfacing primitive — the DRIVER's alerts
# (cooldown, dead-man's-switch, budget cap, circuit-breaker trip) AND the CLI's
# digest. Reads the canonical config ~/.claude/agent-notify.json (override with
# $NOTIFY_CONFIG): "slack_webhook_url" / "email" / "telegram_bot_token" +
# "telegram_chat_id" / "local_notify". jq-free (grep/sed extract over our own
# controlled keys). Every transport is best-effort + backgrounded so a slow/dead
# endpoint can never block or abort a tick; an empty config is a silent no-op.
# Usage: notify_send "<title>" "<body>"  (title = Slack/Telegram prefix + email subject).
notify_send() {
  local title="${1:-backlog-agent}" body="${2:-}"
  local cfg="${NOTIFY_CONFIG:-$HOME/.claude/agent-notify.json}"
  [[ -n "$body" ]] || return 0
  [[ -f "$cfg" ]] || return 0
  local slack_url email local_notify tg_token tg_chat
  slack_url="$(grep -oE '"slack_webhook_url"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null \
              | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | head -n1 || true)"
  email="$(grep -oE '"email"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null \
              | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | head -n1 || true)"
  local_notify="$(grep -oE '"local_notify"[[:space:]]*:[[:space:]]*(true|false)' "$cfg" 2>/dev/null \
              | grep -oE '(true|false)$' | head -n1 || true)"
  tg_token="$(grep -oE '"telegram_bot_token"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null \
              | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | head -n1 || true)"
  # chat_id may be a quoted string OR an unquoted (possibly negative, for groups) number.
  tg_chat="$(grep -oE '"telegram_chat_id"[[:space:]]*:[[:space:]]*"?-?[0-9A-Za-z_]+"?' "$cfg" 2>/dev/null \
              | sed -E 's/.*:[[:space:]]*"?(-?[0-9A-Za-z_]+)"?.*/\1/' | head -n1 || true)"
  [[ -z "$slack_url" && -z "$email" && -z "$tg_token" && "$local_notify" != "true" ]] && return 0
  if [[ -n "$slack_url" ]] && command -v curl >/dev/null 2>&1; then
    # JSON-escape backslash + double-quote in our own controlled text (jq-free).
    local esc payload
    esc="$(printf '%s' "${title}: ${body}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    payload="$(printf '{"text":"%s"}' "$esc")"
    ( curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        --data "$payload" "$slack_url" >/dev/null 2>&1 || true ) &
  fi
  if [[ -n "$tg_token" && -n "$tg_chat" ]] && command -v curl >/dev/null 2>&1; then
    # Telegram Bot API sendMessage; --data-urlencode handles all escaping (jq-free).
    ( curl -fsS -m 10 -X POST \
        --data-urlencode "chat_id=${tg_chat}" \
        --data-urlencode "text=${title}: ${body}" \
        "https://api.telegram.org/bot${tg_token}/sendMessage" >/dev/null 2>&1 || true ) &
  fi
  if [[ -n "$email" ]] && command -v mail >/dev/null 2>&1; then
    ( printf '%s\n' "$body" | mail -s "$title" "$email" >/dev/null 2>&1 || true ) &
  fi
  if [[ "$local_notify" == "true" ]] && command -v osascript >/dev/null 2>&1; then
    local osbody ostitle
    osbody="$(printf '%s' "$body" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    ostitle="$(printf '%s' "$title" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    ( osascript -e "display notification \"${osbody}\" with title \"${ostitle}\"" >/dev/null 2>&1 || true ) &
  fi
  return 0
}
