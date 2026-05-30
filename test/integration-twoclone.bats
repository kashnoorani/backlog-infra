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
#   * the true *concurrent* CAS push-rejection race — both clones commit a claim
#     off the SAME base, one push lands, the other is rejected → rebase-conflict
#     → reset --hard to origin (one winner, no double-work)                    (T4)
#
# T4 reaches that window deterministically via the driver's `_inject_fault` hook
# (#54 part c): the losing tick is paused between its claim COMMIT and its claim
# PUSH (INJECT_FAULT=claim_pre_push:<barrier>) so the winner's push lands first.
# Without the pause the loser always *fetches* the winner's claim before it would
# push and takes the benign skip/handoff path instead of the reset path. The
# single-clone reset-on-divergence recovery is also covered in tick.bats
# ("diverged local HEAD is reset to origin").
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

# T4 — the true CONCURRENT CAS push-rejection race (the part-(c) keystone). Both
# clones claim the SAME item off the SAME base; B is paused between its claim
# COMMIT and its claim PUSH (INJECT_FAULT=claim_pre_push) so A's claim+completion
# reach origin first. When B is released its push is a genuine non-fast-forward
# rejection → B rebases, conflicts on the same backlog line, and reset --hard's to
# origin. That reset-on-divergence path is exactly what sequential ticks can't
# reach (the loser would otherwise fetch A's claim before pushing and skip
# benignly). Asserts: one winner, the item worked exactly once, B's claim never
# lands, and B converges on origin with no stuck [~].
@test "concurrent claim race: the rejected pusher rebase-conflicts and resets to origin" {
  seed_and_clone_b "- [ ] solo task"
  make_curl live                     # neither tick has a stale claim to probe
  make_claude_complete_push          # A claims + completes + pushes (B never reaches claude)

  local barrier="$BATS_TEST_TMPDIR/release-b"
  local b_out="$BATS_TEST_TMPDIR/b_tick.out"

  # B must claim under a DIFFERENT host identity than A. Both clones otherwise run
  # on this one test host, so their claim lines (`[~] … <!-- @host -->`) are
  # byte-identical and B's rebased claim is dropped as already-applied — the
  # benign "rebase + retry" path, not the conflict we're testing. Production
  # clones are different machines; emulate that with a B-only `hostname` shim so
  # B's owner stamp differs and the rebase genuinely conflicts → reset to origin.
  local bshim="$BATS_TEST_TMPDIR/shim-b"
  mkdir -p "$bshim"
  printf '#!/usr/bin/env bash\necho clone-b-host\n' > "$bshim/hostname"
  chmod +x "$bshim/hostname"

  # B starts first and parks AFTER committing its claim, BEFORE pushing it.
  # 3>&- closes bats's status FD in the background job so `wait` can't hang.
  ( cd "$WORK_B" && PATH="$bshim:$PATH" \
      INJECT_FAULT="claim_pre_push:$barrier" INJECT_FAULT_TIMEOUT=30 \
      "$AGENT_BIN" tick >"$b_out" 2>&1 3>&- ) &
  local b_pid=$!

  # Wait until B has committed its claim (i.e. it is parked at the barrier).
  local waited=0
  until git -C "$WORK_B" log -1 --format='%s' 2>/dev/null | grep -q '^claim: solo task'; do
    sleep 0.1
    waited=$((waited + 1))
    [ "$waited" -ge 300 ] && break    # 30s safety net
  done
  git -C "$WORK_B" log -1 --format='%s' | grep -q '^claim: solo task'  # B really parked

  # A ticks to completion while B is parked: A's claim + completion reach origin.
  cd "$WORK"; run_tick
  [ "$status" -eq 0 ]

  # Release B into a now-guaranteed rejected push, and let its tick finish.
  touch "$barrier"
  wait "$b_pid"; local b_rc=$?
  [ "$b_rc" -eq 0 ]                                   # claim-lost path returns 0

  # B took the reset-on-divergence recovery, not the benign skip/handoff.
  grep -q 'reset to origin' "$b_out"

  # Origin is the arbiter: A won the item; it was completed exactly once and B's
  # losing claim never landed.
  local backlog; backlog="$(origin_backlog)"
  [[ "$backlog" == *"[x] solo task"* ]]
  [ "$(origin_commit_count 'work: did the thing')" -eq 1 ]
  [ "$(origin_commit_count 'claim: solo task')" -eq 1 ]

  # B converged on origin (reset --hard): no stuck [~], HEAD == origin/main.
  ! open_marker_in "$WORK_B" '~'
  git -C "$WORK_B" fetch -q origin
  [ "$(git -C "$WORK_B" rev-parse HEAD)" = "$(git -C "$WORK_B" rev-parse origin/main)" ]
}
