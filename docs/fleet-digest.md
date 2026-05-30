# Automated fleet digest (P1 · W2)

The notify-channel consumer: a scheduled summary of *what each project
accomplished this period* — completions, ticks, token spend, and the open `[?]`
blockers that need a human — pushed to the user via the shared notify channel.

Shipped 2026-05-29 (the DIGEST half). The **remote-unblock** half (answer a `[?]`
by replying to the notification) is split into its own follow-up item — see
"Deferred" below.

## What it does

`backlog-agents digest [--period day|week] [--json] [--no-notify]`

- **Data source:** each project's LOCAL per-tick ledger
  `.claude/backlog-history.jsonl` — the same source as `backlog-agents metrics`.
  Because the data is local, the digest **runs locally** (a Cloudflare worker
  can't see the ledgers without first plumbing them into D1).
- **Period windowing:** rows are filtered by their `ts` (ISO-8601, millis
  tolerated) to the last 24h (`day`) or 7d (`week`).
- **Per project:** completions (exit_code==0 AND a non-empty `work_commit`, the
  same approximation as `metrics`), ticks, token spend, and the count + verbatim
  titles of open `[?]` blockers (scanned from `docs/Backlog.md`, anywhere in the
  file, mirroring `backlog-agent unblock`). A project with no in-period activity
  AND no blocker is omitted.
- **Fleet roll-up:** totals + success rate.
- **Surfacing:** the text summary (fleet line + the actionable blocker list) is
  pushed via the shared `notify_send` (`bin/_lib.sh`). `--no-notify` renders to
  stdout only (preview / tests); `--json` emits a machine-readable object.

## Scheduling

`backlog-agents install-digest [--uninstall]` installs two launchd
`StartCalendarInterval` timers on this machine:

- `com.${USER}.backlog-agents-digest-daily`  — `digest --period day`, ~09:00 daily.
- `com.${USER}.backlog-agents-digest-weekly` — `digest --period week`, Mondays ~09:00.

They run where the daemons run (local ledgers). Logs land in
`~/Library/Logs/backlog-agents-digest-{daily,weekly}.{stdout,stderr}.log`.

## Notify channel + Telegram

`notify_send` moved from `bin/backlog-agent` into `bin/_lib.sh` so the driver's
alerts (cooldown, dead-man's-switch, budget cap, circuit-breaker) AND the CLI's
digest share ONE sender. A **Telegram** transport was added alongside Slack /
email / macOS-local: it posts to `https://api.telegram.org/bot<TOKEN>/sendMessage`
via `curl --data-urlencode` (jq-free), reading `telegram_bot_token` +
`telegram_chat_id` from `~/.claude/agent-notify.json`. `chat_id` may be a quoted
string or an unquoted (possibly negative, for groups) number.

**Prerequisite:** the digest is INERT for Telegram until the user creates a bot
(`@BotFather`) and fills `telegram_bot_token` + `telegram_chat_id` into
`~/.claude/agent-notify.json`. Until then the digest still fires the macOS-local
banner (`local_notify: true`). Every transport is best-effort + backgrounded;
an empty/absent config is a silent no-op (fail-open).

Example `~/.claude/agent-notify.json`:

```json
{
  "slack_webhook_url": "",
  "email": "",
  "telegram_bot_token": "123456:ABC-DEF...",
  "telegram_chat_id": "987654321",
  "local_notify": true
}
```

## Decisions (user, 2026-05-29)

- **Scope:** ship the digest first; defer remote-unblock to its own item.
- **Cadence:** BOTH a daily and a weekly digest (two timers).
- **Run-home:** local launchd timer (reuses `metrics`, no D1 plumbing).
- **Delivery:** macOS-local + **Telegram** (WhatsApp declined — bigger Meta/Twilio
  lift; Slack/email remain available in the same config).

## Tests

`test/digest.bats` (7): text content (project + completion count + blocker title +
out-of-window project omitted), `--json` shape + windowed fleet numbers, period
windowing (a 3-day-old completion is in `week` but not `day`), bad-period
rejection, `--no-notify` suppresses the push, and two `notify_send` unit tests
(Telegram Bot-API send via a curl stub; empty-config no-op). Driver/CLI-only —
**no D1 migration / dashboard change.** Suite **219/219**.

## Deferred — remote unblock (its own follow-up item)

Let the user answer a `[?]` blocker by replying to the notification, without
editing `docs/Backlog.md` locally. The bigger lift: a new D1 `unblock_requests`
table + `/api/unblock` endpoint + a Slack/Telegram-facing interactive endpoint +
AUTH + a daemon poll-apply that writes the `[user]` answer and flips `[?]`→`[!]`
in the right project's backlog and commits/pushes (the FIRST inbound control
path; mirrors the fleet-control/account-cooldown D1 poll-and-apply pattern).
