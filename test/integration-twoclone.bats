#!/usr/bin/env bats
#
# Two-clone integration harness — the #54 keystone.
#
# Every other test file drives ONE clone (`$WORK`) black-box and, where it needs
# "another machine," fakes origin moving with a throwaway second clone it pushes
# to by hand. None of them run the REAL driver on two independent checkouts of a
# shared bare origin. This file does: a bare `$REMOTE`, two full driver fixtures
# `$WORK` ("M1") and `$WORK_B` ("M3"), and `backlog-agent tick` run for real on
# each — so the §5 cross-machine claim invariants (docs/cross-machine-locking.md)
# are exercised end-to-end across the git-push CAS medium, not approximated.
#
# Covered (deterministic, real driver on BOTH clones):
#   * two clones pick DIFFERENT items off the same queue — no collision        (T1)
#   * a completed item is never re-worked by the other clone — one winner      (T2)
#   * a dead clone's [~] claim is reaped + handed off cross-machine, and the
#     reclaim-before-claim ordering keeps the claim a non-zero diff            (T3)
#
# Deliberately NOT covered here — the true *concurrent* CAS push-rejection race
# (both clones commit a claim off the same base, one push lands, the other is
# rejected → reset --hard). Hitting that window deterministically requires
# pausing a tick between its fetch and its push, which is exactly what the
# item's `--inject-fault` mode (part c) is for. With sequential ticks the loser
# always *fetches* the winner's claim before it would push, so it takes the
# benign skip/handoff path below rather than the reset path. The reset-on-
# divergence recovery itself is covered single-clone in tick.bats ("diverged
# local HEAD is reset to origin").
#
# Opt out of this (slower, multi-clone) file with TWOCLONE_DISABLE=1, mirroring
# the suite's *_DISABLE convention; it runs by default so the canary covers it.

load helpers

setup() {
  [[ "${TWOCLONE_DISABLE:-0}" == "1" ]] && skip "two-clone integration disabled (TWOCLONE_DISABLE=1)"
  _setup_repo                       # REMOTE + clone A ($WORK), shims, HOME, *_DISABLE
  WORK_B="$BATS_TEST_TMPDIR/work-b" # the second clone ("M3"), made per test
}

# A `complete` claude stub that also PUSHES, mirroring production (lifecycle
# step 7: "commit + push by claude"). The shared make_claude `complete` only
# commits — fine single-clone (tests assert the local tree), but a cross-clone
# test needs the completion to actually reach origin so the OTHER clone sees it.
make_claude_complete_push() {
  cat > "$SHIM/claude" <<'EOF'
#!/usr/bin/env bash
touch "${CLAUDE_CALLED:-/dev/null}"
awk '
  BEGIN{in_open=0; done=0}
  /^## Open/{in_open=1; print; next}
  /^## [A-Z]/{in_open=0; print; next}
  in_open && !done && /^(- )?\[~\] /{ sub(/\[~\]/,"[x]"); done=1 }
  {print}
' docs/Backlog.md > docs/Backlog.md.tmp && mv docs/Backlog.md.tmp docs/Backlog.md
echo implemented > implemented.txt
git add implemented.txt docs/Backlog.md
git commit -qm "work: did the thing"
git push -q origin main 2>/dev/null || true
exit 0
EOF
  chmod +x "$SHIM/claude"
}

# Seed ## Open in clone A with the given item lines, push, then make a fresh
# second clone "B" from the bare origin so both start synced at the same base.
seed_and_clone_b() {
  write_backlog_open_in "$WORK" "$@"
  git -C "$WORK" commit -qam "seed: $*"
  git -C "$WORK" push -q origin main
  rm -rf "$WORK_B"
  git clone -q "$REMOTE" "$WORK_B"
}

# True if the ## Open section of the given clone holds an item with the marker.
open_marker_in() {  # $1=clone dir  $2=marker char (e.g. '~' 'x' ' ')
  grep -qE "^(- )?\\[$2\\] " <(sed -n '/^## Open/,/^## [A-Z]/p' "$1/docs/Backlog.md")
}

