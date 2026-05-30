#!/usr/bin/env bash
# Run the backlog-agent test suite: shellcheck (if available) + bats.
# Self-bootstrapping: uses a system `bats` if present, else a vendored copy
# cloned into test/vendor/bats-core (gitignored). No global install needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

REPO_ROOT="$(cd .. && pwd)"

# --- shellcheck (lint the shell scripts) ---
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  # BLOCKING, matching CI (.github/workflows/test.yml) — the warnings are cleared
  # (#54), so a new one is a real regression and should fail the canary. SC1091:
  # don't follow the sourced _lib.sh. set -e propagates a non-zero shellcheck.
  shellcheck -e SC1091 -S warning \
    "$REPO_ROOT/bin/backlog-agent" "$REPO_ROOT/bin/_lib.sh" \
    "$REPO_ROOT/bin/backlog-agents" "$REPO_ROOT/bin/backlog-secret-scan" \
    "$REPO_ROOT/bin/backlog-snapshot.sh" "$REPO_ROOT/bin/dev-projects"
else
  echo "== shellcheck not installed — skipping lint (brew install shellcheck) =="
fi

# --- bats (behavioral tests) ---
BATS="$(command -v bats || true)"
if [ -z "$BATS" ]; then
  if [ ! -x vendor/bats-core/bin/bats ]; then
    echo "== vendoring bats-core =="
    mkdir -p vendor
    git clone --depth 1 https://github.com/bats-core/bats-core vendor/bats-core
  fi
  BATS="$PWD/vendor/bats-core/bin/bats"
fi

echo "== bats ($("$BATS" --version)) =="

# Run tests in parallel when GNU parallel is available (each test is hermetic —
# its own $BATS_TEST_TMPDIR + redirected $HOME, see helpers.bash). Fall back to
# serial on hosts without GNU parallel so the canary still runs everywhere.
# Override the job count with BATS_JOBS; set BATS_JOBS=1 to force serial.
JOBS="${BATS_JOBS:-$(command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu || nproc 2>/dev/null || echo 1)}"
if [ "$JOBS" -gt 1 ] && command -v parallel >/dev/null 2>&1; then
  echo "== running ${JOBS}-way parallel (GNU parallel) =="
  exec "$BATS" -j "$JOBS" "$PWD"/*.bats
fi
echo "== running serially (set BATS_JOBS>1 + install GNU parallel to parallelize) =="
exec "$BATS" "$PWD"/*.bats
