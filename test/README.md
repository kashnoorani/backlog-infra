# backlog-agent tests

Behavioral tests for the fleet driver (`bin/backlog-agent`) — the W0 foundation
that makes every later driver change safe to land (see `docs/Backlog.md`).

## Run

```sh
test/run.sh
```

Self-bootstrapping: uses a system `bats` if present, else clones `bats-core`
into `test/vendor/` (gitignored). No global install required. Lints with
`shellcheck` if it's installed (`brew install shellcheck`).

## How it works

Each test (`*.bats`) runs against a **hermetic fixture** built in a per-test
temp dir by `_setup_repo` in `helpers.bash`:

- a throwaway **work repo** + a local **bare remote** (`origin`) — no network,
  no GitHub;
- a **no-op status hook** (`scripts/backlog-agent-status.mjs` → `exit 0`) so
  ticks don't push real status;
- PATH **shims** for `claude` and `ssh` so the driver never reaches the real
  tools. `make_claude <mode>` swaps the claude stub per test
  (`noop` | `complete` | `fail_limit` | `fail_other`); `CLAUDE_CALLED` records
  whether claude ran.

Tests drive the real entry point black-box: `backlog-agent tick`.

## Coverage (current)

`tick.bats` — the deterministic §5/§10 invariants:

1. idle tick → claude not invoked
2. active cooldown → claude not invoked (short-circuit)
3. plan-limit output → arms cooldown **and** unclaims
4. generic failure → unclaims, no cooldown
5. successful tick → completion accepted (item `[x]`), not unclaimed
6. stale `[~]` + `STARTUP_RECLAIM` → reclaim recorded
7. diverged HEAD + conflict → `reset --hard origin` recovery

## TODO

- **Concurrent claim-race** (two daemons push the same `claim:` → one wins,
  loser `reset --hard`s). Needs a concurrency harness; test 7 covers the
  divergence-recovery primitive it relies on, deterministically.
- **`--inject-fault` mode** in the driver (kill mid-claim, simulate rejected
  push) to exercise more §10 paths directly.
- **Portability:** `reclaim_stale_claims` uses `sed -i ''` (BSD-only) while
  claim/unclaim use the portable `_local_awk_inplace` — a latent bug for any
  Linux run. The harness will catch it once tests also run on Linux.
