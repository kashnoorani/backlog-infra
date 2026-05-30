# Remote unblock — answer a `[?]` by replying to the fleet digest

**Status:** shipped 2026-05-30 (P1 · W2). The FIRST inbound control path.

## Problem

A `[?]` blocker is an item the autonomous worker parked because it needs a human
design decision. Until now it could ONLY be answered on the machine that owns the
clone: edit `docs/Backlog.md` (write a `[user]` answer line + flip `[?]`→`[!]`) and
run `backlog-agent unblock`. Every other guard shipped in W2 is **outbound** (notify)
or a **daemon-polled D1 control flag** (freeze / pause / stop / account-cooldown).
There was no way to answer a blocker from outside a clone — e.g. from a phone.

This closes the human-in-the-loop gap: reply to the fleet digest and the answer lands
in the right project's backlog from anywhere.

## Mechanism

It reuses the existing auto-flip path. `auto_flip_blocked` (`bin/backlog-agent`)
already scans for a `[user]`-prefixed answer written under a `[?]` item and flips
`[?]`→`[!]` so the worker retries — no manual `unblock`. So remote unblock only has to
**reproduce "write the `[user]` answer line + flip `[?]`→`[!]`" into the right
project's backlog, commit/push** — driven by a D1 row that a Telegram reply writes. It
rides the proven D1 poll-and-apply bus (same shape as account-cooldown / fleet-control).

### Flow

```
 digest (Telegram, outbound) lists each [?] as  <project>#<N>  title
        │
        ▼  user replies:  "<project>#<N>  my answer text"
 Telegram  ──update POST──►  /api/telegram-webhook  (auth: secret-token + chat_id)
                                   │  writes a row
                                   ▼
                          D1  unblock_requests  {project,item_index,title_prefix?,
                                                  answer, requested_by, applied:0}
                                   ▲  polled each tick (GET, fail-open)
        ┌──────────────────────────┘
 each project daemon, top-of-tick (process_unblock_requests, before auto_flip):
   GET /api/unblock?project=<self>  → matches its project's pending rows
   locate the Nth [?]  (do_unblock ordering) + title-prefix guard
   write "  [user] <answer>" under it + flip [?]→[!]  → commit + push
   POST /api/unblock {id,applied:1,...}   (idempotent CAS clear)
```

## Item addressing — `<project>#<index>`

The handle is `<project>#<N>` where N is the **1-based index of the Nth `[?]` in that
project's `docs/Backlog.md`** (file order) — the exact ordering `backlog-agent unblock`
lists and `backlog-agents digest` now prints. A reply names the project + the index.

**Stale-index guard.** The `[?]` set can shift between the digest and the reply (a new
blocker appears, one gets answered). Each request optionally carries a `title_prefix`;
before writing, the daemon checks the Nth `[?]`'s title starts with it. On a mismatch
**or** an out-of-range index it **NO-OPS** — re-notifies the user, logs
`unblock_mismatch`, and clears the row `result=mismatch` so it doesn't retry forever —
never unblocking the wrong item. (The Telegram bot currently submits a null prefix; the
index match + the user reading the digest is the primary guard, the prefix the belt. A
future digest could embed the prefix in the handle for a tighter check.)

## Decisions (user, 2026-05-30)

- **Full loop** shipped (D1 + daemon half **and** the Telegram bot), not the half-loop.
- **D1 row, daemon-applied** write path (mirrors fleet-control/cooldown; no clone on the
  worker) — over a GitHub-API commit from the worker or email-reply parsing.
- **`<project>#<index>` + title-prefix guard** addressing — over title-substring.
- **Shared `HEALTH_API_KEY` bearer** on the D1 write; GET is public/read-only.

## Surfaces

### Dashboard (backlog-dashboard)
- `migrations/0005_unblock_requests.sql` — the request table (`id, project, item_index,
  title_prefix, answer, requested_by, requested_epoch, applied, applied_epoch,
  applied_by, result, updated_at`), index on `(project, applied)`. Rows are retained for
  audit (never auto-deleted); GET returns only `applied=0`.
- `functions/api/unblock.js`:
  - `GET /api/unblock?project=<p>` → pending requests for that project. Public + CORS,
    read-only; robust to an unmigrated DB (`{requests:[]}`, fail-open).
  - `POST /api/unblock` (bearer `HEALTH_API_KEY`): **publish** `{project, item_index,
    title_prefix?, answer, requested_by?}` (inserts `applied=0`) or **clear** `{id,
    applied:1, applied_by?, result?}` (idempotent CAS — only flips `applied 0→1`).
