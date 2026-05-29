#!/usr/bin/env bats
#
# `backlog-lint.mjs` — standalone Backlog.md schema linter.
# Each test writes a throwaway fixture into $BATS_TEST_TMPDIR and invokes
# `node bin/backlog-lint.mjs <fixture>`, asserting the exit code + report.

LINT="${BATS_TEST_DIRNAME}/../bin/backlog-lint.mjs"

# Write a canonical, well-formed backlog to $1.
write_valid() {
  cat > "$1" <<'EOF'
# Project — Backlog

Intro prose that mentions a `- [x]` marker inline; not a list item.

## Thinking
- [ ] a parked idea

## Open
- [ ] first open item
- [!] answered, ready to retry
- [~] claimed item

## In progress
- [~] something in flight

## Blocked
- [?] waiting on a decision

## Done
- [x] a finished item
EOF
}

# 1. A valid backlog lints clean (exit 0).
@test "valid backlog → exit 0" {
  fx="$BATS_TEST_TMPDIR/valid.md"
  write_valid "$fx"
  run node "$LINT" "$fx"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# 2. Sections out of canonical order → exit 1.
@test "out-of-order sections → exit 1" {
  fx="$BATS_TEST_TMPDIR/order.md"
  cat > "$fx" <<'EOF'
# Project — Backlog

## Open
- [ ] an open item

## Thinking
- [ ] a parked idea

## Done
- [x] done
EOF
  run node "$LINT" "$fx"
  [ "$status" -eq 1 ]
  [[ "$output" == *"section order"* ]]
}

# 3. An invalid marker → exit 1.
@test "bad marker → exit 1" {
  fx="$BATS_TEST_TMPDIR/marker.md"
  cat > "$fx" <<'EOF'
# Project — Backlog

## Open
- [z] this marker is not valid
EOF
  run node "$LINT" "$fx"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad marker"* ]]
}

# 4. A duplicate title within Open → exit 1.
@test "duplicate Open title → exit 1" {
  fx="$BATS_TEST_TMPDIR/dup.md"
  cat > "$fx" <<'EOF'
# Project — Backlog

## Open
- [ ] wire up the thing
- [ ] another item
- [ ] wire up the thing

## Done
- [x] done
EOF
  run node "$LINT" "$fx"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate Open title"* ]]
}

# 5. An obviously-malformed "- [" line → exit 1.
@test "malformed checkbox-like line → exit 1" {
  fx="$BATS_TEST_TMPDIR/malformed.md"
  cat > "$fx" <<'EOF'
# Project — Backlog

## Open
- [ this bracket never closes properly
EOF
  run node "$LINT" "$fx"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed item"* ]]
}

# 6. A missing file is reported and exits 1 (no crash).
@test "missing file → exit 1" {
  run node "$LINT" "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read"* ]]
}

# 7. The repo's own docs/Backlog.md lints clean (real-world smoke test).
@test "repo docs/Backlog.md is well-formed" {
  run node "$LINT" "${BATS_TEST_DIRNAME}/../docs/Backlog.md"
  [ "$status" -eq 0 ]
}
