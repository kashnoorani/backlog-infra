#!/usr/bin/env bats
#
# Secret-scanning pre-push gate (W2, docs/secret-scan.md). Unlike Guards 1-4 (all
# POST-push flag/reopen), a secret gate must PREVENT the push — a published key
# can't be un-published. Prevention is a per-clone git pre-push HOOK that runs the
# scanner and rejects the push; a post-push Guard 5 in the driver is the
# belt-and-suspenders DETECT+alert for a clone missing the hook.
#
# Four surfaces under test:
#   - bin/backlog-secret-scan        the scanner (--range/--commit/--prepush; gitleaks
#                                    dispatch + builtin floor; allowlist; fail modes)
#   - .git/hooks/pre-push            real git rejection of a secret-bearing push
#   - bin/backlog-agent              ensure_prepush_hook (self-heal) + Guard 5 (flag)
#   - bin/backlog-agents             install-hooks (fleet-wide) + doctor
#
# Hermetic: a throwaway repo + local bare remote; the scanner is the REAL bin
# (no network). The canonical AWS docs example key (AKIAIOSFODNN7EXAMPLE) and a
# fake ghp_ token stand in for secrets — neither is a live credential.

load 'helpers'

SCAN="${BATS_TEST_DIRNAME}/../bin/backlog-secret-scan"
AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

AWS_KEY='AKIAIOSFODNN7EXAMPLE'
GH_TOKEN='ghp_0123456789012345678901234567890123ab'

# A throwaway git repo with a local bare remote, on PATH-less plain git. Sets
# SR_REMOTE, SR_WORK and cd's in. Lighter than _setup_repo (no claude/daemon).
_scan_repo() {
  SR_REMOTE="$BATS_TEST_TMPDIR/sr-remote.git"
  SR_WORK="$BATS_TEST_TMPDIR/sr-work"
  export GIT_TERMINAL_PROMPT=0
  export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
  git init -q --bare -b main "$SR_REMOTE"
  git init -q -b main "$SR_WORK"
  cd "$SR_WORK"
  echo seed > seed.txt && git add seed.txt && git commit -qm seed
  git remote add origin "$SR_REMOTE"
  git push -qu origin main
}

# ==========================================================================
# Scanner: bin/backlog-secret-scan
# ==========================================================================

@test "scanner: builtin --range flags an AWS key on an added line" {
  _scan_repo
  local base; base="$(git rev-parse HEAD)"
  echo "aws = $AWS_KEY" > leak.txt && git add leak.txt && git commit -qm leak
  run env SECRET_SCANNER=builtin "$SCAN" --range "$base" HEAD
  [ "$status" -eq 1 ]
  [[ "$output" == *"AKIA"* ]]
}

@test "scanner: builtin --range passes a clean diff" {
  _scan_repo
  local base; base="$(git rev-parse HEAD)"
  echo "just some prose, nothing secret" > ok.txt && git add ok.txt && git commit -qm ok
  run env SECRET_SCANNER=builtin "$SCAN" --range "$base" HEAD
  [ "$status" -eq 0 ]
}

@test "scanner: builtin --commit flags a single commit (incl. a PEM block)" {
  _scan_repo
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n' > id_key && git add id_key && git commit -qm key
  run env SECRET_SCANNER=builtin "$SCAN" --commit HEAD
  [ "$status" -eq 1 ]
}

@test "scanner: --prepush rejects a secret in the pushed range (existing branch)" {
  _scan_repo
  local remote_oid; remote_oid="$(git rev-parse HEAD)"
  echo "token = $GH_TOKEN" > t.txt && git add t.txt && git commit -qm tok
  local local_oid; local_oid="$(git rev-parse HEAD)"
  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$local_oid' '$remote_oid' | SECRET_SCANNER=builtin '$SCAN' --prepush"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PUSH REJECTED"* ]]
}

