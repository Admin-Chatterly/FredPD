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

    --- The forensic lab (spec 8.7).
    ---
    --- How long an analysis takes, in real minutes, counted from the moment an
    --- analyst starts it at the lab terminal. The due time is written to the
    --- database, so timers survive a restart and nobody can shorten one.
    ---
    --- Priority is a multiplier on whatever is set here: `routine` is the full
    --- time, `expedited` half of it and `urgent` a quarter. An analysis that is
    --- not listed takes 30 minutes.
    ---
    --- Longer is better than shorter. The wait is the mechanic -- it is what
    --- makes a lab request a decision about which items matter rather than a
    --- button pressed on everything collected.
    lab = {
        analysisMinutes = {
            dna = 45,
            print_comparison = 20,
            print_search = 25,
            ballistics = 40,
            gsr = 15,
            drug_id = 10,
        },
    },

    --- What a player is wearing (spec 3.8, 8.2).
    ---
    --- Read from whichever clothing resource you run -- illenium-appearance,
    --- fivem-appearance and esx_skin are tried in that order without any
    --- configuration. Set `resource` (and `getters`, if your fork renamed the
    --- export) only if you run something else; naming one replaces the list
    --- rather than adding to it.
    ---
    --- `gloves` is the part that matters to section 8, and it is the part that
    --- cannot be guessed. Gloves are what turn a fingerprint into a glove mark,
    --- and GTA has no "wearing gloves" flag: gloves are drawn as part of the
    --- arms, so the only way to tell is to know which arms drawables are the
    --- gloved ones. That is a property of the clothing *your* server ships, so
    --- it lives here and not in the code.
    ---
    --- Keyed by ped model name, then by arms drawable id (clothing component 3),
    --- and below is a starting list for the two vanilla freemode models. Check
    --- it once on your own server before you rely on the mechanic -- step
    --- through the arms drawables in your clothing menu and note which of them
    --- put gloves on the hands -- and replace it outright if you run a clothing
    --- pack, EUP or add-on DLC clothing, where the numbering is your pack's and
    --- not the base game's.
    ---
    --- Leaving a gloved drawable out is the cheap mistake: that touch leaves a
    --- fingerprint, which an investigator can still work with. Listing one that
    --- is not gloved is the expensive one: every touch in that garment leaves a
    --- glove mark, and the prints those touches should have left never exist.
    ---
    --- A ped model that is not listed here leaves prints and never glove marks.
    --- Remove `gloves` entirely and no player ever leaves a glove mark, which
    --- the resource says on startup rather than leaving you to wonder.
    appearance = {
        gloves = {
            ['mp_m_freemode_01'] = {
                [4] = true, [5] = true, [7] = true, [8] = true, [9] = true, [11] = true, [12] = true,
            },
            ['mp_f_freemode_01'] = {
                [4] = true, [5] = true, [7] = true, [8] = true, [9] = true, [11] = true, [12] = true,
            },
        },
    },

    --- Evidence in the world (spec 8).
    ---
    --- The grid's own numbers -- cell size, how far traces are streamed, how
    --- long each type lives and how fast it decays -- all have working defaults
    --- in `server/modules/forensics/service.lua`, and anything you put in this
    --- section is merged over them, two levels deep: setting one item name below
    --- leaves the rest of the defaults alone.
    ---
    --- `destroyItems` is here because it is the one part of section 8 that
    --- cannot have a correct default. These are ox_inventory item names, and
    --- which names exist is a property of your item list, not of FredPD:
    ---
    ---   wipe   -- the kit spent wiping a surface down
    ---   weapon -- the kit spent cleaning a weapon (the same kit by default)
    ---   clean  -- the chemicals spent cleaning up a pool of blood
    ---
    --- Washing your hands and picking your own casings up cost nothing and have
    --- no entry: they are not items you can fail to own.
    ---
    --- An action whose item your server does not have is refused every time, and
    --- the officer is told they have no item. If destruction never works, these
    --- three names are the first thing to check against your item list.
    forensics = {
        destroyItems = {
            wipe = 'wiping_kit',
            weapon = 'wiping_kit',
            clean = 'cleaning_chemicals',
        },
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
