#!/usr/bin/env bats
#
# `bin/backlog-snapshot.sh` — off-repo backlog safety net.
# Hermetic: $HOME is redirected to BATS_TEST_TMPDIR (canary.bats style) so
# snapshots land under a throwaway home, never the real ~/.claude. The script
# is run with `bash $SNAP_BIN` so it needs no executable bit.

SNAP_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-snapshot.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude"
  # A throwaway project repo with a canonical backlog.
  PROJ="$BATS_TEST_TMPDIR/proj/myproject"
  mkdir -p "$PROJ/docs"
  git init -q "$PROJ"
  git -C "$PROJ" config user.email t@e.co
  git -C "$PROJ" config user.name t
  printf '# myproject — Backlog\n\n## Open\n- [ ] do a thing\n' > "$PROJ/docs/Backlog.md"
  SNAP_DIR="$HOME/.claude/backlog-snapshots/myproject"
}

# Helper: run the snapshot tool from inside the project dir.
in_proj() { ( cd "$PROJ" && "$@" ); }

# 1. Taking a snapshot creates a file under the redirected HOME and prints it.
@test "snapshot creates a file under \$HOME and prints its path" {
  run in_proj bash "$SNAP_BIN"
  [ "$status" -eq 0 ]
  local path="$output"
  # Lands under the redirected HOME, keyed by project name.
  [[ "$path" == "$SNAP_DIR/"*.md ]]
  [ -f "$path" ]
  # Content matches the source backlog.
  diff "$PROJ/docs/Backlog.md" "$path"
}

# 2. --restore-latest prints the newest snapshot path (does not overwrite).
@test "--restore-latest prints the latest snapshot path" {
  run in_proj bash "$SNAP_BIN"
  [ "$status" -eq 0 ]
  local created="$output"

  run in_proj bash "$SNAP_BIN" --restore-latest
  [ "$status" -eq 0 ]
  [ "$output" = "$created" ]
  [ -f "$output" ]
  # Working file is untouched (no auto-overwrite).
  [ -f "$PROJ/docs/Backlog.md" ]
}

# 3. --restore-latest reflects the newest of multiple snapshots.
@test "--restore-latest returns the most recent of several snapshots" {
  in_proj bash "$SNAP_BIN" >/dev/null
  # Force a distinct, later timestamp so the newest is unambiguous.
  local later="$SNAP_DIR/20990101T000000Z.md"
  cp "$PROJ/docs/Backlog.md" "$later"

  run in_proj bash "$SNAP_BIN" --restore-latest
  [ "$status" -eq 0 ]
  [ "$output" = "$later" ]
}

# 4. --restore-latest with no snapshots fails cleanly.
@test "--restore-latest with no snapshots fails" {
  run in_proj bash "$SNAP_BIN" --restore-latest
  [ "$status" -ne 0 ]
}

# 5. Missing backlog file fails cleanly (no snapshot dir created with content).
@test "snapshot fails when no backlog file exists" {
  rm -f "$PROJ/docs/Backlog.md"
  run in_proj bash "$SNAP_BIN"
  [ "$status" -ne 0 ]
}
