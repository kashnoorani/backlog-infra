# Deny-by-default autonomous tool/permission profile (threat-model §5)

**Status: SHIPPED; default-OFF, flipped on per project via a marker file (W1,
2026-05-30). See [Flip-on](#flip-on-greenlit-canary-first).** The PREVENTIVE
input-side complement to the already-shipped Guard 7 (`_relocate_injected_open_items`)
and the §4.3 untrusted-content prompt firewall. See `docs/threat-model.md` §5.

## Problem

The autonomous daemon runs `claude -p` with the user's **full interactive
permissions**. The §4 input-side guards harden the *prompt* (firewall clause +
forcing agent-added `## Open` items into `## Thinking`), but they are prompt-level
and detective. If a poisoned instruction nonetheless slips through, an
indirect-injected tick could still exfiltrate secrets, egress to the network, or
rewrite the shared driver — with full authority. §5 closes that by running the
autonomous tick under a **tighter tool/permission profile** than the human-in-the-loop
interactive session.

## Mechanism

When `AUTONOMOUS_TOOL_PROFILE=1`, the driver injects a generated `--settings` JSON
string into the `claude -p` invocation (`bin/backlog-agent`, the `agent_cmd` block).
The JSON is built by `build_tool_profile_settings` (jq-free; rule strings are simple,
no escaping needed) and contains **only** `permissions.deny`:

```json
{"permissions":{"deny":[ … ]}}
```

Two deliberate choices:

- **deny-only, no `defaultMode`/`allow`.** `--settings` *layers* onto the daemon's
  existing config, and `permissions.deny` always wins over `allow`. Emitting only
  deny rules adds the constraints without disturbing the headless auto-accept the
  daemon relies on (a `claude -p` tick can't pause for an interactive permission
  prompt) or its git allow-list.
- **opt-in, default OFF.** Unlike the default-enabled `*_DISABLE` feature flags,
  this one is the inverse: `AUTONOMOUS_TOOL_PROFILE` defaults to `0`. A too-broad
  deny rule would *silently* break ticks (a tool the daemon legitimately needs gets
  denied), so the profile ships off and is flipped on per-project under observation.

## Deny classes

1. **Network egress** — `WebFetch`, `WebSearch` (the model's native network tools)
   plus the common Bash exfil commands `Bash(curl:*)` / `Bash(wget:*)` /
   `Bash(nc:*)` / `Bash(ncat:*)` / `Bash(telnet:*)`. A true git-remotes+D1-only
   *allowlist* is **not** expressible in the permission schema, and a blanket
   no-network Bash sandbox (via `--add-dir`) would break the daemon's `git push`.
   Residual egress (e.g. a `python -c` socket) is left to the **secret-scan pre-push
   + diff-size** output-side guards. Cuts T1/T2.
2. **Secret-path reads** — `Read(~/.ssh/**)`, `Read(~/.aws/**)`, `Read(~/.gnupg/**)`,
   `Read(~/.config/backlog/**)` (the `health-key`), and `.env` (`Read(.env)` /
   `Read(./.env)` / `Read(**/.env)`). Cuts T1.
3. **Protected-path writes** — `Edit()` + `Write()` denied for each file in
   `PROTECTED_PATHS` (`bin/backlog-agent`, `bin/backlog-agent-status.mjs`,
   `release.mjs`, `CLAUDE.md`, `.gitignore`). This is the **preventive twin** of the
   detective Guard 3 (which *flags* a committed protected-path change post-hoc).
   Exact repo-relative names, so a project's own unrelated `bin/` tooling stays
   writable (per the user decision; not a blanket `bin/**` deny). Cuts T3/T4.

The deny set is derived from `PROTECTED_PATHS` so the preventive (§5) and detective
(Guard 3) twins stay in sync — edit one list, both follow.

## Scope / what's NOT done

- **Fallback agent unprofiled.** The Layer-3 cooldown-fallback agent is a different
  CLI; it is left unprofiled this slice (noted, low risk — it runs the same prompt
  but only when the Anthropic plan limit is hit).
- **No fleet flip-on yet.** This slice lands the profile behind the default-off flag
  with hermetic coverage only. Turning it on for a real project (then fleet-wide) is
  a SEPARATE greenlit step — at which point the live `permissions.deny` *matching
  semantics* for the `Edit()`/`Read()` path rules should be spot-checked against a
  real `claude -p` tick (the hermetic tests assert the injected JSON, not the CLI's
  enforcement of it).

## Telemetry

`log_event tool_profile_applied item <title>` fires each tick the profile is
injected (driver-only; no D1/dashboard surface).

## Tests

`test/tool-profile.bats` (9 cases), gated off by `AUTONOMOUS_TOOL_PROFILE=0` in
`test/helpers.bash` like the other feature flags. Cases assert: default-off injects
no `--settings`; enabled injects valid deny-only JSON (no `defaultMode`/`allow`); the
three deny classes are present; PROTECTED_PATHS Edit+Write coverage; composition with
`--max-budget-usd` (prompt stays last); and the telemetry event. Argv is captured via
a recording `claude` PATH shim (same pattern as `per-item-ceiling.bats`).

`test/tool-profile-flipon.bats` (7 cases) covers the flip-on machinery:
`tool_profile_plist_env` gates the launchd env snippet on the marker file;
`tool-profile --show` emits deny-only JSON; and `tool-profile --verify` reports PASS
against a `claude` shim that *enforces* the deny set and FAIL against one that
*ignores* it (proving the verify oracle detects both directions), plus the
missing-binary and unknown-arg error paths.

Note `build_tool_profile_settings` + `PROTECTED_PATHS` live in `bin/_lib.sh`, shared
by the driver (injection + detective Guard 3) and the CLI (`tool-profile`), so the
deny set has one definition.

## Flip-on (greenlit; canary-first)

The profile is flipped on **per project via a marker file**, so a canary can be
turned on one project at a time and the flag **survives a `sync`/reinstall** (which
regenerates the daemon plist). The deny set is purely additive, so the failure mode
is a *blocked* tick, not a *runaway* one — fail-loud, easy to back out.

**Mechanism:** `do_install_daemon` (`bin/backlog-agent`) calls
`tool_profile_plist_env` (`bin/_lib.sh`); if `<project>/.claude/tool-profile.on`
exists it threads `<key>AUTONOMOUS_TOOL_PROFILE</key><string>1</string>` into the
daemon plist's `EnvironmentVariables`. The daemon inherits the env from launchd and
the driver injects the constrained `--settings` on every tick. No marker ⇒ the plist
is byte-identical to the pre-flip form.

**Runbook (canary → fleet):**
1. **Prove enforcement first** (per CLI version): `backlog-agents tool-profile --verify`.
   Runs real one-off `claude -p` calls with the generated `--settings` and asserts a
   secret read (`.env`) and a `PROTECTED_PATHS` Edit are **REFUSED**, while a benign
   Read/Edit **SUCCEEDS** (deny is scoped, not a blanket block). This closes the gap
   the hermetic tests can't: they assert the injected JSON, not the CLI's enforcement.
   (`--show` prints the JSON.) Exits non-zero on any mismatch — do not flip on a FAIL.
2. **Canary one project:** `touch <project>/.claude/tool-profile.on`, then
   `(cd <project> && backlog-agent install-daemon)` to regenerate + reload the plist
   (or `launchctl kickstart -k gui/$(id -u)/com.$USER.<project>.backlog-agent`).
   Watch ≥1 real tick: `log_event tool_profile_applied` present, tick still completes,
   no spurious tool-denied failures in the item's work.
3. **Fleet-wide:** repeat the `touch` + reinstall for the remaining projects.
4. **Rollback:** `rm <project>/.claude/tool-profile.on` + reinstall (or kickstart). A
   too-broad deny is recoverable — the tick fails loud and the item is left unclaimed.
