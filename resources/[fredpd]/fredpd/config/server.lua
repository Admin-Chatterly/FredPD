--- Server-only configuration. This file is listed in `server_scripts` and must
--- never appear in `files {}` -- that is the difference between a secret the
--- server holds and a secret every player can download (invariant 7).
---
--- Secrets themselves live in `set` convars (never `setr`, which replicates to
--- clients), so this file holds the names and the tuning, not the values.

FredPD = FredPD or {}
FredPD.Config = FredPD.Config or {}

FredPD.Config.server = {
    --- Loopback gateway (spec 3.7). The secret signs every request in both
    --- directions; a missing one is a boot failure, not a warning.
    gateway = {
        url = GetConvar('fredpd:gateway_url', 'http://127.0.0.1:3080'),
        secret = GetConvar('fredpd:gateway_secret', ''),
        --- How long a signed request stays valid, in seconds (spec 3.7).
        replayWindow = 30,
    },

    --- Default route rate limit, per session (spec 3.5). A route may set its own.
    rateLimit = {
        per = 30,
        window = 60,
    },

    --- Discord is the only permission source (invariant 2).
    discord = {
        guildId = GetConvar('fredpd:discord_guild', ''),

        --- Outage policy (spec 4.2). Both tiers degrade toward *less* access:
        --- a gateway that stops answering must never widen what anyone can do.
        ---
        --- Past this, sensitive actions (approvals, releases, deletions,
        --- intelligence and surveillance) are refused.
        sensitiveStaleAfterSeconds = 15 * 60,
        --- Past this, the session is read-only: nothing that changes state.
        readOnlyAfterSeconds = 6 * 60 * 60,
    },
}
