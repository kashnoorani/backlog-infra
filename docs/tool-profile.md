# Deny-by-default autonomous tool/permission profile (threat-model §5)

**Status: SHIPPED behind a default-OFF flag (W1, 2026-05-30).** The PREVENTIVE
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

## Flip-on (later, greenlit)

Set `AUTONOMOUS_TOOL_PROFILE=1` for one project's daemon, observe a few ticks for
spurious denials (a legitimately-needed tool being blocked), then roll fleet-wide.
The profile is purely additive deny rules, so the failure mode is a *blocked* tick,
not a *runaway* one — fail-loud, easy to back out by clearing the flag.
