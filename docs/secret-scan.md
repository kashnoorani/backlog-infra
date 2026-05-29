# Secret-scanning pre-push gate (P1 · W2)

A guard so a daemon (or a human) can **never push a secret** to a repo the
fleet manages. The guard-primitive consumer for the *tick-guard* primitive, but
with a twist the other guards don't have: **it must run BEFORE the push, not
after.**

## The crux: pre-push, not post-push

Every other W2 guard (circuit-breaker, diff-size, protected-path, per-tick
verification) is **POST-push** — it inspects `work_base..work_head` *after*
`claude -p` has already run `git push` from inside its own session, and only
*flags* or *reopens*. That model is fine for "this commit was too big" or "the
gate is red", because those are recoverable: the user reviews, the item
reopens, work continues.

It is **useless for secrets.** Once a key is pushed it is published — it may be
cached, forked, scraped, or indexed within seconds, and rewriting history
across every clone/machine is a hazard we've already rejected. A post-push
secret scan can only tell you the barn door is open after the horse is gone.

So the real gate intercepts **at the git layer, before the push leaves the
machine**. The daemon does *not* mediate claude's push (claude runs `git push`
itself), so the robust interception point is a git **`pre-push` hook**
(`.git/hooks/pre-push`) installed in every clone. The hook runs the scanner on
exactly the commits being pushed and **rejects the push (non-zero exit)** when a
secret is found — catching claude's own push, the daemon's claim/status pushes,
and a human's manual push uniformly.

The daemon's role is therefore **ensuring the hook is installed and current**,
not scanning after the fact.

```
 claude -p  ──►  git push  ──►  .git/hooks/pre-push  ──►  backlog-secret-scan --prepush
                                        │                        │
                                        │                  secret found? exit 1
                                        ▼                        │
                                 push REJECTED  ◄────────────────┘   (fail CLOSED)
```

A second, **post-push** scan still runs in `tick_once` (Guard 5) as
belt-and-suspenders: if a clone is somehow missing the hook (a brand-new
machine before its first ensure-on-tick, a hand-edited `.git/hooks`, `git push
--no-verify`), the daemon still **detects** the leak after the fact and
**alerts** loudly via the dead-man's-switch channel — it just can't prevent it.
Prevention is the hook; detection+alert is the guard.

## Components

| Piece | Where | Role |
|---|---|---|
| `backlog-secret-scan` | `bin/` (new, standalone) | the scanner — ONE source of truth for the regex set; callable by the hook, the driver, and the CLI. Dependency-light, no `_lib.sh` source. |
| `.git/hooks/pre-push` | each clone (per-machine, not version-controlled) | tiny stub: `exec backlog-secret-scan --prepush "$@"`. Carries a `(version N)` marker. |
| `ensure_prepush_hook` | `bin/backlog-agent` (driver) | top-of-tick self-heal: writes the hook if missing/stale (keyed by version). Best-effort; never aborts a tick. |
| Guard 5 (post-push scan) | `bin/backlog-agent` `tick_once` | belt-and-suspenders: scans `work_base..work_head`; on a hit → `log_event secret_detected` + `notify_send` (flag, like Guards 2/3 — no reopen). |
| `backlog-agents install-hooks` | `bin/backlog-agents` (CLI) | one-shot fleet-wide install (like `install-monitor`). `--force` to replace a foreign hook. |
| `doctor` "Pre-push secret gate" section | `bin/backlog-agents` | asserts every active repo has the current hook; warns on missing/stale/foreign. |

No D1 migration, no dashboard change — driver + CLI + per-clone git hooks only.
Propagates exactly like per-tick verification / the dead-man's-switch: push the
driver, `daemon-sync` restarts the 6 non-infra daemons (gated canary+skew), M3
pulls + canaries. The hook install rides the driver (ensure-on-tick) + a
one-time `install-hooks` per machine.

## The scanner (`backlog-secret-scan`)

Standalone bash. Modes:

- `--range <base> <head>` — scan the **added** lines of `base..head`'s diff.
- `--commit <sha>` — scan one commit's added lines (`git show`).
- `--prepush` — read the git pre-push **stdin protocol**
  (`<local ref> <local oid> <remote ref> <remote oid>` lines), compute the new
  commits per ref (`git rev-list <local> --not --remotes`, so we only scan what
  this push actually adds — not the whole history), and scan each. New-branch
  pushes (remote oid all-zero) and root commits are handled via `git show`,
  which works without a parent.
- `--staged` — scan staged changes (for a future pre-commit consumer; unused by
  the gate today).

Only **added** lines are scanned (`^\+`, excluding `^\+\+\+`), so unchanged
context and deletions never trip the gate.

### Scanner selection (DECISION: gitleaks-if-present + builtin fallback)

```
SECRET_SCANNER=auto (default)
  gitleaks on PATH?  → gitleaks (authoritative; honors .gitleaks.toml allowlist)
        else         → builtin high-confidence regex floor
  SECRET_SCANNER=builtin | gitleaks  forces one path (tests + emergencies)
```

