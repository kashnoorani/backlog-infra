#!/usr/bin/env bats
#
# Dead-man's-switch alerting (W2, docs/dead-mans-switch.md) — a notify-channel
# consumer that promotes "STALE-too-long / repeated-hook-failure" from a passive
# dashboard color into an ACTUAL push. Two halves, two surfaces:
#
#   (b) DRIVER repeated-hook-failure (bin/backlog-agent) — the daemon is ALIVE but
#       its status hook (git fetch/rebase/push + telemetry) fails N consecutive
#       ticks. _run_status_hook feeds _hookfail_record; at DMS_HOOKFAIL_THRESHOLD it
#       fires ONE notify_send and throttles (the `alerted` flag); status_ok clears
#       the streak so the next incident re-alerts. The daemon can alert about
#       ITSELF here because it's alive, just failing.
#
#   (a) CLI staleness watcher (bin/backlog-agents monitor) — a dead daemon can't
#       alert about itself, so the monitor reads the INDEPENDENT D1 heartbeat for
#       each (project, host) it knows and fires when one hasn't beaten for
#       > DMS_STALE_SECS. Per-incident dedup; infra EXCLUDED (held by policy);
#       FAIL-OPEN on an unreadable heartbeat (can't conclude death).
#
# Hermetic: curl / mail / osascript are PATH-shimmed; no network. The driver half
# reuses helpers.bash; the CLI half builds a tiny fake fleet under a scratch HOME
# (mirrors sync-infra-exclude.bats). FREEZE_DISABLE / ACCOUNT_COOLDOWN_DISABLE keep
# the other top-of-tick D1 reads out of these tests.

load 'helpers'

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

# Poll for a backgrounded notify POST to land (notify_send backgrounds curl so a
# slow endpoint can't stall the daemon). Fails after ~3s.
wait_for_post() {
  local i
  for i in $(seq 1 30); do
    [ -s "$HOME/.posted" ] && return 0
    sleep 0.1
  done
  return 1
}

# Count lines in $HOME/.posted whose payload matches a substring. grep -c prints
# "0" AND exits 1 on no match, so capture-then-default avoids the "0\n0" footgun.
posted_count() {
  local n; n="$(grep -c -- "$1" "$HOME/.posted" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# ==========================================================================
# (b) DRIVER — repeated status-hook failure
# ==========================================================================

# Rewrite the per-project status hook so the next tick's _run_status_hook exits
# with the given code (0 = status_ok, non-zero = status_fail). MUST commit + push:
# an uncommitted change is reverted by the tick's autostash/rebase (the committed
# _setup_repo hook is process.exit(0)), which silently turns every tick status_ok.
hook_exit() {
  printf 'process.exit(%s)\n' "$1" > "$WORK/scripts/backlog-agent-status.mjs"
  git -C "$WORK" add scripts/backlog-agent-status.mjs
  git -C "$WORK" commit -qm "test: status hook exits $1" >/dev/null 2>&1 || true
  git -C "$WORK" push -q origin main >/dev/null 2>&1 || true
}

# curl shim for the DRIVER: records Slack POSTs (notify_send) to $HOME/.posted and
# answers the reaper's heartbeat read innocuously. The Slack webhook URL is the
# only POST target here (freeze + account-cooldown reads are disabled by helpers).
make_dms_driver_curl() {
  mkdir -p "$HOME/.config/backlog"; echo testkey > "$HOME/.config/backlog/health-key"
  : > "$HOME/.posted"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a";; --data|-d) data="$a";; esac
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
case "$url" in
  *heartbeat*) printf '%s\n%s' '{"found":false}' 404 ;;
  *)           printf '%s\n' "$data" >> "$HOME/.posted"; printf '%s\n%s' ok 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# Opt-in notify config (canonical ~/.claude/agent-notify.json). Channels per args:
