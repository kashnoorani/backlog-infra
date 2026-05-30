#!/usr/bin/env bats
#
# `backlog-agents digest` — the automated fleet digest (W2; docs/fleet-digest.md),
# plus the shared notify_send (bin/_lib.sh) Telegram/local transports it rides on.
#
# Hermetic: BACKLOGS_PROJECTS_ROOTS points at a throwaway tree of fake projects,
# each carrying a hand-written .claude/backlog-history.jsonl (with controllable,
# now-relative timestamps so period windowing is exercised) and a docs/Backlog.md
# (so the [?]-blocker scan has something to find). HOME + NOTIFY_CONFIG are
# redirected to scratch paths so the digest never fires a real notification and
# never reads the user's ledgers. The notify_send unit tests stub `curl`/
# `osascript` on PATH and `wait` for the backgrounded sends.

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"
LIB="${BATS_TEST_DIRNAME}/../bin/_lib.sh"

# ISO-8601 (UTC, with millis to also exercise the fractional-second strip) for
# a BSD `date -v` offset like "1H" / "3d" / "10d".
iso_ago() { date -u -v-"$1" '+%Y-%m-%dT%H:%M:%S.000Z'; }

# Append one ledger record. Usage: hist <file> <exit_code> <work_commit> <tokens> <item> <ts>
# work_commit "null" (unquoted) ⇒ no-commit tick; else JSON-quoted SHA.
hist() {
  local file="$1" ec="$2" wc="$3" tok="$4" item="$5" ts="$6"
  mkdir -p "$(dirname "$file")"
  local wc_json
  if [[ "$wc" == "null" ]]; then wc_json="null"; else wc_json="\"$wc\""; fi
  printf '{"ts":"%s","host":"h.local","mode":"loop","item":"%s","exit_code":%s,"tokens":%s,"work_commit":%s}\n' \
    "$ts" "$item" "$ec" "$tok" "$wc_json" >> "$file"
}

setup() {
  ROOT="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$ROOT"
  export BACKLOGS_PROJECTS_ROOTS="$ROOT"

  # Keep notify hermetic: redirect HOME + point NOTIFY_CONFIG at an absent file so
  # notify_send is a silent no-op unless a test creates it (production fail-open).
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export NOTIFY_CONFIG="$BATS_TEST_TMPDIR/notify.json"

  # alpha: within-period activity + one open [?] blocker.
  #   t1 (1h ago):  ok + commit + 100 tok, item "ship A"  -> completion
  #   t2 (3d ago):  ok + commit + 300 tok, item "ship B"  -> completion (in week, not day)
  #   t3 (1h ago):  ok + no commit + 50 tok               -> tick, not a completion
  local A="$ROOT/alpha/.claude/backlog-history.jsonl"
  hist "$A" 0 c0ffee 100 "ship A" "$(iso_ago 1H)"
  hist "$A" 0 deadbe 300 "ship B" "$(iso_ago 3d)"
  hist "$A" 0 null    50 ""       "$(iso_ago 1H)"
  mkdir -p "$ROOT/alpha/docs"
  cat > "$ROOT/alpha/docs/Backlog.md" <<'EOF'
# alpha — Backlog
## Open
- [ ] something open
## Blocked
- [?] decide the storage format <!-- @h.local -->
## Done
- [x] old thing
EOF

  # stale: one OLD completion (10d ago) — outside both windows; no blocker. With
  # no in-period activity and no blocker it must NOT appear in either digest.
  local S="$ROOT/stale/.claude/backlog-history.jsonl"
  hist "$S" 0 ababab 70 "ancient" "$(iso_ago 10d)"
  mkdir -p "$ROOT/stale/docs"
  printf '# stale\n## Open\n- [ ] x\n' > "$ROOT/stale/docs/Backlog.md"
}

@test "digest text: shows the active project, its completion count, and the blocker title" {
  run "$AGENTS_BIN" digest --period week --no-notify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "alpha"
  echo "$output" | grep -q "Open \[?\] blockers"
  echo "$output" | grep -q "decide the storage format"
  echo "$output" | grep -q "ship A"
  # stale project (only an out-of-window completion, no blocker) is omitted.
  ! echo "$output" | grep -q "ancient"
}

@test "digest --json: validates and carries period-windowed fleet + project fields" {
  run "$AGENTS_BIN" digest --period week --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.period == "week"' >/dev/null
  echo "$output" | jq -e '.fleet.completed == 2' >/dev/null      # ship A + ship B
  echo "$output" | jq -e '.fleet.ticks == 3' >/dev/null
  echo "$output" | jq -e '.fleet.blocked == 1' >/dev/null
  echo "$output" | jq -e '(.projects | map(.project) | index("alpha")) != null' >/dev/null
  echo "$output" | jq -e '(.projects | map(.project) | index("stale")) == null' >/dev/null
  echo "$output" | jq -e '(.projects[] | select(.project=="alpha") | .completions | length) == 2' >/dev/null
}

@test "period windowing: a 3-day-old completion is in --period week but not --period day" {
  run "$AGENTS_BIN" digest --period week --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.projects[] | select(.project=="alpha") | .completed) == 2' >/dev/null

  run "$AGENTS_BIN" digest --period day --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.projects[] | select(.project=="alpha") | .completed) == 1' >/dev/null
  echo "$output" | jq -e '(.projects[] | select(.project=="alpha") | .completions | index("ship B")) == null' >/dev/null
}

@test "digest rejects an unknown period" {
  run "$AGENTS_BIN" digest --period month --no-notify
  [ "$status" -eq 2 ]
}

@test "digest --no-notify does NOT push (stubbed curl/osascript never invoked)" {
  # A live telegram config — but --no-notify must skip the send entirely.
  printf '{"telegram_bot_token":"123:FAKE","telegram_chat_id":"-100","local_notify":true}\n' > "$NOTIFY_CONFIG"
  local shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  printf '#!/usr/bin/env bash\necho called >> "%s"\n' "$BATS_TEST_TMPDIR/notified" > "$shim/curl"
  printf '#!/usr/bin/env bash\necho called >> "%s"\n' "$BATS_TEST_TMPDIR/notified" > "$shim/osascript"
  chmod +x "$shim/curl" "$shim/osascript"
  PATH="$shim:$PATH" run "$AGENTS_BIN" digest --period week --no-notify
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/notified" ]
}

@test "notify_send: Telegram branch posts to the Bot API sendMessage endpoint" {
  printf '{"telegram_bot_token":"123:FAKE","telegram_chat_id":-100200,"local_notify":false}\n' > "$NOTIFY_CONFIG"
  local shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  cat > "$shim/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/curlargs"
exit 0
EOF
  chmod +x "$shim/curl"
  PATH="$shim:$PATH" bash -c ". '$LIB'; NOTIFY_CONFIG='$NOTIFY_CONFIG' notify_send 'digest (7d)' 'fleet: 2 completed'; wait"
  run cat "$BATS_TEST_TMPDIR/curlargs"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "api.telegram.org/bot123:FAKE/sendMessage"
  echo "$output" | grep -q "chat_id=-100200"
  echo "$output" | grep -q "text=digest (7d): fleet: 2 completed"
}

@test "notify_send: empty/absent config is a silent no-op" {
  rm -f "$NOTIFY_CONFIG"
  run bash -c ". '$LIB'; NOTIFY_CONFIG='$NOTIFY_CONFIG' notify_send 'x' 'y'; echo done"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "done"
}
