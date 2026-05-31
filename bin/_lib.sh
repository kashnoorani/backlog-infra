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

# --- Deny-by-default autonomous tool/permission profile (threat-model §5) ---
# Shared by the DRIVER (backlog-agent: injects --settings when
# AUTONOMOUS_TOOL_PROFILE=1, and the detective Guard 3 protected-path check) and
# the CLI (backlog-agents tool-profile --verify/--show) so the deny set and the
# protected-path list have ONE definition — the preventive (§5) and detective
# (Guard 3) twins stay in sync. docs/tool-profile.md / docs/threat-model.md §5.
#
# Shared-driver + project-config files the autonomous tick must never rewrite.
# Exact repo-relative names, so a project's own unrelated bin/ tooling stays
# writable (per the user decision; not a blanket bin/** deny).
PROTECTED_PATHS="bin/backlog-agent bin/backlog-agent-status.mjs release.mjs CLAUDE.md .gitignore"

# Emit the constrained --settings JSON injected into the autonomous `claude -p`
# (jq-free; rule strings are simple, no escaping needed). Contains ONLY
# permissions.deny — deny wins + layers onto the daemon's config, leaving the
# headless auto-accept untouched. Deny classes: network egress, secret-path
# reads, and Edit/Write of each PROTECTED_PATHS file.
build_tool_profile_settings() {
  local -a deny=(
    WebFetch WebSearch
    "Bash(curl:*)" "Bash(wget:*)" "Bash(nc:*)" "Bash(ncat:*)" "Bash(telnet:*)"
    "Read(~/.ssh/**)" "Read(~/.aws/**)" "Read(~/.gnupg/**)"
    "Read(~/.config/backlog/**)" "Read(.env)" "Read(./.env)" "Read(**/.env)"
    "Edit(docs/Backlog.md)" "Write(docs/Backlog.md)"
    "Edit(Backlog.md)" "Write(Backlog.md)"
    "Edit(backlog.txt)" "Write(backlog.txt)"
  )
  local p
  for p in $PROTECTED_PATHS; do
    deny+=( "Edit(${p})" "Write(${p})" )
  done
  local json='' sep='' r
  for r in "${deny[@]}"; do
    json+="${sep}\"${r}\""
    sep=','
  done
  printf '{"permissions":{"deny":[%s]}}' "$json"
}

# §5 tool-profile flip-on is PER PROJECT via a marker file, so a canary can be
# flipped one project at a time and survive a `sync`/reinstall (which regenerates
# the daemon plist). The marker lives OUTSIDE the repo at
# ~/.claude/tool-profile/<project>.on — per-machine state that must never be
# committed (an in-repo marker isn't reliably gitignored and would propagate the
# flip to other machines), matching where the canary/budgets/notify config already
# live. Emit the launchd <EnvironmentVariables> snippet that sets
# AUTONOMOUS_TOOL_PROFILE=1 iff the marker for $1 (project name) exists; empty
# otherwise. The driver injects the constrained --settings on every tick when the
# env is 1. Rollback = rm the marker + reinstall the daemon. Quote-free output, so
# no XML escaping needed. do_install_daemon splices the result into the plist's
# EnvironmentVariables dict; a bats test asserts it without a live launchctl bootstrap.
tool_profile_plist_env() {
  local project="$1"
  [[ -f "$HOME/.claude/tool-profile/${project}.on" ]] || return 0
  printf '\n        <key>AUTONOMOUS_TOOL_PROFILE</key>\n        <string>1</string>'
}

# Check SSH connectivity to GitHub. Critical for cloning, pulling, and pushing.
# $1 = timeout in seconds (default 5). Returns 0 if healthy, non-zero if broken.
check_github_ssh() {
  local timeout=5
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
# HTML-escape the 3 characters Telegram's HTML parser treats as markup.
# Usage: _html_esc "some <string> with & chars"
_html_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Usage: notify_send "<title>" "<body>" ["<tg_html>"]
# Optional 3rd arg: pre-formatted HTML for Telegram (parse_mode=HTML). When omitted,
# Telegram receives plain "${title}: ${body}". Slack / email / macOS always get plain text.
notify_send() {
  local title="${1:-backlog-agent}" body="${2:-}" tg_html="${3:-}"
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
    # When a pre-formatted tg_html body is provided, send it with parse_mode=HTML so
    # bold/code/line-breaks render. Otherwise fall back to plain "${title}: ${body}".
    if [[ -n "$tg_html" ]]; then
      ( curl -fsS -m 10 -X POST \
          --data-urlencode "chat_id=${tg_chat}" \
          --data-urlencode "text=${tg_html}" \
          --data-urlencode "parse_mode=HTML" \
          "https://api.telegram.org/bot${tg_token}/sendMessage" >/dev/null 2>&1 || true ) &
    else
      ( curl -fsS -m 10 -X POST \
          --data-urlencode "chat_id=${tg_chat}" \
          --data-urlencode "text=${title}: ${body}" \
          "https://api.telegram.org/bot${tg_token}/sendMessage" >/dev/null 2>&1 || true ) &
    fi
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
