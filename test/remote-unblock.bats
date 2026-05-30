#!/usr/bin/env bats
#
# Remote unblock (W2, docs/remote-unblock.md) — the FIRST inbound control path. A
# `[?]` blocker can today only be answered on the machine that owns the clone (edit
# docs/Backlog.md + `backlog-agent unblock`). This feature lets the user reply to the
# fleet digest (Telegram bot -> POST /api/unblock -> a D1 unblock_requests row); each
# daemon POLLS GET /api/unblock?project=<self> top-of-tick (process_unblock_requests),
# matches its project, locates the addressed `[?]` item (the Nth, the `do_unblock`
# ordering), writes the `[user]` answer + flips `[?]`→`[!]`, commits/pushes, and marks
# the row applied. Item addressing is `<project>#<index>` + an optional title-prefix
# guard: a stale index ⇒ NO-OP + re-notify + clear `mismatch`, never the wrong item.
#
# All hermetic: curl is PATH-shimmed; no network. REMOTE_UNBLOCK_DISABLE=1 (helpers
# default) keeps ordinary tick tests off the network; these re-enable it (=0) behind
# the stub. node IS used (the answer is arbitrary free text, base64'd through the
# shell) — it's a real dep of the driver, available on PATH after the shim.

load 'helpers'

# curl shim for the remote-unblock poll + clear. GET /api/unblock modes:
#   pending  -> 200 {requests:[{id:1,item_index:1,title_prefix:"",answer:…}]}
#   guarded  -> same, but title_prefix that does NOT match the seeded [?] title
#   none     -> 200 {requests:[]}
#   unreachable -> exit 7 (fail-open)
# A POST (clear) records its body to $HOME/.posted and returns 200.
# *heartbeat* -> 404 (reaper fail-safe skip); anything else -> {} 200.
ANSWER_TEXT='use the WGS84 datum, document the tradeoff'
make_unblock_curl() {
  local mode="$1"
  mkdir -p "$HOME/.config/backlog"
  echo testkey > "$HOME/.config/backlog/health-key"
  : > "$HOME/.posted"
  cat > "$SHIM/curl" <<EOF
#!/usr/bin/env bash
mode="$mode"
answer="$ANSWER_TEXT"
EOF
  cat >> "$SHIM/curl" <<'EOF'
method=GET; url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a";; -d) data="$a";; esac
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
emit() { printf '%s\n%s' "$1" "$2"; }
case "$url" in
  *unblock*)
    if [ "$method" = POST ]; then
      printf '%s\n' "$data" >> "$HOME/.posted"; emit '{"ok":true,"cleared":true}' 200
    else
      case "$mode" in
        pending)     emit "{\"requests\":[{\"id\":1,\"project\":\"p\",\"item_index\":1,\"title_prefix\":\"\",\"answer\":\"$answer\"}]}" 200 ;;
        guarded)     emit "{\"requests\":[{\"id\":1,\"project\":\"p\",\"item_index\":1,\"title_prefix\":\"Totally different prefix\",\"answer\":\"$answer\"}]}" 200 ;;
        outofrange)  emit "{\"requests\":[{\"id\":1,\"project\":\"p\",\"item_index\":9,\"title_prefix\":\"\",\"answer\":\"$answer\"}]}" 200 ;;
        none)        emit '{"requests":[]}' 200 ;;
        unreachable) exit 7 ;;
      esac
    fi ;;
  *heartbeat*) emit '{"found":false}' 404 ;;
  *)           emit '{}' 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# Poll for the clear POST to land (backgrounded in the driver so it can't stall the tick).
wait_for_post() {
  local i
  for i in $(seq 1 30); do
    [ -s "$HOME/.posted" ] && return 0
    sleep 0.1
  done
  return 1
}

# ==========================================================================
# Apply path
# ==========================================================================

