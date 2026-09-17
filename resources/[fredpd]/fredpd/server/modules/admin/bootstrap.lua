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
--- Records a refusal against the person who caused it.
---
--- Every refusal is logged, not just the interesting ones. The branch that
--- matters most is `noRoles`: somebody who got the code right but holds no
--- guild role. Left silent, that attempt leaves no trace at all.
local function refuse(discordId, reason, localeKey)
    FredPD.Core.audit.write({
        action = 'bootstrap.refused',
        discordId = discordId,
        outcome = 'denied',
        detail = { reason = reason },
    })

    return false, localeKey
end

--- @param src number server id of the player who will become the administrator
--- @param roleId string the one Discord role that will grant administration
local function perform(src, roleId)
    local discordId = FredPD.Bridge.framework.getDiscordId(src)

    if Bootstrap.isComplete() then
        return refuse(discordId, 'already_set_up', 'setup.alreadyDone')
    end

    -- The seed carries the permission groups. Without it there is no `admin`
    -- group to map anything to, and the foreign key would fail mid-transaction
    -- with a message about a constraint rather than about the missing file.
    local adminGroup = FredPD.Core.db.scalar(
        'SELECT `key` FROM fpd_permission_groups WHERE `key` = ?', { 'admin' }
    )

    if not adminGroup then
        return refuse(discordId, 'no_seed', 'setup.noSeed')
    end

    if not discordId then
        return refuse(nil, 'no_discord', 'setup.noDiscord')
    end

    -- Their roles have to be on record before they can be mapped, and on a
    -- fresh install nothing has synced yet.
    if not FredPD.Core.discord.enabled() then
        return refuse(discordId, 'no_token', 'setup.noToken')
    end

    -- Forced past the connect cooldown: their roles were very likely fetched
    -- moments ago when they joined, and setup is the one moment where reading a
    -- 30-second-old snapshot would mean mapping a role they just removed.
    if not FredPD.Core.discord.refreshOne(discordId, true) then
        return refuse(discordId, 'discord_failed', 'setup.discordFailed')
    end

    local held = FredPD.Core.perms.memberRoles(discordId)

    -- Mapping nobody to nothing would leave an install that looks set up and
    -- grants nothing, which is the hardest state to diagnose. Refuse instead:
    -- setup has not run, so it can be run again once they hold a role.
    if #held == 0 then
        return refuse(discordId, 'no_roles', 'setup.noRoles')
    end

    -- The role has to be one they actually hold. Two reasons: a typo cannot
    -- quietly grant administration to some unrelated role, and `@everyone`
    -- (whose id is the guild id) never appears in a member's role list, so it
    -- cannot be named here even by an operator who thinks it would be a
    -- reasonable choice.
    local holdsIt = false
    for index = 1, #held do
        if held[index] == roleId then holdsIt = true break end
    end

    if not holdsIt then
        return refuse(discordId, 'role_not_held', 'setup.roleNotHeld')
    end

    local character = FredPD.Bridge.framework.getCharacter(src)
    local agency = FredPD.Config.server.agency
    local officer = {
        discordId = discordId,
        identifier = character and character.identifier or nil,
        callsign = nil,
        name = character and (character.firstName .. ' ' .. character.lastName) or nil,
    }

    local committed = FredPD.Core.db.transaction(
        service().bootstrapStatements(agency, officer, { roleId })
    )

    if not committed then
        return refuse(discordId, 'write_failed', 'setup.failed')
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
        -- The role id, not a count. "3 roles were mapped" tells a reviewer
        -- nothing about which doors were opened.
        detail = { role = roleId, identifier = officer.identifier },
    })

    setupCode = nil

    print(('[fredpd] setup complete: agency %s, first administrator %s, Discord role %s grants admin')
        :format(agency.id, discordId, roleId))

    return true, 'setup.done', { agency = agency.name, role = roleId }
end

