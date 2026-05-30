#!/usr/bin/env bats
#
# `backlog-agents sync` follower-update must RECONCILE monitor-churn divergence,
# not give up like a bare `pull --ff-only` (#53). The lead machine's monitor
# *rebases* origin as it sweeps (rewriting `monitor: sweep …` SHAs), so a
# follower that earlier ff-pulled now diverges and `pull --ff-only` fails
# forever — stranding the operator. _follower_reconcile mirrors the daemon's
# hardened pull pathway (fetch → reset --hard origin/<branch>) but ONLY for pure
# monitor-churn: two tripwires (clean tree + only `monitor:` commits ahead) gate
# the reset so real operator work is never nuked.
#
# Hermetic: a throwaway HOME with $ACTIVE_ROOT holding real clones + bare
# origins. The reconcile loop is driven via the side-effect-free seam
# `sync --projects-only` (no dotfiles, no kash_setup, no daemon restart, no
# gate) so launchctl/SSH/dotfiles are never touched.

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  ACTIVE="$HOME/dev/projects/active"
  mkdir -p "$ACTIVE"
}

# Create project $1 under $ACTIVE as a clone of a fresh bare origin on `main`,
# with one base commit. Exports ORIGIN_$1 and PROJ_$1-ish via echo'd paths.
mkrepo() {
  local name="$1"
  local origin="$BATS_TEST_TMPDIR/$name.git"
  local proj="$ACTIVE/$name"
  git -c init.defaultBranch=main init -q --bare "$origin"
  git -c init.defaultBranch=main init -q "$proj"
  git -C "$proj" config user.email t@e.co
  git -C "$proj" config user.name t
  git -C "$proj" config commit.gpgsign false
  printf 'base\n' > "$proj/file.txt"
  git -C "$proj" add file.txt
  git -C "$proj" commit -qm "base"
  git -C "$proj" remote add origin "$origin"
  git -C "$proj" push -q -u origin HEAD:main
}

# Commit a file change in repo $1 with subject $2 (no push) → local-only commit.
commit_local() {
  local proj="$ACTIVE/$1" subj="$2"
  printf '%s\n' "$subj" >> "$proj/file.txt"
  git -C "$proj" add file.txt
  git -C "$proj" commit -qm "$subj"
}

# Advance ORIGIN of repo $1 by pushing commit subject $2 from a side clone, so
# the follower's HEAD is now BEHIND or DIVERGED from origin.
advance_origin() {
  local name="$1" subj="$2"
  local origin="$BATS_TEST_TMPDIR/$name.git"
  local side="$BATS_TEST_TMPDIR/$name.side"
  rm -rf "$side"
  git clone -q "$origin" "$side"
  git -C "$side" config user.email s@e.co
  git -C "$side" config user.name s
  printf '%s\n' "origin-$subj" >> "$side/file.txt"
  git -C "$side" add file.txt
  git -C "$side" commit -qm "$subj"
  git -C "$side" push -q origin HEAD:main
}

head_sha() { git -C "$ACTIVE/$1" rev-parse HEAD; }
origin_sha() { git -C "$ACTIVE/$1" rev-parse "origin/main"; }

run_sync() { run bash "$AGENTS_BIN" sync --projects-only; }

# 1. Clean fast-forward (follower strictly behind) still works.
@test "clean fast-forward pulls the follower up to origin" {
  mkrepo p
  advance_origin p "monitor: sweep 1"
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"p (on main)"* ]]
  [ "$(head_sha p)" = "$(origin_sha p)" ]
}

# 2. Monitor-churn divergence: local has a monitor sweep, origin rewrote it →
#    ff-only fails → reconcile via reset --hard.
@test "monitor-churn divergence is reconciled to origin" {
  mkrepo p
  commit_local p "monitor: sweep 7"          # local-only monitor commit
  advance_origin p "monitor: sweep 7"        # origin's own (different SHA)
  local before; before="$(head_sha p)"
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconciled monitor-churn"* ]]
  [ "$(head_sha p)" = "$(origin_sha p)" ]
  [ "$(head_sha p)" != "$before" ]
}

# 3. Tripwire 1 — a dirty working tree is NEVER reset.
@test "dirty tree blocks the reconcile (leaves alone)" {
  mkrepo p
  commit_local p "monitor: sweep 7"
  advance_origin p "monitor: sweep 7"
  printf 'uncommitted operator edit\n' >> "$ACTIVE/p/file.txt"
  local before; before="$(head_sha p)"
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"working tree dirty"* ]]
  [ "$(head_sha p)" = "$before" ]          # HEAD untouched
}

# 4. Tripwire 2 — a non-monitor un-pushed commit is NEVER discarded.
@test "non-monitor ahead commit blocks the reconcile (leaves alone)" {
  mkrepo p
  commit_local p "feat: real operator work"   # NOT a monitor sweep
  advance_origin p "monitor: sweep 7"
  local before; before="$(head_sha p)"
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"non-monitor commit"* ]]
  [ "$(head_sha p)" = "$before" ]
}

# 5. SYNC_RECONCILE_DISABLE=1 forces the old warn-only behaviour.
@test "SYNC_RECONCILE_DISABLE falls back to warn+leave-alone" {
  mkrepo p
  commit_local p "monitor: sweep 7"
  advance_origin p "monitor: sweep 7"
  local before; before="$(head_sha p)"
  run env SYNC_RECONCILE_DISABLE=1 bash "$AGENTS_BIN" sync --projects-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"reconcile disabled"* ]]
  [ "$(head_sha p)" = "$before" ]
}

# 6. Already up to date — ff no-op, no reconcile.
@test "already-current follower is a clean no-op" {
  mkrepo p
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"p (on main)"* ]]
  [[ "$output" != *"reconciled"* ]]
}
