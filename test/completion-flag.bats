#!/usr/bin/env bats
#
# Tests for the W0-foundation additions to bin/backlog-agent-status.mjs:
#   - completed (boolean) + completed_items (array of titles), detected by
#     diffing docs/Backlog.md across preHead..HEAD for [x] transitions
#   - repo_slug ("owner/repo" derived from the origin remote URL)
#   - full_commit (the FULL 40-char work-commit SHA, alongside the existing
#     short last_work_commit)
#
# Style mirrors test/status-hook.bats: hermetic fixture via _setup_status_repo,
# hook driven through run_hook (which passes --pre-head "$(... rev-parse HEAD)").

load 'helpers'

setup() { _setup_status_repo; }

# Make a real work commit that flips the first non-done item in ## Open to [x],
# emulating a tick that completed an item. Returns nothing; mutates the work repo.
_complete_item_commit() {
  local title="$1"
  write_backlog_open_in "$WORK" "- [x] $title"
  echo work > "$WORK/work.txt"
  git -C "$WORK" add work.txt docs/Backlog.md
  git -C "$WORK" commit -qm "work: completed $title"
}

# A tick whose commit moved an item from [ ] → [x] across preHead..HEAD must
# report completed=true with the item title.
@test "completed=true with the title when an item moved to [x]" {
  # preHead is the init commit (item is "- [ ] do the thing").
  local pre; pre="$(git -C "$WORK" rev-parse HEAD)"
  _complete_item_commit "do the thing"

  run env node "$HOOK_BIN" --item "do the thing" --exit-code 0 --mode loop \
    --pre-head "$pre" --pulled 0
  [ "$status" -eq 0 ]

  [ "$(jq -r .completed "$WORK/.claude/backlog-status.json")" = "true" ]
  [ "$(jq -r '.completed_items | length' "$WORK/.claude/backlog-status.json")" = "1" ]
  [ "$(jq -r '.completed_items[0]' "$WORK/.claude/backlog-status.json")" = "do the thing" ]
  # History record mirrors it.
  grep -q '"completed":true' "$WORK/.claude/backlog-history.jsonl"
  grep -q '"do the thing"' "$WORK/.claude/backlog-history.jsonl"
}

# An idle/no-op tick (preHead == HEAD, nothing changed) → completed=false,
# completed_items empty.
@test "completed=false on an idle/no-op tick" {
  # run_hook passes --pre-head "$(rev-parse HEAD)", i.e. preHead == HEAD → idle.
  run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r .completed "$WORK/.claude/backlog-status.json")" = "false" ]
  [ "$(jq -r '.completed_items | length' "$WORK/.claude/backlog-status.json")" = "0" ]
}

# A tick that committed work but did NOT move any item to [x] → completed=false.
@test "completed=false when work landed but no item reached [x]" {
  local pre; pre="$(git -C "$WORK" rev-parse HEAD)"
  echo work > "$WORK/work.txt"
  git -C "$WORK" add work.txt
  git -C "$WORK" commit -qm "work: no completion"

  run env node "$HOOK_BIN" --item "do the thing" --exit-code 0 --mode loop \
    --pre-head "$pre" --pulled 0
  [ "$status" -eq 0 ]
  [ "$(jq -r .completed "$WORK/.claude/backlog-status.json")" = "false" ]
  [ "$(jq -r '.completed_items | length' "$WORK/.claude/backlog-status.json")" = "0" ]
}

# repo_slug is derived from the origin remote. The fixture's origin is a local
# bare path; point it at a github SSH URL and confirm owner/repo is extracted.
# We also drop the remote-tracking ref so the hook's push step is skipped
# (no upstream → no network attempt against the fake github URL).
@test "repo_slug derived from a github SSH origin remote" {
  git -C "$WORK" remote set-url origin "git@github.com:acme/widgets.git"
  git -C "$WORK" update-ref -d refs/remotes/origin/main
  run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r .repo_slug "$WORK/.claude/backlog-status.json")" = "acme/widgets" ]
  grep -q '"repo_slug":"acme/widgets"' "$WORK/.claude/backlog-history.jsonl"
}

# repo_slug also handles the https form.
@test "repo_slug derived from a github https origin remote" {
  git -C "$WORK" remote set-url origin "https://github.com/acme/gadgets.git"
  git -C "$WORK" update-ref -d refs/remotes/origin/main
  run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r .repo_slug "$WORK/.claude/backlog-status.json")" = "acme/gadgets" ]
}

# full_commit is the FULL 40-char SHA of the work commit, and last_work_commit
# stays the short 7-char form (both present).
@test "full_commit is the full 40-char SHA; short last_work_commit retained" {
  local pre; pre="$(git -C "$WORK" rev-parse HEAD)"
  _complete_item_commit "do the thing"
  local head; head="$(git -C "$WORK" rev-parse HEAD)"

  run env node "$HOOK_BIN" --item "do the thing" --exit-code 0 --mode loop \
    --pre-head "$pre" --pulled 0
  [ "$status" -eq 0 ]

  local full; full="$(jq -r .full_commit "$WORK/.claude/backlog-status.json")"
  [ "${#full}" -eq 40 ]
  [ "$full" = "$head" ]
  local short; short="$(jq -r .last_work_commit "$WORK/.claude/backlog-status.json")"
  [ "${#short}" -eq 7 ]
  [ "$short" = "${head:0:7}" ]
}

# full_commit is null on an idle tick (no work commit this tick).
@test "full_commit is null on an idle tick" {
  run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r .full_commit "$WORK/.claude/backlog-status.json")" = "null" ]
}