# The canonical state of the backlog as origin sees it (source of truth). Fetch
# first so $WORK's origin/main reflects pushes the OTHER clone made.
origin_backlog() { git -C "$WORK" fetch -q origin; git -C "$WORK" show origin/main:docs/Backlog.md; }

# Count commits on origin/main whose subject contains the needle (fetch first).
origin_commit_count() { git -C "$WORK" fetch -q origin; git -C "$WORK" log origin/main --format='%s' | grep -c "$1"; }


# T1 — two clones, two items: each real driver claims a DIFFERENT item and
# completes it. Neither re-touches the other's item; both completions land on
# origin. This is the "two daemons anywhere" guarantee a single clone can't show.
@test "two clones each claim a different item — no collision, both land on origin" {
  seed_and_clone_b "- [ ] alpha task" "- [ ] beta task"
  make_claude_complete_push

  # A ticks first: claims + completes the first open item (alpha).
  cd "$WORK";   run_tick
  [ "$status" -eq 0 ]

  # B ticks: fetches A's completion, then claims + completes the NEXT open
  # item (beta) — it must not see alpha as available.
  cd "$WORK_B"; run_tick
  [ "$status" -eq 0 ]

  # Origin is the arbiter: both done, each completed exactly once.
  local backlog; backlog="$(origin_backlog)"
  [[ "$backlog" == *"[x] alpha task"* ]]
  [[ "$backlog" == *"[x] beta task"* ]]
  [ "$(origin_commit_count 'work: did the thing')" -eq 2 ]
  # No item left mid-flight on either side.
  ! open_marker_in "$WORK_B" '~'
}

# T2 — same single item: the first clone wins it; the second sees it already
# done and idles. The item is worked exactly once (no double-work).
@test "a completed item is not re-worked by the other clone — one winner" {
  seed_and_clone_b "- [ ] solo task"
  make_claude_complete_push

  cd "$WORK"; run_tick
  [ "$status" -eq 0 ]

  rm -f "$CLAUDE_CALLED"            # forget A's invocation before B ticks
  cd "$WORK_B"; run_tick
  [ "$status" -eq 0 ]
  ! claude_was_called              # B found no open item -> heartbeat only
  [[ "$output" == *"no open items"* ]]

  [[ "$(origin_backlog)" == *"[x] solo task"* ]]
  [ "$(origin_commit_count 'work: did the thing')" -eq 1 ]   # worked once, not twice
}

# T3 — cross-machine reaper handoff. Clone A really claims the item (stamping its
# host) and then "dies" (no further ticks/heartbeats). Clone B ticks while A's D1
# heartbeat reports dead: the TTL reaper frees the [~], pushes a STANDALONE
# "reclaim:" commit, then re-claims and completes the item. Asserting the item
# ends [x] proves the reclaim-before-claim ordering held — had reclaim and claim
# been bundled, the [~]->[ ]->[~] would net a zero diff, the claim push would be
# skipped, and the item would never reach [x].
@test "a dead clone's claim is reaped + handed off, reclaim kept as its own commit" {
  seed_and_clone_b "- [ ] handoff task"

  # A claims (real tick, noop claude leaves it [~]) and pushes; then goes silent.
  make_curl live                   # A's own claim tick: nothing stale to probe
  make_claude noop
  cd "$WORK"; run_tick
  [ "$status" -eq 0 ]
  open_marker_in "$WORK" '~'                         # A holds the claim locally
  [[ "$(origin_backlog)" == *"[~] handoff task"* ]]  # and it reached origin

  # B ticks: A's heartbeat is dead -> reaper frees + B finishes the work.
  make_curl dead
  make_claude_complete_push
  cd "$WORK_B"; run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaim"* ]]

  local backlog; backlog="$(origin_backlog)"
  [[ "$backlog" == *"[x] handoff task"* ]]           # B took over and finished it
  [ "$(origin_commit_count 'reclaim:')" -ge 1 ]      # reclaim pushed as its own commit

  # And the dead clone A, on its next fetch, converges on B's completion.
  git -C "$WORK" fetch -q origin
  [[ "$(git -C "$WORK" show origin/main:docs/Backlog.md)" == *"[x] handoff task"* ]]
}
