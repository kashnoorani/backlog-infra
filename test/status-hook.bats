#!/usr/bin/env bats
#
# Tests for bin/backlog-agent-status.mjs — the per-tick status hook.
# This is where the 2026-05-28 incident lived (unconditional
# `git add COOLDOWN_FILE` aborted every status commit fleet-wide for ~8h).

load 'helpers'

setup() { _setup_status_repo; }

# Writes all three artifacts with valid JSON / JSONL.
@test "writes status, per-host, and history artifacts" {
  run_hook
  [ "$status" -eq 0 ]
  [ -f "$WORK/.claude/backlog-status.json" ]
  node -e 'JSON.parse(require("fs").readFileSync(".claude/backlog-status.json"))'
  ls "$WORK"/.claude/backlog-status-*.json >/dev/null
  [ -f "$WORK/.claude/backlog-history.jsonl" ]
  node -e 'process.argv[1].trim().split("\n").forEach(l=>JSON.parse(l))' \
    "$(cat "$WORK"/.claude/backlog-history.jsonl)"
}

# The 2026-05-28 regression: with NO cooldown file present, the hook must not
# abort (it used to `git add` a non-existent agent-cooldown.json → exit 128).
@test "absent cooldown file does not abort the hook" {
  [ ! -f "$WORK/.claude/agent-cooldown.json" ]
  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *"did not match any files"* ]]
}

# A present cooldown file is staged without error.
@test "present cooldown file is staged cleanly" {
  printf '{ "until_epoch": %s }\n' "$(( $(date +%s) + 3600 ))" > "$WORK/.claude/agent-cooldown.json"
  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *"did not match any files"* ]]
}

# Each invocation appends exactly one line to the history ledger.
@test "history ledger grows by one line per invocation" {
  run_hook
  run_hook
  [ "$(grep -c . "$WORK/.claude/backlog-history.jsonl")" -eq 2 ]
}

# Version-skew (W1): --driver-sha is recorded into the status JSON and history
# so the dashboard can flag a host running a stale shared driver.
@test "records driver_sha into status and history" {
  run_hook --driver-sha abc1234
  [ "$status" -eq 0 ]
  [ "$(jq -r .driver_sha "$WORK/.claude/backlog-status.json")" = "abc1234" ]
  grep -q '"driver_sha":"abc1234"' "$WORK/.claude/backlog-history.jsonl"
}

# Absent --driver-sha → field present but null (never crashes / omits).
@test "driver_sha is null when not supplied" {
  run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r .driver_sha "$WORK/.claude/backlog-status.json")" = "null" ]
}

# Layer 3 (docs/multi-agent-design.md): when a non-Claude fallback agent ran
# the tick, the trailer records `agent=<name>` in place of the token/turn usage
# (there's no Claude transcript to count), while keeping the `Claude-Effort:`
# key so grep-based consumers still match.
@test "non-claude --agent records agent= in the commit trailer" {
  run_hook --agent opencode
  [ "$status" -eq 0 ]
  local msg; msg="$(git -C "$WORK" log -1 --format=%B HEAD)"
  [[ "$msg" == *"Claude-Effort: agent=opencode, exit=0"* ]]
  [[ "$msg" != *"turns"* ]]
}

# Default agent (claude) keeps the usual token/turn trailer.
@test "default claude agent keeps the token/turn trailer" {
  run_hook
  [ "$status" -eq 0 ]
  local msg; msg="$(git -C "$WORK" log -1 --format=%B HEAD)"
  [[ "$msg" == *"Claude-Effort:"* ]]
  [[ "$msg" == *"turns, exit=0"* ]]
  [[ "$msg" != *"agent="* ]]
}

# REGRESSION GUARD for the untrack interaction: now that the SHARED
# backlog-status.json is gitignored, the hook must STILL commit the per-host
# file + history (they are tracked). It must not treat "the shared file is
# ignored" as "everything is ignored, skip the commit".
@test "still commits per-host + history when only shared status.json is gitignored" {
  local head_before; head_before="$(git -C "$WORK" rev-parse HEAD)"
  run_hook
  [ "$status" -eq 0 ]
  local head_after; head_after="$(git -C "$WORK" rev-parse HEAD)"
  [ "$head_before" != "$head_after" ]                       # a commit landed
  git -C "$WORK" show --stat HEAD | grep -q "backlog-history.jsonl"
  [[ "$output" != *"skipping commit"* ]]
}

# TaizMail-class orphan-stash leak (2026-05-29): when this tick and another
# machine's tick both touch the SAME tracked, hook-owned telemetry file, the
# post-rebase autostash pop conflicts — and the failed pop used to leave the
# stash ORPHANED, accumulating silently (10 in 2h on TaizMail). A pop conflict
# CONFINED to the ephemeral set must now be auto-resolved (history union'd) and
# the stash DROPPED — never orphaned.
@test "ephemeral-only autostash pop conflict is resolved + stash dropped (no orphan)" {
  local hist=".claude/backlog-history.jsonl"
  # Seed a tracked history line on both sides, then push.
  echo '{"ts":"base","tokens":1}' > "$WORK/$hist"
  git -C "$WORK" add "$hist"
  git -C "$WORK" commit -qm "seed history"
  git -C "$WORK" push -q origin main

  # Another machine appends a DIFFERENT history line and pushes (origin ahead).
  local other="$BATS_TEST_TMPDIR/other"
  git clone -q "$REMOTE" "$other"
  echo '{"ts":"origin","tokens":2}' >> "$other/$hist"
  git -C "$other" add "$hist"
  git -C "$other" commit -qm "origin history"
  git -C "$other" push -q origin main

  # Locally leave a conflicting uncommitted append to the SAME file — the dirty
  # tree the pre-rebase autostash grabs, whose pop then conflicts post-rebase.
  echo '{"ts":"local","tokens":3}' >> "$WORK/$hist"

  run_hook
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$WORK" stash list)" ]            # no orphan stash left behind
  [[ "$output" == *"resolved ephemeral autostash conflict"* ]]
  # The union preserves all three pre-tick lines (plus this tick's appended one).
  grep -q '"ts":"base"'   "$WORK/$hist"
  grep -q '"ts":"origin"' "$WORK/$hist"
  grep -q '"ts":"local"'  "$WORK/$hist"
}

# Belt-and-suspenders: a pop conflict that touches a NON-ephemeral path is real
# work — it must NOT be auto-discarded. The stash is preserved (legacy behavior)
# so the user can recover it.
@test "non-ephemeral autostash pop conflict leaves the stash intact" {
  echo base > "$WORK/work.txt"
  git -C "$WORK" add work.txt
  git -C "$WORK" commit -qm "seed work"
  git -C "$WORK" push -q origin main

  local other="$BATS_TEST_TMPDIR/other"
  git clone -q "$REMOTE" "$other"
  echo origin > "$other/work.txt"
  git -C "$other" commit -qam "origin work"
  git -C "$other" push -q origin main

  echo local > "$WORK/work.txt"                    # conflicting dirty edit

  run_hook
  [ -n "$(git -C "$WORK" stash list)" ]            # real work is NOT dropped
  [[ "$output" == *"changes left in stash"* ]]
  [[ "$output" != *"resolved ephemeral autostash conflict"* ]]
}