@test "scanner: --prepush scans only NEW commits on a new-branch push" {
  _scan_repo
  echo "k = $AWS_KEY" > nb.txt && git add nb.txt && git commit -qm nb
  local local_oid; local_oid="$(git rev-parse HEAD)"
  local zero=0000000000000000000000000000000000000000
  run bash -c "printf 'refs/heads/x %s refs/heads/x %s\n' '$local_oid' '$zero' | SECRET_SCANNER=builtin '$SCAN' --prepush"
  [ "$status" -eq 1 ]
}

@test "scanner: inline 'pragma: allowlist secret' suppresses a finding" {
  _scan_repo
  local base; base="$(git rev-parse HEAD)"
  echo "token = $GH_TOKEN # pragma: allowlist secret" > t.txt && git add t.txt && git commit -qm tok
  run env SECRET_SCANNER=builtin "$SCAN" --range "$base" HEAD
  [ "$status" -eq 0 ]
}

@test "scanner: a committed .secret-scan-allow regex suppresses a finding" {
  _scan_repo
  printf 'ghp_[A-Za-z0-9]{36}\n' > .secret-scan-allow && git add .secret-scan-allow && git commit -qm allow
  local base; base="$(git rev-parse HEAD)"
  echo "token = $GH_TOKEN" > t.txt && git add t.txt && git commit -qm tok
  run env SECRET_SCANNER=builtin "$SCAN" --range "$base" HEAD
  [ "$status" -eq 0 ]
}

@test "scanner: SECRET_SCAN_DISABLE=1 short-circuits to a clean pass" {
  _scan_repo
  local base; base="$(git rev-parse HEAD)"
  echo "aws = $AWS_KEY" > leak.txt && git add leak.txt && git commit -qm leak
  run env SECRET_SCAN_DISABLE=1 SECRET_SCANNER=builtin "$SCAN" --range "$base" HEAD
  [ "$status" -eq 0 ]
}

@test "scanner: a shimmed gitleaks is PREFERRED over the builtin floor (dispatch)" {
  _scan_repo
  local base; base="$(git rev-parse HEAD)"
  # A benign token the builtin floor would NOT flag, so a finding can only come
  # from gitleaks → proves dispatch chose gitleaks.
  echo "benign value here" > b.txt && git add b.txt && git commit -qm b
  local shim="$BATS_TEST_TMPDIR/glshim"; mkdir -p "$shim"
  cat > "$shim/gitleaks" <<'EOF'
#!/usr/bin/env bash
# Pretend to be gitleaks: always report a finding (exit 1).
exit 1
EOF
  chmod +x "$shim/gitleaks"
  run env PATH="$shim:$PATH" SECRET_SCANNER=auto "$SCAN" --range "$base" HEAD
  [ "$status" -eq 1 ]
}

# ==========================================================================
# Real pre-push hook rejection (end-to-end through git push)
# ==========================================================================

# Write a real pre-push gate into the cwd repo that execs the scanner ($SCAN).
_install_gate_here() {
  { printf '#!/usr/bin/env bash\n'; printf 'exec "%s" --prepush "$@"\n' "$SCAN"; } > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
}

@test "hook: installing the gate REJECTS a push carrying a secret" {
  _scan_repo
  _install_gate_here
  echo "aws = $AWS_KEY" > leak.txt && git add leak.txt && git commit -qm leak
  run env SECRET_SCANNER=builtin git push origin main
  [ "$status" -ne 0 ]
}

@test "hook: installing the gate ALLOWS a clean push" {
  _scan_repo
  _install_gate_here
  echo "benign content" > ok.txt && git add ok.txt && git commit -qm ok
  run env SECRET_SCANNER=builtin git push origin main
  [ "$status" -eq 0 ]
}