--- Runs setup for a connected player, one attempt at a time.
---
--- The lock is released through `pcall` rather than after the call, so an error
--- inside setup cannot leave it held -- which would make the one path that can
--- create an administrator unusable until the resource restarted.
---
--- @param src number server id of the player who will become the administrator
--- @param roleId string the one Discord role that will grant administration
--- @return boolean ok
--- @return string localeKey describing what happened
--- @return table|nil params for the locale string
function Bootstrap.run(src, roleId)
    if type(roleId) ~= 'string' or roleId:match('^%d+$') == nil then
        return false, 'setup.noRole'
    end

    if running then
        return false, 'setup.busy'
    end

    running = true
    local ok, result, key, params = pcall(perform, src, roleId)
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

    -- `math.random` is seeded from the clock and is not a cryptographic source
    -- (FiveM's Lua has none). Mixing in the game timer and a sub-second clock
    -- reading makes the state harder to reproduce from "roughly when the server
    -- restarted", which is what an attacker actually knows. The real defence is
    -- the length of the code and the rate limit on the event.
    math.randomseed(math.floor((os.clock() * 1000000) % 2147483647) ~ GetGameTimer() ~ os.time())

    setupCode = service().generateSetupCode()

    print('[fredpd] ------------------------------------------------------------')
    print('[fredpd] This install is not set up yet.')
    print('[fredpd] Join the server, then run one of these:')
    print(('[fredpd]   in the game chat:   /fredpd setup %s <discord role id>'):format(setupCode))
    print('[fredpd]   in this console:    fredpd_setup <player id> <discord role id>')
    print('[fredpd]')
    print('[fredpd] `fredpd_setup <player id>` on its own lists that player\'s roles.')
    print('[fredpd] Pick the role that should grant administration -- a staff or')
    print('[fredpd] command role, never one every member of the server holds.')
    print('[fredpd] ------------------------------------------------------------')
end

--- The in-game path. The code is what proves console access.
RegisterNetEvent('fredpd:setup', function(code, roleId)
    local src = source

    -- Nothing left to do once setup has succeeded. Returning here rather than
    -- falling through to the `bad_code` branch matters: that branch writes an
    -- audit row, and `fpd_audit_log` is append-only and exempt from retention,
    -- so a handful of players calling this on a loop would grow it forever.
    if setupCode == nil then
        return
    end

    -- Before anything else: a player spamming this must not be able to drive
    -- the Discord API or the database at will, and must not be able to try
    -- codes quickly enough for guessing to be worth anything.
    if not FredPD.Core.ratelimit.take(src, 'setup', { per = 3, window = 60 }) then
        return
    end

    if not service().codeMatches(code, setupCode) then
        FredPD.Core.audit.write({
            action = 'bootstrap.refused',
            -- Derived from `src` on the server, never sent by the client. An
            -- unattributable refusal tells you somebody tried and nothing else.
            discordId = FredPD.Bridge.framework.getDiscordId(src),
            outcome = 'denied',
            detail = { reason = 'bad_code' },
        })
        TriggerClientEvent('fredpd:setupResult', src, false, 'setup.badCode')
        return
    end

    local ok, key, params = Bootstrap.run(src, roleId)
    TriggerClientEvent('fredpd:setupResult', src, ok, key, params)
end)

--- Prints one player's Discord roles, so the operator can pick one.
local function listRoles(target)
    local discordId = FredPD.Bridge.framework.getDiscordId(target)

    if not discordId then
        print('[fredpd] that player has no Discord identity. They need Discord running.')
        return
    end

    if not FredPD.Core.discord.refreshOne(discordId, true) then
        print('[fredpd] could not read their roles from Discord. Check config/server.lua.')
        return
    end

    local held = FredPD.Core.perms.memberRoles(discordId)
    if #held == 0 then
        print(('[fredpd] %s holds no roles in the guild. Give them one first.'):format(GetPlayerName(target)))
        return
    end

    -- Names are worth a second call: picking by raw snowflake is how the wrong
    -- role gets chosen.
    local names = {}
    for _, role in ipairs(FredPD.Core.discord.guildRoles() or {}) do
        names[role.id] = role.name
    end

    print(('[fredpd] Discord roles held by %s:'):format(GetPlayerName(target)))

    for index = 1, #held do
        print(('[fredpd]   %s  %s'):format(held[index], names[held[index]] or '?'))
    end

    print('[fredpd] Run: fredpd_setup ' .. target .. ' <one of those ids>')
    print('[fredpd] Choose a staff or command role. Whatever you pick, everyone')
    print('[fredpd] holding it becomes a FredPD administrator.')
end

--- The console path. `source` is 0 only in the server console, so no code is
--- needed: being there is the proof.
RegisterCommand('fredpd_setup', function(source, args)
    if source ~= 0 then
        print('[fredpd] fredpd_setup runs in the server console. In game, use /fredpd setup <code> <role id>.')
        return
    end

    -- The player id is always explicit. It used to default to "the only player
    -- online", which on a restart could silently hand administration to an
    -- unrelated player who happened to join first.
    local target = tonumber(args[1])

    if not target or GetPlayerName(target) == nil then
        print('[fredpd] usage: fredpd_setup <player id> [discord role id]')
        print('[fredpd] The player has to be in game -- setup reads their Discord id.')
        return
    end

    -- In its own thread: setup calls Discord and waits on the response, and
    -- awaiting inside a command handler would block the scheduler.
    CreateThread(function()
        if not args[2] then
            listRoles(target)
            return
        end

        local ok, key, params = Bootstrap.run(target, args[2])
        print(('[fredpd] %s'):format(FredPD.t(key, params)))

        if ok then
            TriggerClientEvent('fredpd:setupResult', target, true, key, params)
        end
    end)
end, true)

FredPD.Modules.bootstrap = Bootstrap
