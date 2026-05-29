#!/usr/bin/env bats
#
# `backlog-agents doctor` — preflight health check (W1).
# Runs against a fake $HOME so ACTIVE_ROOT / DOTFILES / LaunchAgents all
# relocate into a per-test scratch tree. doctor is read-only, so these never
# touch the real fleet.

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/dev/projects/active" "$HOME/dotfiles" "$HOME/.claude" \
           "$HOME/Library/LaunchAgents"
  : > "$HOME/dotfiles/active-projects.txt"
  printf '{ "projects": {} }\n' > "$HOME/.claude/backlog-budgets.json"
}

# Scaffold a well-formed project under the fake ACTIVE_ROOT.
mk_project() {
  local name="$1" root="$HOME/dev/projects/active/$1"
  mkdir -p "$root/.git" "$root/docs" "$root/scripts" "$root/.claude"
  printf '# b\n\n## Open\n' > "$root/docs/Backlog.md"
  printf '.claude/backlog-agent.log\n.claude/backlog-agent.lock/\n.claude/backlog-status.json\n' > "$root/.gitignore"
  printf 'process.exit(0)\n' > "$root/scripts/backlog-agent-status.mjs"
}

# Append a manifest entry for a project name.
add_manifest() {
  printf '%s\tgit@github.com:x/%s.git\n' "$1" "$1" >> "$HOME/dotfiles/active-projects.txt"
}

run_doctor() { run bash "$AGENTS_BIN" doctor; }

# 1. A clean, in-manifest project → no hard failures, exit 0.
@test "clean fixture passes" {
  mk_project tahoe; add_manifest tahoe
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"no hard failures"* ]]
  [[ "$output" == *"manifest present (1 project(s))"* ]]
}

# 2. Missing manifest → hard fail.
@test "missing manifest fails" {
  rm -f "$HOME/dotfiles/active-projects.txt"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"no manifest"* ]]
}

# 3. Manifest lists a project whose dir is absent → hard fail.
@test "manifest entry without a dir fails" {
  add_manifest ghost
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghost"* && "$output" == *"does not exist"* ]]
}

# 4. A project with a backlog that the manifest omits → warn, still exit 0.
@test "project missing from manifest warns but does not fail" {
  mk_project orphan   # not added to the manifest
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphan"* && "$output" == *"missing from the manifest"* ]]
}

# 5. Missing gitignore patterns → warn, exit 0.
@test "missing gitignore patterns warn" {
  mk_project tahoe; add_manifest tahoe
  printf 'node_modules/\n' > "$HOME/dev/projects/active/tahoe/.gitignore"  # drop the required patterns
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing gitignore pattern"* ]]
}

# 6. A status hook with a syntax error → hard fail.
@test "broken status hook fails" {
  mk_project tahoe; add_manifest tahoe
  printf 'this is ( not valid javascript {\n' > "$HOME/dev/projects/active/tahoe/scripts/backlog-agent-status.mjs"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"syntax error"* ]]
}

# 7. Invalid budgets JSON → hard fail.
@test "invalid budgets JSON fails" {
  mk_project tahoe; add_manifest tahoe
  printf 'not json at all\n' > "$HOME/.claude/backlog-budgets.json"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"budgets file is not valid JSON"* ]]
}