@test "hook: an absent scanner fails OPEN (push allowed, loud warn)" {
  _scan_repo
  cat > .git/hooks/pre-push <<'EOF'
#!/usr/bin/env bash
SCANNER="/nonexistent/backlog-secret-scan"
[[ -x "$SCANNER" ]] && exec "$SCANNER" --prepush "$@"
command -v backlog-secret-scan >/dev/null 2>&1 && exec backlog-secret-scan --prepush "$@"
echo "backlog secret-scan: scanner not found on PATH; allowing push (fail-open)" >&2
exit 0
EOF
  chmod +x .git/hooks/pre-push
  echo "aws = $AWS_KEY" > leak.txt && git add leak.txt && git commit -qm leak
  # Minimal PATH so the real backlog-secret-scan (on the dev PATH) is NOT found —
  # exercises the genuine "scanner absent" fail-open branch. git lives in /usr/bin.
  run env PATH="/usr/bin:/bin" git push origin main
  [ "$status" -eq 0 ]   # fails OPEN: the broken/absent scanner must not wedge pushes
}

# ==========================================================================
# Driver: ensure_prepush_hook (self-heal on tick)
# ==========================================================================

# True if $WORK's pre-push hook is our current-version gate.
_work_hook_is_ours() {
  grep -q "backlog secret-scan pre-push gate (version 1)" "$WORK/.git/hooks/pre-push" 2>/dev/null
}

@test "driver: a tick installs the pre-push gate when missing" {
  _setup_repo
  run_tick SECRET_SCAN_DISABLE=0
  [ "$status" -eq 0 ]
  [ -x "$WORK/.git/hooks/pre-push" ]
  _work_hook_is_ours
}

@test "driver: a tick OVERWRITES an empty (0-byte) pre-push hook" {
  _setup_repo
  : > "$WORK/.git/hooks/pre-push"          # the real-world empty no-op hook
  run_tick SECRET_SCAN_DISABLE=0
  _work_hook_is_ours
}

@test "driver: a tick LEAVES a foreign (non-empty, unmarked) hook untouched" {
  _setup_repo
  printf '#!/usr/bin/env bash\necho my own hook\nexit 0\n' > "$WORK/.git/hooks/pre-push"
  chmod +x "$WORK/.git/hooks/pre-push"
  run_tick SECRET_SCAN_DISABLE=0
  grep -q "my own hook" "$WORK/.git/hooks/pre-push"      # preserved
  ! _work_hook_is_ours                                   # NOT replaced
}

@test "driver: a tick REWRITES a stale-version ours hook" {
  _setup_repo
  cat > "$WORK/.git/hooks/pre-push" <<'EOF'
#!/usr/bin/env bash
# backlog secret-scan pre-push gate (version 0) — auto-installed by backlog-agent; do not edit.
exit 0
EOF
  chmod +x "$WORK/.git/hooks/pre-push"
  run_tick SECRET_SCAN_DISABLE=0
  _work_hook_is_ours                                     # bumped to version 1
}

# ==========================================================================
# Driver: Guard 5 (post-push flag + alert when the hook was bypassed/absent)
# ==========================================================================

# A curl shim that records notify POSTs to $HOME/.posted and answers the reaper's
# heartbeat read with 404 (fail-safe, no reclaim). Same shape as the DMS test.
_guard5_curl() {
  mkdir -p "$HOME/.config/backlog"; echo testkey > "$HOME/.config/backlog/health-key"
  : > "$HOME/.posted"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
data=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in --data|-d) data="$a";; esac
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
case "$url" in
  *heartbeat*) printf '%s\n%s' '{"found":false}' 404 ;;
  *)           printf '%s\n' "$data" >> "$HOME/.posted"; printf '%s\n%s' ok 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

_notify_slack() {
  mkdir -p "$HOME/.claude"
  printf '{ "slack_webhook_url": "http://localhost/slack-SECRET", "email": "", "local_notify": false }\n' \
    > "$HOME/.claude/agent-notify.json"
}

