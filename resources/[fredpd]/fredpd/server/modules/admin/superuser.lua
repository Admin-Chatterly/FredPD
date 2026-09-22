--- Superuser: a console-only recovery grant (spec 4.3, invariant 2).
---
--- `admin` is deliberately not the top of the permission model -- it does not
--- inherit `patrol_basic`, and every ordinary way to map a Discord role to a
--- group (`admin.rolemap.create`, the group editor) refuses to hand out more
--- than the caller already holds. That is correct for day-to-day use and
--- wrong for recovery: if a role mapping is ever wrong, a group is ever
--- misconfigured, or an administrator is ever locked out of Administration
--- itself, there has to be a way in that does not depend on the thing that is
--- broken. Before this file, that way was a raw SQL insert.
---
--- This is that way, and it is deliberately narrower than `/fredpd setup`
--- (`bootstrap.lua`):
---
---   * **Console only, with no in-game counterpart at all.** `/fredpd setup`
---     has a chat form because the person typing the code and the person who
---     read it off the console can be different people. Superuser assumes
---     they are the same person: whoever is at the console targets a player
---     id directly. Nothing here is reachable from a client, ever.
---   * **Not one-time.** Setup refuses the moment `fpd_officers` has a row,
---     because there is exactly one first administrator. Superuser has to
---     keep working for as long as the server runs, because its entire
---     purpose is being available the day something else breaks.
---   * **Still checked against Discord.** The named role has to be one the
---     target actually holds right now, refreshed live rather than read from
---     a snapshot -- the same safety `/fredpd setup` applies, so a typo'd
---     snowflake cannot silently grant superuser to an unrelated role.
---
--- Granting it does not touch what an existing officer row already says about
--- who they are: an officer that already exists keeps their identifier,
--- callsign and name exactly as they were. This is a permission grant, not an
--- identity rewrite.
---
--- The permission itself is one row, not a list: `database/seeds/0003_superuser.sql`
--- grants the group `superuser` the literal wildcard `'*'`, which
--- `Perms.satisfies` (`server/core/perms.lua`) honours for every key that
--- exists today and every key a future module adds. An enumerated list would
--- have to be extended by hand forever and would be wrong the moment somebody
--- forgot -- which is exactly what happened to the group editor's own
--- `PERMISSION_CATALOGUE` in `admin/routes.lua`.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Superuser = {}

--- Is `roleId` one of the roles Discord currently says this player holds?
--- Forces a live refresh rather than trusting a snapshot, for the same reason
--- `/fredpd setup` does (spec 4.2): granting superuser on stale role data
--- would mean granting it against roles that may already be wrong.
--- @return boolean ok, string|nil error
local function verifyHeld(discordId, roleId)
    if not FredPD.Core.discord.refreshOne(discordId, true) then
        return false, 'could not read their roles from Discord. Check config/server.lua.'
    end

    local held = FredPD.Core.perms.memberRoles(discordId)

    for index = 1, #held do
        if held[index] == roleId then return true end
    end

    return false, ('that player does not hold role %s right now.'):format(roleId)
end