#   slack=<url>  email=<addr>  local=<true|false>
write_notify_config() {
  mkdir -p "$HOME/.claude"
  local slack="" email="" localn="false"
  while (( $# )); do case "$1" in slack=*) slack="${1#slack=}";; email=*) email="${1#email=}";; local=*) localn="${1#local=}";; esac; shift; done
  {
    printf '{\n'
    printf '  "slack_webhook_url": "%s",\n' "$slack"
    printf '  "email": "%s",\n' "$email"
    printf '  "local_notify": %s\n' "$localn"
    printf '}\n'
  } > "$HOME/.claude/agent-notify.json"
}

# b1. Fires exactly ONCE at the threshold (3 consecutive status_fail), then throttles.
@test "driver: repeated hook failure fires one alert at threshold N, then throttles" {
  _setup_repo
  make_dms_driver_curl
  write_notify_config slack=http://localhost/slack-DMS
  hook_exit 1                      # every tick's status hook now FAILS

  run_tick ; run_tick              # ticks 1+2: below threshold, no alert
  [ "$(posted_count consecutive)" -eq 0 ]

  run_tick                         # tick 3: trips
  wait_for_post
  [ "$(posted_count consecutive)" -eq 1 ]
  grep -q "dead-man" "$HOME/.posted"

  run_tick ; run_tick              # persists failing: throttled, still ONE alert
  [ "$(posted_count consecutive)" -eq 1 ]
}

# b2. A status_ok clears the streak AND the throttle, so a NEW incident re-alerts.
@test "driver: status_ok resets the streak; the next incident re-alerts" {
  _setup_repo
  make_dms_driver_curl
  write_notify_config slack=http://localhost/slack-DMS

  hook_exit 1; run_tick; run_tick; run_tick   # incident 1 -> 1 alert
  wait_for_post
  [ "$(posted_count consecutive)" -eq 1 ]
  [ -f "$WORK/.claude/backlog-agent-hookfail.json" ]

  hook_exit 0; run_tick                        # recovery clears the state file
  [ ! -f "$WORK/.claude/backlog-agent-hookfail.json" ]

  hook_exit 1; run_tick; run_tick; run_tick   # incident 2 -> a second alert
  wait_for_post
  [ "$(posted_count consecutive)" -eq 2 ]
}

# b3. No config => silent no-op (the switch never depends on alerting being set up).
@test "driver: repeated hook failure with no notify config is a silent no-op" {
  _setup_repo
  make_dms_driver_curl
  rm -f "$HOME/.claude/agent-notify.json"
  hook_exit 1
  run_tick; run_tick; run_tick
  [ "$status" -eq 0 ]
  [ "$(posted_count consecutive)" -eq 0 ]      # nothing posted, tick unharmed
  [ -f "$WORK/.claude/backlog-agent-hookfail.json" ]   # but the streak is still tracked
}

# b4. notify_send routes to ALL configured channels (slack + email + local).
@test "driver: notify_send fires slack, email and macOS-local channels" {
  _setup_repo
  make_dms_driver_curl
  # Shim mail + osascript to record invocations.
  cat > "$SHIM/mail" <<EOF
#!/usr/bin/env bash
echo "mailed" >> "$HOME/.mailed"
cat >/dev/null
EOF
  cat > "$SHIM/osascript" <<EOF
#!/usr/bin/env bash
echo "osa" >> "$HOME/.osa"
EOF
  chmod +x "$SHIM/mail" "$SHIM/osascript"
  write_notify_config slack=http://localhost/slack-DMS email=me@example.com local=true
  hook_exit 1
  run_tick; run_tick; run_tick
  wait_for_post
  [ "$(posted_count consecutive)" -eq 1 ]      # slack
  for i in $(seq 1 30); do [ -s "$HOME/.mailed" ] && break; sleep 0.1; done
  [ -s "$HOME/.mailed" ]                        # email
  for i in $(seq 1 30); do [ -s "$HOME/.osa" ] && break; sleep 0.1; done
  [ -s "$HOME/.osa" ]                           # macOS-local
}

# ==========================================================================
# (a) CLI — monitor staleness watcher
# ==========================================================================

# Build a fake fleet under a scratch HOME and a curl shim whose heartbeat answers
# are keyed off the &project= name: *alive* -> fresh, *unknown* -> 404 (fail-open),
# everything else (incl. backlog-infra, proj-dead) -> dead (heartbeat 2h old). Slack
# POSTs are recorded to $HOME/.posted.
setup_fake_fleet() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export USER="tu"
  ACTIVE="$HOME/dev/projects/active"
  SHIM="$BATS_TEST_TMPDIR/shim"; mkdir -p "$SHIM"; export PATH="$SHIM:$PATH"
  mkdir -p "$HOME/.config/backlog" "$HOME/.claude" "$ACTIVE/backlog-infra/.claude"
  echo testkey > "$HOME/.config/backlog/health-key"
  : > "$HOME/.posted"
  # Projects + their per-host status files (the (project,host) pairs the watcher
  # enumerates — same source the MACHINES table reads).
  mkdir -p "$ACTIVE/proj-alive/.claude" "$ACTIVE/proj-dead/.claude" "$ACTIVE/proj-unknown/.claude"
  echo '{}' > "$ACTIVE/proj-alive/.claude/backlog-status-HostA.json"
  echo '{}' > "$ACTIVE/proj-dead/.claude/backlog-status-HostB.json"
  echo '{}' > "$ACTIVE/proj-unknown/.claude/backlog-status-HostC.json"
  echo '{}' > "$ACTIVE/backlog-infra/.claude/backlog-status-HostA.json"  # dead but EXCLUDED
  write_notify_config slack=http://localhost/slack-DMS
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
now="$(date +%s)"
url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in --data|-d) data="$a";; esac
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
emit() { printf '%s\n%s' "$1" "$2"; }
case "$url" in
  *heartbeat*)
    proj="$(printf '%s' "$url" | sed -nE 's|.*[?&]project=([^&]*).*|\1|p' | head -n1)"
    case "$proj" in
      *alive*)   emit "{\"found\":true,\"heartbeat_epoch\":$now}" 200 ;;
      *unknown*) emit '{"found":false}' 404 ;;
      *)         emit "{\"found\":true,\"heartbeat_epoch\":$((now-7200))}" 200 ;;
    esac ;;
  *) printf '%s\n' "$data" >> "$HOME/.posted"; emit ok 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# a1. A dead daemon trips: flagged in the report AND pushed to the notify channel.
