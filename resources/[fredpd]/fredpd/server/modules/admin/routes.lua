--- Administration routes: the Discord role map (spec 4.3, 7.30).
---
--- This is what makes permissions configurable in game. An administrator maps a
--- Discord role id to a permission group from the MDT, and it takes effect on
--- the next reload — no restart, no config file.
---
--- Invariant 2 is unchanged by any of this. Discord roles remain the only
--- permission source; what is editable here is the *mapping*, not the source.

local route = FredPD.Core.route
local db = FredPD.Core.db

--- A Discord snowflake is digits only. The schema already bounds the length;
--- this rejects the shape, so a role name pasted into the id field fails here
--- rather than silently never matching anyone.
local function isSnowflake(value)
    return value:match('^%d+$') ~= nil
end

route.define({
    name = 'admin.rolemap.list',
    perm = 'admin.permissions.edit',
    schema = 'RoleMapList',
    handler = function(session, _input)
        local mappings = db.query(
            [[SELECT m.id, m.discord_role_id AS discordRoleId, m.discord_role_name AS discordRoleName,
                     m.group_key AS groupKey, m.agency_id AS agencyId, g.name AS groupName
                FROM fpd_role_map m
                JOIN fpd_permission_groups g ON g.`key` = m.group_key
               WHERE m.agency_id = ?
               ORDER BY m.discord_role_name, m.group_key]],
            { session.agencyId }
        )

        local groups = db.query(
            'SELECT `key`, name, inherits, description FROM fpd_permission_groups ORDER BY `key`'
        )

        -- How stale the Discord snapshot is, so the screen can say whether what
        -- it is showing is current (spec 4.2).
        local snapshotAge = db.scalar(
            'SELECT TIMESTAMPDIFF(SECOND, MAX(synced_at), NOW()) FROM fpd_discord_members'
        )

        return { mappings = mappings, groups = groups, snapshotAgeSeconds = snapshotAge }
    end,
})

route.define({
    name = 'admin.rolemap.create',
    perm = 'admin.permissions.edit',
    schema = 'RoleMapCreate',
    -- Granting permissions on a stale snapshot is exactly the case spec 4.2
    -- blocks: the roles we would be mapping against may already be wrong.
    sensitive = true,
    audit = 'rolemap.created',
    subjectType = 'role_map',
    auditDetail = function(input)
        return { discordRoleId = input.discordRoleId, groupKey = input.groupKey, agencyId = input.agencyId }
    end,
    handler = function(session, input)
        if not isSnowflake(input.discordRoleId) then
            return route.refuse(FredPD.ErrorCode.INVALID, { discordRoleId = 'not_snowflake' })
        end

        -- An administrator configures their own agency, not somebody else's.
        if input.agencyId ~= session.agencyId then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        local group = db.single('SELECT `key` FROM fpd_permission_groups WHERE `key` = ?', { input.groupKey })
        if not group then
            return route.refuse(FredPD.ErrorCode.INVALID, { groupKey = 'unknown' })
        end

        local existing = db.single(
            [[SELECT id FROM fpd_role_map
               WHERE discord_role_id = ? AND group_key = ? AND agency_id = ?]],
            { input.discordRoleId, input.groupKey, input.agencyId }
        )

        if existing then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        local id = db.insert(
            [[INSERT INTO fpd_role_map (discord_role_id, discord_role_name, group_key, agency_id, created_by)
              VALUES (?, ?, ?, ?, ?)]],
            {
                input.discordRoleId,
                input.discordRoleName,
                input.groupKey,
                input.agencyId,
                session.discordId,
            }
        )

        -- Recompute, then push the new module list to everyone already online.
        -- Granting a permission that only applies after a reconnect would make
        -- the editor feel broken.
        FredPD.Core.perms.reload()
        FredPD.Core.session.refreshAll()

        return { id = id }
    end,
})

route.define({
    name = 'admin.rolemap.delete',
    perm = 'admin.permissions.edit',
    schema = 'RoleMapDelete',
    sensitive = true,
    audit = 'rolemap.deleted',
    subjectType = 'role_map',
    handler = function(session, input)
        local existing = db.single(
            'SELECT id, agency_id AS agencyId, discord_role_id AS discordRoleId, group_key AS groupKey FROM fpd_role_map WHERE id = ?',
            { input.id }
        )

        if not existing then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        if existing.agencyId ~= session.agencyId then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        db.execute('DELETE FROM fpd_role_map WHERE id = ?', { input.id })

        -- Revocation must be immediate: an open MDT loses its pages now, not on
        -- the officer's next reconnect (spec 4.2).
        FredPD.Core.perms.reload()
        FredPD.Core.session.refreshAll()

        return { id = input.id }
    end,
})

--- The session's own view of itself, for the NUI shell.
route.define({
    name = 'session.get',
    perm = 'page.records',
    handler = function(session, _input)
        return {
            callsign = session.callsign,
            name = session.name,
            agencyId = session.agencyId,
            agencyName = FredPD.Core.agencies.nameOf(session.agencyId),
            onDuty = FredPD.Bridge.policejob.isOnDuty(session.src),
            modules = FredPD.Core.session.allowedModules(session),
            permissionsStale = FredPD.Core.session.isStale(session),
        }
    end,
})
