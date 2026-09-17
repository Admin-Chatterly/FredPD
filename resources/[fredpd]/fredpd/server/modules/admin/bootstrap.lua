--- First-run setup (spec 16, ADR-010).
---
--- Turns an empty database into one an administrator can work from: the agency,
--- the first officer, and that officer's Discord roles mapped to `admin`. It
--- replaces four rows of hand-written SQL, one of which required copying a
--- snowflake out of Discord by hand.
---
--- **Why this is not a `route`.** Every route begins by opening a session, and
--- a session requires an `fpd_officers` row (`session.lua`). Before setup there
--- is no such row for anybody, so a route would refuse before its handler ever
--- ran. This is the one client-triggered state change outside `route()`, and it
--- is confined to the one moment when the alternative is editing SQL by hand.
---
--- Three things keep it from being an escalation path:
---
---   1. It refuses the moment `fpd_officers` has any row. There is exactly one
---      first run.
---   2. In game it requires a code printed only to the server console, so
---      running it means having access to the console -- which the operator has
---      and a player does not. Without this, on a fresh public server the first
---      player to guess the command would become an administrator.
---   3. It is audited like any sensitive action, including its refusals.
---
--- The logic worth testing lives in `service.lua`; this file is the plumbing.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Bootstrap = {}

--- Printed to the console at boot while the install is empty, and required by
--- the in-game command. Regenerated on every resource start, so a code seen
--- once is not good forever, and cleared once setup succeeds.
local setupCode = nil

local function service()
    return FredPD.Modules.admin
end

--- Has anybody been set up yet?
function Bootstrap.isComplete()
    local count = FredPD.Core.db.scalar('SELECT COUNT(*) FROM fpd_officers')
    return (count or 0) > 0
end

--- True while a setup attempt is between its "has anyone been set up?" check
--- and its write.
---
--- That gap contains an HTTP call to Discord, which is long enough for a second
--- attempt to pass the same check and for both to write. Two attempts by the
--- same person collide on `uq_fpd_officers_discord_agency` and the second rolls
--- back, but two *different* people insert two different discord ids cleanly --
--- and both walk away administrators.
local running = false