# A claude stub that completes the item but SNEAKS a secret past the hook
# (git push --no-verify) — emulating a clone whose pre-push hook is absent/bypassed.
_make_claude_secret_bypass() {
  cat > "$SHIM/claude" <<EOF
#!/usr/bin/env bash
touch "\${CLAUDE_CALLED:-/dev/null}"
AWS="$AWS_KEY"
EOF
  cat >> "$SHIM/claude" <<'EOF'
awk '
  BEGIN{in_open=0; done=0}
  /^## Open/{in_open=1; print; next}
  /^## [A-Z]/{in_open=0; print; next}
  in_open && !done && /^(- )?\[~\] /{ sub(/\[~\]/,"[x]"); done=1 }
  {print}
' docs/Backlog.md > docs/Backlog.md.tmp && mv docs/Backlog.md.tmp docs/Backlog.md
echo "aws_key = $AWS" > leaked.txt
git add leaked.txt docs/Backlog.md
git commit -qm "work: leaked a secret"
git push --no-verify origin main >/dev/null 2>&1 || true
exit 0
EOF
  chmod +x "$SHIM/claude"
}

@test "driver: Guard 5 flags + alerts when a pushed commit carries a secret" {
  _setup_repo
  _guard5_curl
  _notify_slack
  _make_claude_secret_bypass
  run_tick SECRET_SCAN_DISABLE=0 SECRET_SCANNER=builtin
  [ "$status" -eq 0 ]
  # Structured event recorded …
  grep -q '"event":"secret_detected"' "$WORK/.claude/backlog-agent-events.jsonl"
  # … and an alert pushed to the notify channel.
  for i in $(seq 1 30); do [ -s "$HOME/.posted" ] && break; sleep 0.1; done
  grep -q "SECRET LEAK" "$HOME/.posted"
}

@test "driver: Guard 5 stays quiet on a clean completing tick" {
  _setup_repo
  _guard5_curl
  _notify_slack
  make_claude complete            # commits implemented.txt — no secret
  run_tick SECRET_SCAN_DISABLE=0 SECRET_SCANNER=builtin
  [ "$status" -eq 0 ]
  ! grep -q '"event":"secret_detected"' "$WORK/.claude/backlog-agent-events.jsonl" 2>/dev/null
  ! grep -q "SECRET LEAK" "$HOME/.posted" 2>/dev/null
}

# ==========================================================================
# CLI: backlog-agents install-hooks (fleet-wide)
# ==========================================================================

# Build a tiny fake fleet of clones under a scratch HOME/ACTIVE_ROOT.
_fake_fleet() {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  FF_ACTIVE="$HOME/dev/projects/active"; mkdir -p "$FF_ACTIVE"
  export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
  local p
  for p in alpha beta; do
    git init -q -b main "$FF_ACTIVE/$p"
    ( cd "$FF_ACTIVE/$p" && echo x > a && git add a && git commit -qm init )
  done
}

@test "install-hooks: installs the gate across the fleet (and is idempotent)" {
  _fake_fleet
  run env ACTIVE_ROOT="$FF_ACTIVE" bash "$AGENTS_BIN" install-hooks
  [ "$status" -eq 0 ]
  grep -q "backlog secret-scan pre-push gate (version 1)" "$FF_ACTIVE/alpha/.git/hooks/pre-push"
  grep -q "backlog secret-scan pre-push gate (version 1)" "$FF_ACTIVE/beta/.git/hooks/pre-push"
  # second run: already current, nothing reinstalled
  run env ACTIVE_ROOT="$FF_ACTIVE" bash "$AGENTS_BIN" install-hooks
  [[ "$output" == *"already current"* ]]
}

@test "install-hooks: leaves a foreign hook unless --force" {
  _fake_fleet
  printf '#!/usr/bin/env bash\necho mine\n' > "$FF_ACTIVE/alpha/.git/hooks/pre-push"
  chmod +x "$FF_ACTIVE/alpha/.git/hooks/pre-push"
  run env ACTIVE_ROOT="$FF_ACTIVE" bash "$AGENTS_BIN" install-hooks
  grep -q "mine" "$FF_ACTIVE/alpha/.git/hooks/pre-push"              # preserved
  ! grep -q "secret-scan pre-push gate" "$FF_ACTIVE/alpha/.git/hooks/pre-push"
  run env ACTIVE_ROOT="$FF_ACTIVE" bash "$AGENTS_BIN" install-hooks --force
  grep -q "backlog secret-scan pre-push gate (version 1)" "$FF_ACTIVE/alpha/.git/hooks/pre-push"  # replaced
}
