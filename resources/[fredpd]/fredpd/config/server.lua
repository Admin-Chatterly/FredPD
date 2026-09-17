--- =============================================================================
--- FredPD configuration. **This is the only file you need to edit.**
--- =============================================================================
---
--- Fill in the three things under `discord` and `agency`, start the resource,
--- then run the setup command it prints. That is the whole install.
---
--- This file is listed in `server_scripts` and must never appear in `files {}`.
--- That is the difference between a secret the server holds and one every
--- player can download (invariant 7). Do not move these values into
--- `config/shared.lua`, which does reach clients.
---
--- If you run FredPD from a git clone rather than the release bundle, your
--- edited copy of this file carries a bot token: do not commit it.
---
--- Every value below can also be supplied as a `set` convar, which wins when
--- present. That is for hosts that template their configuration; you do not
--- need any convars for a normal install.

FredPD = FredPD or {}
FredPD.Config = FredPD.Config or {}

local function setting(convar, fallback)
    local value = GetConvar(convar, '')
    if value == '' then return fallback end
    return value
end

FredPD.Config.server = {
    -- -------------------------------------------------------------------------
    -- 1. Discord  (required)
    --
    -- Discord roles are the only thing that grants access in FredPD
    -- (invariant 2), so this is what makes the suite work at all.
    --
    -- Create the bot once:
    --   1. https://discord.com/developers/applications -> New Application
    --   2. Bot -> Reset Token -> copy it into `token` below
    --   3. Bot -> Privileged Gateway Intents -> enable SERVER MEMBERS INTENT
    --   4. Installation -> invite it to your guild (no permissions needed --
    --      it only reads the member list)
    --
    -- `guildId`: right-click your server in Discord -> Copy Server ID.
    -- Both need Developer Mode on: Settings -> Advanced -> Developer Mode.
    -- -------------------------------------------------------------------------
    discord = {
        token = setting('fredpd:discord_token', ''),
        guildId = setting('fredpd:discord_guild', ''),

        --- How often the whole member list is refreshed, in minutes.
        --- A role added or removed in Discord takes effect within this window
        --- without a restart. Joining the server refreshes that player at once,
        --- so this is the ceiling on how stale anyone's roles can be.
        refreshMinutes = 10,

        --- Outage policy (spec 4.2). Both tiers degrade toward *less* access:
        --- Discord going unreachable must never widen what anyone can do.
        ---
        --- Past this, sensitive actions (approvals, releases, deletions,
        --- intelligence and surveillance) are refused.
        sensitiveStaleAfterSeconds = 15 * 60,
        --- Past this, the session is read-only: nothing that changes state.
        readOnlyAfterSeconds = 6 * 60 * 60,
    },

    -- -------------------------------------------------------------------------
    -- 2. Your agency  (required)
    --
    -- Created by the setup command on first run. `id` is a short stable key
    -- used in the database and never shown to players; change it before you set
    -- up, not after.
    -- -------------------------------------------------------------------------
    agency = {
        id = 'lspd',
        name = 'Los Santos Police Department',
        shortName = 'LSPD',
        accentColor = '#1b4f9c',
    },

    -- -------------------------------------------------------------------------
    -- 3. Everything below has a working default. Leave it alone unless you have
    --    a reason.
    -- -------------------------------------------------------------------------

    --- Default route rate limit, per session (spec 3.5). A route may set its own.
    rateLimit = {
        per = 30,
        window = 60,
    },

    --- The gateway is a separate Node service for media, PDF rendering and
    --- scheduled jobs. None of that exists yet and FXServer never calls it, so
    --- it is off and you do not need to deploy anything (ADR-010). When it
    --- arrives, set `enabled = true` and give it a secret generated with
    --- `openssl rand -hex 32`.
    gateway = {
        enabled = false,
        url = setting('fredpd:gateway_url', 'http://127.0.0.1:3080'),
        secret = setting('fredpd:gateway_secret', ''),
        --- How long a signed request stays valid, in seconds (spec 3.7).
        replayWindow = 30,
    },
}