@test "monitor: a stale-too-long daemon trips the dead-man's-switch and pushes" {
  setup_fake_fleet
  run env USER=tu bash "$AGENTS_BIN" monitor --once
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEAD-MAN"* ]]
  [[ "$output" == *"proj-dead@HostB"* ]]
  wait_for_post
  grep -q "proj-dead" "$HOME/.posted"
  grep -q "DEAD daemon" "$HOME/.posted"
}

# a2. A live daemon does NOT trip.
@test "monitor: a freshly-heartbeating daemon does not trip" {
  setup_fake_fleet
  run env USER=tu bash "$AGENTS_BIN" monitor --once
  [[ "$output" != *"proj-alive@HostA"* ]]
}

# a3. The infra daemon is EXCLUDED even though its heartbeat is dead (held by policy).
@test "monitor: the infra daemon is excluded from the staleness watcher" {
  setup_fake_fleet
  run env USER=tu bash "$AGENTS_BIN" monitor --once
  [[ "$output" != *"backlog-infra@HostA"* ]]
  ! grep -q "backlog-infra" "$HOME/.posted"
}

# a4. FAIL-OPEN: an unreadable heartbeat (404) does NOT conclude death.
@test "monitor: an unreadable heartbeat fails open (no false dead-man)" {
  setup_fake_fleet
  run env USER=tu bash "$AGENTS_BIN" monitor --once
  [[ "$output" != *"proj-unknown@HostC"* ]]
}

# a6. Monitor self-protect (Patterns 1-3) must FLAG, never stash/reset, the held
#     infra repo — the case that re-fired every sweep off the frozen daemon log and
#     would eat in-flight interactive work. (Mirrors the do_sync infra exclusion.)
@test "monitor: the infra repo is flagged, never reset, on a stale push-fail log" {
  setup_fake_fleet
  # Give the infra dir a backlog-agent log carrying the stale push-failure line.
  echo "error: failed to push some refs to origin" > "$ACTIVE/backlog-infra/.claude/backlog-agent.log"
  run env USER=tu bash "$AGENTS_BIN" monitor --once --fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"infra repo (interactive, daemon held); flag only"* ]]
  [[ "$output" != *"FIXED${RS:-} backlog-infra"* ]]
  [[ "$output" != *"backlog-infra: git push rejected — fetch + reset"* ]]
}

# a5. Per-incident dedup: a persistent death alerts ONCE across repeated sweeps.
@test "monitor: a persistent dead daemon alerts once across sweeps (dedup)" {
  setup_fake_fleet
  bash "$AGENTS_BIN" monitor --interval 1 >/dev/null 2>&1 &
  local mpid=$!
  sleep 3                                   # ~3 sweeps at interval 1
  kill "$mpid" 2>/dev/null || true
  wait "$mpid" 2>/dev/null || true
  # Exactly one dead-man push for proj-dead despite multiple sweeps.
  [ "$(grep -c 'proj-dead' "$HOME/.posted" 2>/dev/null || echo 0)" -eq 1 ]
}