--- @param src number server id of the player who will become the administrator
--- @return boolean ok
--- @return string localeKey
--- @return table|nil params
local function perform(src)
    if Bootstrap.isComplete() then
        FredPD.Core.audit.write({
            action = 'bootstrap.refused',
            outcome = 'denied',
            detail = { reason = 'already_set_up' },
        })
        return false, 'setup.alreadyDone'
    end

    -- The seed carries the permission groups. Without it there is no `admin`
    -- group to map anything to, and the foreign key would fail mid-transaction
    -- with a message about a constraint rather than about the missing file.
    local adminGroup = FredPD.Core.db.scalar(
        'SELECT `key` FROM fpd_permission_groups WHERE `key` = ?', { 'admin' }
    )

    if not adminGroup then
        return false, 'setup.noSeed'
    end

    local discordId = FredPD.Bridge.framework.getDiscordId(src)
    if not discordId then
        return false, 'setup.noDiscord'
    end

    -- Their roles have to be on record before they can be mapped, and on a
    -- fresh install nothing has synced yet.
    if not FredPD.Core.discord.enabled() then
        return false, 'setup.noToken'
    end

    -- Forced past the connect cooldown: their roles were very likely fetched
    -- moments ago when they joined, and setup is the one moment where reading a
    -- 30-second-old snapshot would mean mapping a role they just removed.
    if not FredPD.Core.discord.refreshOne(discordId, true) then
        return false, 'setup.discordFailed'
    end

    local roleIds = FredPD.Core.perms.memberRoles(discordId)

    -- Mapping nobody to nothing would leave an install that looks set up and
    -- grants nothing, which is the hardest state to diagnose. Refuse instead:
    -- setup has not run, so it can be run again once they hold a role.
    if #roleIds == 0 then
        return false, 'setup.noRoles'
    end

    local character = FredPD.Bridge.framework.getCharacter(src)
    local agency = FredPD.Config.server.agency
    local officer = {
        discordId = discordId,
        callsign = nil,
        name = character and (character.firstName .. ' ' .. character.lastName) or nil,
    }

    local committed = FredPD.Core.db.transaction(
        service().bootstrapStatements(agency, officer, roleIds)
    )

    if not committed then
        return false, 'setup.failed'
    end

    FredPD.Core.agencies.reload()
    FredPD.Core.perms.reload()
    -- Drop any half-formed session so the next call builds one that can see the
    -- roster row that now exists.
    FredPD.Core.session.drop(src)

    FredPD.Core.audit.write({
        action = 'bootstrap.completed',
        discordId = discordId,
        agencyId = agency.id,
        subjectType = 'agency',
        subjectId = agency.id,
        detail = { roles = #roleIds },
    })

    setupCode = nil

    print(('[fredpd] setup complete: agency %s, first administrator %s, %d role(s) mapped to admin')
        :format(agency.id, discordId, #roleIds))

    return true, 'setup.done', { agency = agency.name, roles = #roleIds }
end

--- Runs setup for a connected player, one attempt at a time.
---
--- The lock is released through `pcall` rather than after the call, so an error
--- inside setup cannot leave it held -- which would make the one path that can
--- create an administrator unusable until the resource restarted.
---
--- @param src number server id of the player who will become the administrator
--- @return boolean ok
--- @return string localeKey describing what happened
--- @return table|nil params for the locale string
function Bootstrap.run(src)
    if running then
        return false, 'setup.busy'
    end

    running = true
    local ok, result, key, params = pcall(perform, src)
    running = false

    if not ok then
        -- `result` is the error message; it may name tables and columns, so it
        -- goes to the console and never to the player.
        print(('[fredpd] setup failed: %s'):format(tostring(result)))
        return false, 'setup.failed'
    end

    return result, key, params
end

--- Prints what to do next, at boot, while the install is empty.
function Bootstrap.announce()
    if Bootstrap.isComplete() then
        setupCode = nil
        return
    end

    setupCode = service().generateSetupCode()

    print('[fredpd] ------------------------------------------------------------')
    print('[fredpd] This install is not set up yet.')
    print('[fredpd] Join the server, then type this in the game chat:')
    print(('[fredpd]     /fredpd setup %s'):format(setupCode))
    print('[fredpd] Or run `fredpd_setup` here in the console while you are in game.')
    print('[fredpd] ------------------------------------------------------------')
end

--- The in-game path. The code is what proves console access.
RegisterNetEvent('fredpd:setup', function(code)
    local src = source

    -- Before anything else: a player spamming this must not be able to drive
    -- the Discord API or the database at will, and must not be able to try
    -- codes quickly enough for guessing to be worth anything.
    if not FredPD.Core.ratelimit.take(src, 'setup', { per = 3, window = 60 }) then
        return
    end

    if not service().codeMatches(code, setupCode) then
        FredPD.Core.audit.write({
            action = 'bootstrap.refused',
            outcome = 'denied',
            detail = { reason = 'bad_code' },
        })
        TriggerClientEvent('fredpd:setupResult', src, false, 'setup.badCode')
        return
    end

    local ok, key, params = Bootstrap.run(src)
    TriggerClientEvent('fredpd:setupResult', src, ok, key, params)
end)

--- The console path. `source` is 0 only in the server console, so no code is
--- needed: being there is the proof.
RegisterCommand('fredpd_setup', function(source, args)
    if source ~= 0 then
        print('[fredpd] fredpd_setup runs in the server console. In game, use /fredpd setup <code>.')
        return
    end

    local target = tonumber(args[1])

    if not target then
        local players = GetPlayers()

        if #players ~= 1 then
            print(('[fredpd] %d players online. Run `fredpd_setup <player id>` to say which one.')
                :format(#players))
            return
        end

        target = tonumber(players[1])
    end

    if not target or GetPlayerName(target) == nil then
        print('[fredpd] no such player. They have to be in game -- setup reads their Discord id.')
        return
    end

    -- In its own thread: setup calls Discord and waits on the response, and
    -- awaiting inside a command handler would block the scheduler.
    CreateThread(function()
        local ok, key, params = Bootstrap.run(target)
        print(('[fredpd] %s'):format(FredPD.t(key, params)))

        if ok then
            TriggerClientEvent('fredpd:setupResult', target, true, key, params)
        end
    end)
end, true)

FredPD.Modules.bootstrap = Bootstrap