--- Grants `roleId` the `superuser` group, in the agency configured in
--- config/server.lua. There is no in-game path to this function at all --
--- `superuser.lua`'s tail only ever calls it from a `RegisterCommand` that
--- refuses everything but the server console.
---
--- @param src number server id of the player whose role will grant superuser
--- @param roleId string the Discord role id to map
--- @return boolean ok, string message
function Superuser.grant(src, roleId)
    if type(roleId) ~= 'string' or roleId:match('^%d+$') == nil then
        return false, 'usage: fredpd_superuser <player id> <discord role id>'
    end

    local discordId = FredPD.Bridge.framework.getDiscordId(src)
    if not discordId then
        return false, 'that player has no Discord identity. They need Discord running.'
    end

    local heldOk, heldErr = verifyHeld(discordId, roleId)
    if not heldOk then return false, heldErr end

    local agency = FredPD.Config.server.agency
    local character = FredPD.Bridge.framework.getCharacter(src)

    -- Read before the transaction so the write below knows whether it is
    -- creating a roster row or only reactivating and mapping one that already
    -- exists -- the two must not write the same statement (invariant 8's
    -- parameterization rule aside, an INSERT that always ran would either
    -- collide with the row's unique key or silently overwrite who they are).
    local existingOfficer = FredPD.Core.db.single(
        'SELECT id FROM fpd_officers WHERE discord_id = ? AND agency_id = ?',
        { discordId, agency.id }
    )

    local statements = {
        {
            query = [[INSERT INTO fpd_agencies (id, name, short_name, accent_color)
                      VALUES (?, ?, ?, ?)
                      ON DUPLICATE KEY UPDATE name = VALUES(name), short_name = VALUES(short_name)]],
            values = { agency.id, agency.name, agency.shortName, agency.accentColor or '#1b4f9c' },
        },
    }

    if existingOfficer then
        statements[#statements + 1] = {
            query = 'UPDATE fpd_officers SET active = 1 WHERE id = ?',
            values = { existingOfficer.id },
        }
    else
        statements[#statements + 1] = {
            -- `identifier` binds the ESX character, the same as bootstrap
            -- (spec 4.1). Left NULL when no character is loaded, which
            -- `Session.open` then reads as "no binding check" -- true here as
            -- it is everywhere else, not a special case for this path.
            query = [[INSERT INTO fpd_officers (discord_id, agency_id, identifier, callsign, name)
                      VALUES (?, ?, ?, ?, ?)]],
            values = {
                discordId,
                agency.id,
                character and character.identifier or nil,
                nil,
                character and (character.firstName .. ' ' .. character.lastName) or nil,
            },
        }
    end

    statements[#statements + 1] = {
        query = [[INSERT IGNORE INTO fpd_role_map
                      (discord_role_id, discord_role_name, group_key, agency_id, created_by)
                  VALUES (?, NULL, 'superuser', ?, ?)]],
        values = { roleId, agency.id, discordId },
    }

    if not FredPD.Core.db.transaction(statements) then
        return false, 'could not be written to the database. Check the server console above for the reason.'
    end

    -- Effective immediately, the same as every other rolemap write (spec
    -- 4.2): an operator fixing a lockout should not have to also tell the
    -- person to reconnect.
    FredPD.Core.perms.reload()
    FredPD.Core.session.refreshAll()

    FredPD.Core.audit.write({
        action = 'superuser.granted',
        discordId = discordId,
        agencyId = agency.id,
        subjectType = 'role_map',
        detail = { role = roleId },
    })

    return true, ('role %s now grants superuser in %s. Effective immediately, no reconnect needed.')
        :format(roleId, agency.id)
end

--- Removes every mapping of `roleId` to `superuser`, in the configured agency.
--- @param roleId string
--- @return boolean ok, string message
function Superuser.revoke(roleId)
    if type(roleId) ~= 'string' or roleId:match('^%d+$') == nil then
        return false, 'usage: fredpd_superuser_revoke <discord role id>'
    end

    local agency = FredPD.Config.server.agency

    local removed = FredPD.Core.db.execute(
        [[DELETE FROM fpd_role_map
           WHERE discord_role_id = ? AND group_key = 'superuser' AND agency_id = ?]],
        { roleId, agency.id }
    )

    if not removed or removed == 0 then
        return false, ('role %s was not mapped to superuser in %s.'):format(roleId, agency.id)
    end

    FredPD.Core.perms.reload()
    FredPD.Core.session.refreshAll()

    FredPD.Core.audit.write({
        action = 'superuser.revoked',
        agencyId = agency.id,
        subjectType = 'role_map',
        detail = { role = roleId },
    })

    return true, ('role %s no longer grants superuser in %s. Effective immediately.'):format(roleId, agency.id)
end

--- Every Discord role currently mapped to superuser, in any agency -- so a
--- grant nobody remembers cannot hide in an agency nobody is looking at.
--- @return table list of { discordRoleId, agencyId }
function Superuser.list()
    return FredPD.Core.db.query(
        [[SELECT discord_role_id AS discordRoleId, agency_id AS agencyId
            FROM fpd_role_map WHERE group_key = 'superuser']]
    )
end

-- -----------------------------------------------------------------------------
-- Console commands. `source == 0` is the server console and nowhere else --
-- see `fredpd_setup` in bootstrap.lua for the same check and the same reason.
-- -----------------------------------------------------------------------------

--- Prints one player's Discord roles, the same shape `fredpd_setup` prints,
--- so an operator can pick a real role id instead of guessing one.
local function printHeldRoles(target)
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
        print(('[fredpd] %s holds no roles in the guild.'):format(GetPlayerName(target)))
        return
    end

    local names = {}
    for _, role in ipairs(FredPD.Core.discord.guildRoles() or {}) do
        names[role.id] = role.name
    end

    print(('[fredpd] Discord roles held by %s:'):format(GetPlayerName(target)))
    for index = 1, #held do
        print(('[fredpd]   %s  %s'):format(held[index], names[held[index]] or '?'))
    end
    print('[fredpd] Run: fredpd_superuser ' .. target .. ' <one of those ids>')
end

RegisterCommand('fredpd_superuser', function(source, args)
    if source ~= 0 then
        print('[fredpd] fredpd_superuser runs in the server console only -- there is no in-game path, on purpose.')
        return
    end

    local target = tonumber(args[1])
    if not target or GetPlayerName(target) == nil then
        print('[fredpd] usage: fredpd_superuser <player id> [discord role id]')
        print('[fredpd] The player has to be in game -- this reads their Discord id and current character.')
        return
    end

    -- Its own thread: Discord is a network call, and awaiting one inside a
    -- command handler would block the scheduler (same reason fredpd_setup
    -- does this).
    CreateThread(function()
        if not args[2] then
            printHeldRoles(target)
            return
        end

        local ok, message = FredPD.Modules.superuser.grant(target, args[2])
        print(('[fredpd] %s'):format(message))
    end)
end, true)

RegisterCommand('fredpd_superuser_revoke', function(source, args)
    if source ~= 0 then
        print('[fredpd] fredpd_superuser_revoke runs in the server console only.')
        return
    end

    if not args[1] then
        print('[fredpd] usage: fredpd_superuser_revoke <discord role id>')
        return
    end

    local ok, message = FredPD.Modules.superuser.revoke(args[1])
    print(('[fredpd] %s'):format(message))
end, true)

RegisterCommand('fredpd_superuser_list', function(source)
    if source ~= 0 then
        print('[fredpd] fredpd_superuser_list runs in the server console only.')
        return
    end

    local rows = FredPD.Modules.superuser.list()

    if #rows == 0 then
        print('[fredpd] no Discord role currently grants superuser.')
        return
    end

    print('[fredpd] Discord roles mapped to superuser:')
    for index = 1, #rows do
        print(('[fredpd]   %s  (agency %s)'):format(rows[index].discordRoleId, rows[index].agencyId))
    end
end, true)

FredPD.Modules.superuser = Superuser