# 1. A pending request writes the [user] answer + flips [?]→[!] + clears the row.
@test "remote-unblock: pending request writes the answer, flips [?], clears the row" {
  _setup_repo
  export REMOTE_UNBLOCK_DISABLE=0
  write_backlog_open "- [?] design decision needed for the widget"
  git add docs/Backlog.md; git commit -qm "seed blocker"; git push -q
  make_unblock_curl pending
  run_tick REMOTE_UNBLOCK_DISABLE=0
  [ "$status" -eq 0 ]
  # The [user] answer landed in the body.
  grep -qF "[user] ${ANSWER_TEXT}" docs/Backlog.md
  # The blocker is no longer [?] (flipped to [!], or [~] if the same tick then claimed it).
  ! grep -qE '^(- )?\[\?\] design decision' docs/Backlog.md
  # A clear POST landed marking the row applied.
  wait_for_post
  grep -q '"applied":1' "$HOME/.posted"
  grep -q '"result":"applied"' "$HOME/.posted"
  # Audit: a remote-unblock commit was recorded.
  git log --oneline | grep -q 'remote-unblock:'
}

# 2. Title-prefix mismatch (the [?] set shifted) -> NO-OP + clear 'mismatch', no flip.
@test "remote-unblock: title-prefix mismatch is a no-op + clears 'mismatch'" {
  _setup_repo
  export REMOTE_UNBLOCK_DISABLE=0
  write_backlog_open "- [?] design decision needed for the widget"
  git add docs/Backlog.md; git commit -qm "seed blocker"; git push -q
  make_unblock_curl guarded
  run_tick REMOTE_UNBLOCK_DISABLE=0
  [ "$status" -eq 0 ]
  # No answer written, blocker still [?].
  ! grep -qF "[user]" docs/Backlog.md
  grep -qE '^(- )?\[\?\] design decision' docs/Backlog.md
  # The row was cleared as a mismatch (so it doesn't retry forever).
  wait_for_post
  grep -q '"result":"mismatch"' "$HOME/.posted"
}

# 3. Out-of-range index (fewer [?] than the handle named) -> no-op + clear 'mismatch'.
@test "remote-unblock: out-of-range index is a no-op + clears 'mismatch'" {
  _setup_repo
  export REMOTE_UNBLOCK_DISABLE=0
  write_backlog_open "- [?] design decision needed for the widget"
  git add docs/Backlog.md; git commit -qm "seed blocker"; git push -q
  make_unblock_curl outofrange
  run_tick REMOTE_UNBLOCK_DISABLE=0
  [ "$status" -eq 0 ]
  ! grep -qF "[user]" docs/Backlog.md
  grep -qE '^(- )?\[\?\] design decision' docs/Backlog.md
  wait_for_post
  grep -q '"result":"mismatch"' "$HOME/.posted"
}

# 4. Fail-open: an unreachable endpoint applies nothing (the blocker is untouched).
@test "remote-unblock: unreachable endpoint fails open (blocker untouched)" {
  _setup_repo
  export REMOTE_UNBLOCK_DISABLE=0
  write_backlog_open "- [?] design decision needed for the widget"
  git add docs/Backlog.md; git commit -qm "seed blocker"; git push -q
  make_unblock_curl unreachable
  run_tick REMOTE_UNBLOCK_DISABLE=0
  [ "$status" -eq 0 ]
  ! grep -qF "[user]" docs/Backlog.md
  grep -qE '^(- )?\[\?\] design decision' docs/Backlog.md
  [ ! -s "$HOME/.posted" ]   # nothing applied -> nothing cleared
}

# 5. The disable flag (helpers default = 1) skips the poll entirely: a pending
#    request is NOT applied even though the endpoint WOULD serve it.
@test "remote-unblock: REMOTE_UNBLOCK_DISABLE=1 skips the poll" {
  _setup_repo
  # leave REMOTE_UNBLOCK_DISABLE=1 (helpers default)
  write_backlog_open "- [?] design decision needed for the widget"
  git add docs/Backlog.md; git commit -qm "seed blocker"; git push -q
  make_unblock_curl pending
  run_tick
  [ "$status" -eq 0 ]
  ! grep -qF "[user]" docs/Backlog.md
  grep -qE '^(- )?\[\?\] design decision' docs/Backlog.md
  [ ! -s "$HOME/.posted" ]
}
