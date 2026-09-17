# ADR-010: Discord role sync runs in FXServer, not in the gateway

- **Status:** Accepted
- **Date:** 2026-09-17
- **Spec:** 4.2, 3.7, 16, and ADR-003 (which this narrows)

## Context

ADR-003 put a Node gateway beside FXServer for the work Lua is bad at: media
with signed URLs, PDF rendering, scheduled jobs, and the Discord bot. The
Discord bot's job is small — read the guild's members and write their role ids
into `fpd_discord_members`, which `perms.memberRoles()` reads on every session.

That bot was never built. `gateway/src/server.ts` shipped in v0.1.0 as the M0
skeleton: a health endpoint and a signed `/fx/ping`. Nothing in the resource
calls the gateway at all — there is no `PerformHttpRequest` anywhere under
`resources/`.

So a v0.1.0 install asks the operator to:

- deploy a Node service that does nothing,
- set a shared secret the resource only checks for presence and never uses,
- insert their own Discord role ids into the database as raw JSON, and
- run a cron job doing `UPDATE fpd_discord_members SET synced_at = NOW()`.

That last one is the worst of them. `synced_at` is the input to the outage
policy in spec 4.2: sensitive actions are refused past 15 minutes, and a session
goes read-only past 6 hours. A cron that stamps it unconditionally forges
exactly the signal the policy exists to read — it reports "Discord confirmed
these roles a minute ago" when nothing has confirmed anything, possibly ever.

## Decision

The Discord role sync moves into FXServer as `server/core/discord.lua`. It calls
the Discord API directly with `PerformHttpRequest`, using a bot token read from
`config/server.lua`.

- The whole guild is refreshed on a timer (`discord.refreshMinutes`, default 10),
  so a role *removed* in Discord takes effect without the member doing anything.
- A connecting player is refreshed immediately, so a role *granted* seconds ago
  is live when they join.
- A failed fetch writes nothing. Rows age, and the 4.2 outage policy narrows
  what sessions may do exactly as designed.

The gateway stays in the repo and in ADR-003 for media, PDF and scheduled jobs —
none of which exist yet. It is now **off by default** (`gateway.enabled = false`)
and requires no secret while it is off, so nobody deploys it to run a health
check.

Configuration moves from five convars to one file, `config/server.lua`, which is
in `server_scripts` and absent from `files {}` — so the token never reaches a
client, which is what invariant 7 is actually about. Convars still win when set,
for hosts that template their configuration.

First-run setup becomes `/fredpd setup <code>` in game, or `fredpd_setup` in the
server console, replacing the four hand-written bootstrap rows.

## Consequences

- **The cron is gone, and must stay gone.** `synced_at` is now only ever written
  alongside a role list that Discord actually returned.
- A normal install deploys no Node at all: copy the resource, edit one file,
  import one SQL file, type one command.
- The operator makes a Discord bot and enables the Server Members intent. That
  is a real step, and it is the one thing here that cannot be removed: without a
  privileged read of the member list there is no way to know who holds what, and
  Discord roles are the only permission source (invariant 2).
- Role changes now take up to `refreshMinutes` to propagate rather than being
  pushed. For a removed role that is a widened window, bounded and configurable;
  previously it was unbounded, because nothing pushed anything.
- FXServer now makes an outbound HTTPS call on a timer. A guild of 1000 members
  is one request per cycle; larger guilds paginate at 1000.
- `FredPD.onDiscordChange()` finally has a caller.
- **Setup is one client-triggered state change outside `route()`**, which
  invariant 3 otherwise forbids. It has to be: a route opens a session first,
  and a session needs an `fpd_officers` row that by definition does not exist
  yet. It is bounded by refusing once any officer exists, by requiring a code
  printed only to the server console, and by being audited including refusals.

## Alternatives considered

**Build the bot in the gateway as planned.** Correct per ADR-003, and it keeps
push-based updates. Rejected for now because it makes every install deploy and
supervise a second service for one table, and the gateway has no other live
responsibility to amortise that cost against. When media and PDF arrive, moving
the sync back is a contained change — the table and its readers do not move.

**Let ESX job grades grant access in a "simple mode".** Removes Discord from the
install entirely. Rejected: it contradicts invariant 2 outright, and it means
anyone who can set a job grade can grant MDT access, including to records.

**Automate the cron properly.** Rejected on principle. The problem with the cron
is not that it is manual, it is that it lies.
