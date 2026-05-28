# backlog-infra — Backlog

A running list of work to do. Mark items `- [x]` when done and move
them to the Done section, `- [ ]` when open, `- [~]` when in progress,
`- [?]` when blocked on a design decision the user needs to weigh in
on, and `- [!]` once you've written answers inline and want the worker
to retry. The autonomous worker (`backlog run`) picks `- [ ]` and `- [!]` items and skips `- [?]`; surface those
to the user when waking them.

Items parked in `## Thinking` are never picked by the daemon — move
them to `## Open` when ready for work.

## Thinking
- [ ] Ability to pause, stop, and resume/restart backlog agents across all machines (fleet-wide control). Pause = suspend tick loop without losing claim/state; stop = full halt; resume/restart = bring back up. Should work uniformly over every machine running daemons, not just the local one.

(see `docs/multi-agent-design.md` for full design)

- [ ] Reconcile compact strategy + docs. The shared `bin/backlog-agent-compact.mjs` moves `## Done` → `## Archive`, but some projects ship a local `scripts/compact-backlog.mjs` that does *title-only* compaction (strips verbose bodies, keeps `[x]` items in `## Done`) — e.g. sacred-geography. `architecture.md` §6/§10 document only the Archive behavior. Pick the canonical strategy, then align the doc + the per-project scripts.
- [ ] Auto-compact trigger never clears under title-only compaction. `_post_tick_cleanup` gates the compact call on `done_count > 20` (count of `[x]` lines), but title-only compaction leaves the items in `## Done`, so the count stays high and compact runs (an idempotent no-op) on *every* tick. Gate on "needs compaction" (verbose bodies present / a marker) instead of the raw `[x]` count. Depends on the strategy decision above.

## Open
- [~] Implement Layer 3: opt-in `~/.claude/agent-fallback.json`, OpenCode invocation, status-hook extension to log `agent=` in the trailer.
- [ ] Extend `bin/backlog-agent-status.mjs` to record per tick: (a) a `completed` / marker-transition flag (did this tick move a backlog item to Done / `[x]`?, since today's stream only logs the item *worked on* + whether a `work_commit` was produced, and `exit_code` does not indicate completion), and (b) `repo_slug` (e.g. `owner/repo`, derived from `git remote`) + the FULL commit SHA (currently only a short 7-char SHA is stored). Goal: let downstream dashboards list genuinely-completed items per usage window with working `github.com/<owner>/<repo>/commit/<sha>` links, without after-the-fact reconstruction. **Prereq for backlog-dashboard "Away/Recap" view** (see backlog-dashboard `docs/Backlog.md`, Thinking).
- [?] Web dashboard: mobile-responsive layout
  - blocked (needs design decision): there is **no web dashboard** in this repo to make responsive. Every "dashboard" reference points to the terminal-based `backlog-agents` fleet CLI — no `.html`, no HTTP server, no web framework exists. "Mobile-responsive layout" presupposes an existing web UI. Before this can be worked: (1) should a web dashboard be built from scratch here, and if so what stack (static HTML reading `backlog-status.json`? a Worker? a Pages app?), where does it live, and how does it source fleet data; or (2) does the web dashboard live in a different repo I should be editing? Answer inline with `[user]` and `backlog unblock` to retry.

