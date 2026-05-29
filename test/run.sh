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
  # SC1091: don't follow sourced _lib.sh; SC2310/2311: set -e + function-in-if
  # are idiomatic here. Tighten over time.
  shellcheck -e SC1091 -S warning "$REPO_ROOT/bin/backlog-agent" "$REPO_ROOT/bin/_lib.sh" || {
    echo "shellcheck reported issues (non-fatal for now)"; }
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
exec "$BATS" "$PWD"/*.bats