`gitleaks` is the lighter, config-driven default when present (single binary,
fast, `.gitleaks.toml` allowlist). Neither machine currently has it installed —
which is exactly why the **builtin floor is mandatory**: the gate must never be
silently absent. A `gitleaks` *execution error* (not "found": a crash, a bad
config) falls back to the builtin floor rather than failing the gate open with
no floor.

### Builtin high-confidence regex set

Tuned for **low false-positive rate** (the gate fails closed, so a noisy rule
wedges real pushes). High-signal credential shapes only:

- AWS Access Key ID — `AKIA[0-9A-Z]{16}`
- PEM / OpenSSH private-key block — `-----BEGIN [A-Z ]*PRIVATE KEY-----`
- GitHub tokens — `ghp_ | gho_ | ghu_ | ghs_ | ghr_ | github_pat_…`
- OpenAI / Anthropic keys — `sk-… | sk-ant-…`
- Slack tokens — `xox[baprs]-…`
- Google API key — `AIza[0-9A-Za-z_\-]{35}`
- Stripe live secret — `sk_live_… | rk_live_…`
- Slack/Discord webhooks — `hooks.slack.com/services/… | discord(app)?.com/api/webhooks/…`

Generic high-entropy / "looks like a password=" assignment rules are
**deliberately excluded** from the builtin floor — too noisy for a
fail-closed gate. gitleaks (when present) carries the broader entropy ruleset.

### Allowlist / bypass (DECISION: allowlist, fail-closed on hit)

- **gitleaks path:** a committed `.gitleaks.toml` allowlist (its native
  mechanism).
- **builtin path:** an inline `pragma: allowlist secret` comment on the offending
  line (detect-secrets convention), OR a committed `.secret-scan-allow` file at
  the repo root (one extended-regex per line; a candidate line matching any
  allow-regex is ignored). Both are committed, so a vetted false positive is
  reviewable in history.

### Failure mode (DECISION: fail-closed on hit, fail-open on absent)

| Situation | Behaviour |
|---|---|
| secret found | **exit 1 — REJECT the push (fail CLOSED)** |
| clean | exit 0 |
| `git` ops fail / can't compute the range | warn + **exit 0 (fail OPEN)** — don't wedge the fleet on a git hiccup; the builtin floor still ran on whatever it could read |
| scanner binary missing (hook can't find `backlog-secret-scan`) | the hook warns + **exit 0 (fail OPEN)** — but ensure-on-tick keeps the scanner present, and the builtin floor means "no gitleaks" is never "no gate" |
| `SECRET_SCAN_DISABLE=1` | skip (tests / emergency override) |

We gate the daemon's OWN pushes too (claim/status/reclaim commits touch only
`docs/Backlog.md` + `.claude/`, low secret risk, but the hook catches every
push uniformly — no carve-out to reason about).

## The pre-push hook stub

```sh
#!/usr/bin/env bash
# backlog secret-scan pre-push gate (version 1) — auto-installed by backlog-agent; do not edit.
SCANNER="<abs path to bin/backlog-secret-scan, baked at install>"
[[ -x "$SCANNER" ]] && exec "$SCANNER" --prepush "$@"
command -v backlog-secret-scan >/dev/null 2>&1 && exec backlog-secret-scan --prepush "$@"
echo "backlog secret-scan: scanner not found on PATH; allowing push (fail-open)" >&2
exit 0
```

- The `(version N)` marker is how `ensure_prepush_hook` / `doctor` decide
  whether a hook is current. Bump `PREPUSH_HOOK_VERSION` in the driver when the
  stub changes; the next tick rewrites every clone's hook.
- A pre-existing pre-push hook that does **not** carry our marker is treated as a
  **foreign user hook**: ensure-on-tick and `install-hooks` leave it alone and
  warn (use `install-hooks --force` to replace). We never clobber a hook we
  didn't write.

## Install + propagation (DECISION: ensure-on-tick + doctor + install-hooks)

1. **ensure-on-tick** (self-healing): `tick_once` calls `ensure_prepush_hook`
   near the top. Writes the hook iff missing or the version marker differs.
   Cheap (one file write), best-effort, runs even on idle/heartbeat ticks so a
   clone never drifts.
2. **`backlog-agents install-hooks`**: explicit one-shot fleet-wide install for
   a fresh machine, so the gate is live before the first tick (and on repos that
   aren't daemon-driven).
3. **`doctor`**: a read-only assertion that every active repo carries the
   current hook — turns "is the gate installed everywhere?" into a glance.

## Tests (`test/secret-scan.bats`, hermetic)

Mirror `dead-mans-switch.bats` / `verification.bats`: shim the scanner + `git
push` on PATH.

- a planted AWS key in a pushed commit **rejects** the push (hook exits non-zero)
- a clean diff **passes**
- the **builtin-fallback** path detects a key when `gitleaks` is absent
- a shimmed `gitleaks` is **preferred** when present (dispatch)
- **absent scanner** → hook fails **open** (push allowed, loud warn)
- `.secret-scan-allow` / inline pragma **suppresses** a vetted false positive
- Guard 5 (post-push) **flags + alerts** when a secret lands without the hook
- `ensure_prepush_hook` writes a missing hook and rewrites a stale-version one,
  but **leaves a foreign hook** untouched