- `functions/api/telegram-webhook.js` — receives Telegram `Update` POSTs.
  - **Auth, two gates:** the `X-Telegram-Bot-Api-Secret-Token` header must equal
    `TELEGRAM_WEBHOOK_SECRET`, AND the update's `chat.id` must equal `TELEGRAM_CHAT_ID`.
    A failed gate is a silent 200 no-op (no D1 touch, no reply).
  - Parses `"<project>#<N> <answer>"` (also accepts a leading `/unblock`), writes the
    `unblock_requests` row directly via the D1 binding, and acks via `sendMessage`. A
    malformed message gets a one-line usage hint.
  - Secrets: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`, `TELEGRAM_CHAT_ID`.

### Driver (backlog-infra `bin/backlog-agent`)
- Config: `UNBLOCK_URL` (default the pages.dev endpoint) + `REMOTE_UNBLOCK_DISABLE`
  (tests / hard-off).
- `_d1_unblock_get` — top-of-tick GET; jq-free curl, **node-parsed** (the answer is
  arbitrary free text) into `id|item_index|title_prefix_b64|answer_b64` lines. **Both**
  prefix and answer are base64'd and the delimiter is `|` (a non-whitespace char outside
  the base64 alphabet) so `read` preserves an empty middle field — a TAB IFS collapses
  `\t\t`. FAIL-OPEN (unreachable / no rows ⇒ no output ⇒ no-op).
- `_d1_unblock_clear` — backgrounded best-effort bearer POST `{id,applied:1,...}`
  (mirrors `_d1_publish_cooldown`).
- `_unblock_apply` — enumerates `[?]` items (the `do_unblock` awk), applies the
  range + title-prefix guard, writes the `[user]` block + flips `[?]`→`[!]` via an awk
  rewrite (answer passed through the environment so quotes/backslashes/newlines can't
  break the program), commits atomically (`-m` before `--`) + pushes, then clears the
  row. `log_event unblock_applied` / `unblock_mismatch`.
- `process_unblock_requests` — the orchestrator, called in `tick_once` right before
  `auto_flip_blocked` (after the pull, so origin is current and the index matches).

### CLI (backlog-infra `bin/backlog-agents`)
- `do_digest` now renders the stable `<project>#<N>` handle in both the stdout blocker
  list and the Telegram notify body, with a "reply `<project>#<N> your answer`" hint —
  those handles ARE the unblock targets.

## Two-daemon race

The same project runs on M1 **and** M3, so both daemons poll the bus. A true
simultaneous race is improbable (staggered tick schedules + each applies only after its
own `git pull`), and is bounded three ways: the clear is an **idempotent CAS** (only
`0→1`, so the audit row is written once), the title-prefix guard makes a stale re-apply
a no-op, and even a duplicate `[user]` line is benign (both flip to `[!]`). Accepted —
not worth a distributed lock. The alternative (claim-the-row-first CAS) trades the rare
duplicate for a rare lost-update if a daemon dies mid-apply; apply-then-clear was chosen
because a lost answer is worse than a benign duplicate.

## Setup (user prerequisites — outward-facing)

Telegram is **inert** until a bot exists and creds are configured (the outbound digest
shares this):

1. Create a bot via `@BotFather`; note the bot token.
2. Add to `~/.claude/agent-notify.json`: `telegram_bot_token`, `telegram_chat_id` (the
   owner chat). This lights up the outbound digest over Telegram.
3. Deploy the dashboard (migration `0005` + the two endpoints), set the CF secrets
   `TELEGRAM_BOT_TOKEN` / `TELEGRAM_WEBHOOK_SECRET` / `TELEGRAM_CHAT_ID`.
4. Register the webhook (outward-facing — confirm first):
   `curl "https://api.telegram.org/bot<token>/setWebhook?url=https://kash-backlogs.pages.dev/api/telegram-webhook&secret_token=<TELEGRAM_WEBHOOK_SECRET>"`.

## Testing

`test/remote-unblock.bats` (hermetic, curl-shimmed, `REMOTE_UNBLOCK_DISABLE=0` behind
the stub): a pending request writes the answer + flips `[?]` + clears the row; a
title-prefix mismatch and an out-of-range index are each a no-op + clear `mismatch`; an
unreachable endpoint fails open; the disable flag skips the poll. The dashboard
endpoints are verified live by hand-curl (publish → GET → clear round-trip, 401 on
unauth) and a hand-crafted Telegram update POST (secret-token header + chat_id → row in
D1).
