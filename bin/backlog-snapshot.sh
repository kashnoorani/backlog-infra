#!/usr/bin/env bash
#
# backlog-snapshot.sh — off-repo safety net for docs/Backlog.md.
#
# The backlog is the single source of truth and is mutated by autonomous
# agents; one bad pull once dropped 2,033 lines. Git is the durable history,
# but an explicit, *off-repo* copy makes "an agent nuked the backlog" a
# one-command restore instead of git archaeology.
#
# Snapshots are written OUTSIDE the repo, so no .gitignore entry is needed:
#
#   $HOME/.claude/backlog-snapshots/<project>/<UTC-timestamp>.md
#
# where <project> is the basename of the git toplevel (falling back to the
# current working directory if not in a git repo).
#
# Usage:
#   backlog-snapshot.sh                 # take a snapshot of the current backlog
#   backlog-snapshot.sh --restore-latest  # print path of the newest snapshot
#
# --restore-latest only PRINTS the path; it never overwrites the working file,
# so a restore is always a deliberate copy by the caller.
#
# Retention: keep the most recent 60 snapshots per project; older ones are
# pruned on each new snapshot.

set -euo pipefail

KEEP=60

# Where snapshots live (overridable for tests via $HOME).
snapshots_root() {
  printf '%s/.claude/backlog-snapshots' "$HOME"
}

# Resolve the project name: basename of the git toplevel, else basename of cwd.
project_name() {
  local top
  if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
    basename "$top"
  else
    basename "$PWD"
  fi
}

# Locate the backlog file, mirroring the driver's polyglot discovery:
#   docs/Backlog.md (canonical) -> Backlog.md (repo root) -> backlog.txt (legacy)
# Resolved relative to the git toplevel if available, else cwd.
backlog_file() {
  local base
  if base="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$base" ]; then
    :
  else
    base="$PWD"
  fi
  local candidate
  for candidate in "docs/Backlog.md" "Backlog.md" "backlog.txt"; do
    if [ -f "$base/$candidate" ]; then
      printf '%s/%s' "$base" "$candidate"
      return 0
    fi
  done
  return 1
}

# Directory holding this project's snapshots.
project_dir() {
  printf '%s/%s' "$(snapshots_root)" "$(project_name)"
}

# Print the path of the newest snapshot for this project (highest timestamp).
latest_snapshot() {
  local dir
  dir="$(project_dir)"
  [ -d "$dir" ] || return 1
  # Names are UTC timestamps (YYYYmmddTHHMMSSZ.md), so lexical sort == chrono.
  local newest=""
  local f
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    newest="$f"
  done
  [ -n "$newest" ] || return 1
  printf '%s' "$newest"
}

# Remove all but the most recent $KEEP snapshots for this project.
prune_snapshots() {
  local dir
  dir="$(project_dir)"
  [ -d "$dir" ] || return 0
  local -a files=()
  local f
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    files+=("$f")
  done
  local count=${#files[@]}
  if [ "$count" -le "$KEEP" ]; then
    return 0
  fi
  # files[] is lexically (== chronologically) sorted ascending by the glob,
  # so the oldest are at the front.
  local remove=$(( count - KEEP ))
  local i
  for (( i = 0; i < remove; i++ )); do
    rm -f "${files[$i]}"
  done
}

take_snapshot() {
  local src
  if ! src="$(backlog_file)"; then
    echo "backlog-snapshot: no backlog file found (looked for docs/Backlog.md, Backlog.md, backlog.txt)" >&2
    return 1
  fi
  local dir
  dir="$(project_dir)"
  mkdir -p "$dir"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local dest="$dir/$ts.md"
  # Avoid clobbering within the same second on rapid successive calls.
  if [ -e "$dest" ]; then
    dest="$dir/${ts}-$$.md"
  fi
  cp "$src" "$dest"
  prune_snapshots
  printf '%s\n' "$dest"
}

main() {
  case "${1:-}" in
    --restore-latest)
      local latest
      if latest="$(latest_snapshot)"; then
        printf '%s\n' "$latest"
        return 0
      fi
      echo "backlog-snapshot: no snapshots found for project '$(project_name)'" >&2
      return 1
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      return 0
      ;;
    "")
      take_snapshot
      ;;
    *)
      echo "backlog-snapshot: unknown argument: $1" >&2
      echo "usage: backlog-snapshot.sh [--restore-latest]" >&2
      return 2
      ;;
  esac
}

main "$@"
