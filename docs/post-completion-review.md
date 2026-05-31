# Post-completion review pass (Guard 8, W2)

A green build gate (Guard 4, per-tick verification) proves a completed tick
**builds**; it does not prove the committed diff **matches the item's stated
intent**. The canonical failure: a tick "edits the backlog" but also drops an
unrelated `[?]` blocked item — nothing breaks, so the build gate is blind. The
post-completion review closes that gap.

When enabled, after a tick **completes** an item (`[x]`) and survives the gate
and per-item ceiling, a cheap second agent (haiku) diffs `work_base..work_head`
against the item's title + body and judges:

1. does the diff fulfil the item's stated intent?
2. does it contain unrelated collateral changes?

On a flagged mismatch it **annotates only** — `log_event
post_completion_mismatch` + a `notify_send` alert. **The `[x] stands`** (no
reopen, no revert). This mirrors the flag-only siblings (diff-size Guard 2,
protected-path Guard 3, secret-scan Guard 5): we surface the signal for a human
and observe its quality before considering a veto.

## Where it runs

`post_completion_review()` in `bin/backlog-agent`, called from `tick_once()`
immediately after the Guard-1 failcount reset and before the work-diff guards
(2/3/5/7). It fires only when the tick **claimed**, **committed**, the item is
now `[x]` (`_completion_claimed`), and neither verification nor the ceiling
reopened it this tick — reviewing reopened or incomplete work would be noise.

## Enabling it (opt-in, canary-first)

Off by default (`POST_COMPLETION_REVIEW=0`) — the haiku call adds latency +
tokens to every completion, so the safe rollout is per-project canary first,
fleet later. Enable a project via a **per-machine marker outside the repo**
(same mechanism as the §5 tool profile — never committed, never propagates to
another machine):

```sh
mkdir -p ~/.claude/post-review
touch ~/.claude/post-review/<project>.on
(cd <project> && backlog-agent install-daemon)   # regenerates the plist, restarts
```

`post_review_plist_env()` (`bin/_lib.sh`) threads `POST_COMPLETION_REVIEW=1`
into the daemon's launchd `EnvironmentVariables` iff the marker exists; no
marker ⇒ the plist is byte-identical to the pre-flip form. Confirm with:

```sh
launchctl print "gui/$(id -u)/com.<user>.<project>.backlog-agent" | grep POST_COMPLETION_REVIEW
```

**Rollback:** `rm ~/.claude/post-review/<project>.on` + reinstall the daemon.

## Cost ceiling (no silent caps)

`POST_REVIEW_MAX_LINES` (default **2000**) caps the diff sent to the reviewer.
Above it the review is **skipped** (not truncated — a partial diff yields false
"matches") and logged `post_completion_review_skipped reason=oversize`. Guard 2
separately flags such oversize commits. `0` = uncapped.

## Telemetry

| event | when |
| --- | --- |
| `post_completion_match` | reviewer judged the diff fulfils the item |
| `post_completion_mismatch` | mismatch flagged (item stays `[x]`, user notified) |
| `post_completion_review_skipped` | diff over `POST_REVIEW_MAX_LINES` |
| `post_completion_review_error` | no reviewer output / unparseable verdict (fail-open) |

## Fail-open

Missing `claude`, an empty diff, no review output, or an unparseable verdict ⇒
**no action** (the completion is accepted). The review can flag, never block.

## Tests

`test/post-completion-review.bats` — the `post_review_plist_env` marker gate and
the end-to-end Guard-8 path through `backlog-agent tick` (MATCH, MISMATCH stays
`[x]`, oversize-skip, unparseable fail-open, and inert-when-off).
