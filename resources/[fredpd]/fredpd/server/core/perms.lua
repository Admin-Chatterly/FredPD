--- Permissions (spec 4.3, invariant 2, ADR-004).
---
--- Discord role -> permission groups -> permission keys.
---
--- The role map lives in `fpd_role_map`, not in a config file, so an
--- administrator edits it from the MDT and it takes effect on the next reload
--- without a restart (spec 7.30). That is the only reason any of this is a
--- table lookup rather than a constant.
---
--- ESX job grades and p_policejob ranks appear nowhere in this file. They are
--- context conditions (4.3), never grants.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Perms = {}

--- Cache of the whole model, rebuilt by `Perms.reload()`.
--- groupPermissions: group key -> { [permission] = true }
--- roleMap:          agency id -> discord role id -> { group keys }
local cache = {
    groupPermissions = {},
    roleMap = {},
    loadedAt = 0,
}

-- -----------------------------------------------------------------------------
-- Pure logic. No natives and no database, so busted can test it directly.
-- -----------------------------------------------------------------------------

--- Resolves a group's own permissions plus everything it inherits.
---
--- @param groupKey string
--- @param groups table group key -> { inherits = string|nil, permissions = { string } }
--- @param seen table|nil guards against a cycle in the inheritance chain
--- @return table set of permission keys
function Perms.expandGroup(groupKey, groups, seen)
    seen = seen or {}

    -- A group that inherits from itself, directly or through a chain, would
    -- otherwise recurse forever. The data allows it, so the code must not.
    if seen[groupKey] then return {} end
    seen[groupKey] = true

    local group = groups[groupKey]
    if not group then return {} end

    local result = {}

    if group.inherits then
        for permission in pairs(Perms.expandGroup(group.inherits, groups, seen)) do
            result[permission] = true
        end
    end

    for index = 1, #(group.permissions or {}) do
        result[group.permissions[index]] = true
    end

    return result
end

--- Every group a group stands for: itself and everything it inherits.
---
--- Membership, not permissions. A vehicle gated to `patrol` is drawable by a
--- supervisor because `supervisor` inherits `patrol` -- the supervisor really is
--- in the patrol bundle -- but not by a dispatcher who happens to hold the same
--- permission keys by another route. That distinction is the whole point of a
--- gate: "the air unit" means the people in it, not the people who could do
--- what it does.
---
--- @param groupKey string
--- @param groups table group key -> { inherits = string|nil, ... }
--- @param seen table|nil guards against a cycle in the inheritance chain
--- @return table set of group keys
function Perms.expandAncestry(groupKey, groups, seen)
    seen = seen or {}

    if seen[groupKey] then return seen end
    if not groups[groupKey] then return seen end

    seen[groupKey] = true

    local inherits = groups[groupKey].inherits
    if inherits then Perms.expandAncestry(inherits, groups, seen) end

    return seen
end

--- The union of every permission granted by a set of Discord roles in one agency.
---
--- @param roleIds table list of Discord role ids the member holds
--- @param rolesToGroups table role id -> { group keys }, for this agency
--- @param groupPermissions table group key -> set of permissions (already expanded)
--- @return table set of permission keys
function Perms.computeEffective(roleIds, rolesToGroups, groupPermissions)
    local effective = {}

    for index = 1, #roleIds do
        local groups = rolesToGroups[roleIds[index]]

        if groups then
            for groupIndex = 1, #groups do
                local permissions = groupPermissions[groups[groupIndex]]

                if permissions then
                    for permission in pairs(permissions) do
                        effective[permission] = true
                    end
                end
            end
        end
    end

    return effective
end

--- True when `effective` satisfies `required`.
---
--- A wildcard in the *grant* (`records.person.*`) matches any key beneath it.
--- Wildcards are deliberately not honoured in the *requirement*: a route asks
--- for exactly one permission, so that reading the route tells you what it needs.
---
--- The bare `'*'` is the same idea taken one level further: everything,
--- regardless of namespace. It exists for exactly one group, `superuser`
--- (`database/seeds/0003_superuser.sql`), granted only by the console command
--- `fredpd_superuser` -- never enumerated as a list of every key that exists,
--- because that list has already drifted once in this codebase (the group
--- editor's own `PERMISSION_CATALOGUE` is missing whole modules' worth of real
--- keys and offers several nothing checks any more). A wildcard cannot go
--- stale the way a list can.
function Perms.satisfies(effective, required)
    if effective['*'] then return true end
    if effective[required] then return true end

    -- Walk up the key: records.person.view -> records.person.* -> records.*
    local prefix = required

    while true do
        local cut = prefix:match('^(.*)%.[^.]+$')
        if not cut then return false end

        if effective[cut .. '.*'] then return true end
        prefix = cut
    end
end

-- -----------------------------------------------------------------------------
-- Loading
-- -----------------------------------------------------------------------------

--- Rebuilds the cache from the database.
---
--- Called at boot, after an administrator edits the role map, and after the
--- gateway pushes a Discord change (spec 4.2).
function Perms.reload()
    local db = FredPD.Core.db

    local groupRows = db.query('SELECT `key`, `inherits` FROM fpd_permission_groups')
    local permissionRows = db.query('SELECT `group_key`, `permission` FROM fpd_group_permissions')

    local groups = {}
    for index = 1, #groupRows do
        local row = groupRows[index]
        groups[row.key] = { inherits = row.inherits, permissions = {} }
    end

    for index = 1, #permissionRows do
        local row = permissionRows[index]
        local group = groups[row.group_key]
        if group then
            group.permissions[#group.permissions + 1] = row.permission
        end
    end

    -- Expand inheritance once here, so a permission check is a table lookup
    -- rather than a walk up the chain on every route call (spec 12).
    local groupPermissions = {}
    local groupAncestry = {}
    for groupKey in pairs(groups) do
        groupPermissions[groupKey] = Perms.expandGroup(groupKey, groups)
        groupAncestry[groupKey] = Perms.expandAncestry(groupKey, groups)
    end

    local mapRows = db.query('SELECT discord_role_id, group_key, agency_id FROM fpd_role_map')
    local roleMap = {}

    for index = 1, #mapRows do
        local row = mapRows[index]
        local agency = roleMap[row.agency_id] or {}
        local roles = agency[row.discord_role_id] or {}

        roles[#roles + 1] = row.group_key
        agency[row.discord_role_id] = roles
        roleMap[row.agency_id] = agency
    end

    cache.groupPermissions = groupPermissions
    cache.groupAncestry = groupAncestry
    cache.roleMap = roleMap
    cache.loadedAt = os.time()

    print(('[fredpd] permissions loaded: %d groups, %d role mappings'):format(#groupRows, #mapRows))
end

--- The Discord roles the gateway last saw for a member, and how stale they are.
--- @return table roleIds, number|nil ageSeconds
function Perms.memberRoles(discordId)
    local row = FredPD.Core.db.single(
        'SELECT roles, TIMESTAMPDIFF(SECOND, synced_at, NOW()) AS age FROM fpd_discord_members WHERE discord_id = ?',
        { discordId }
    )

    if not row then return {}, nil end

    local ok, roles = pcall(json.decode, row.roles)
    if not ok or type(roles) ~= 'table' then return {}, row.age end

    return roles, row.age
end

--- The groups a member is in, in one agency.
---
--- Membership rather than permissions, and the two answer different questions.
--- `effectiveFor` says what an officer may *do*; this says which bundles they
--- are *in*, which is what a gate on a group means. A dispatcher who happens to
--- hold every key the air unit holds is still not in the air unit.
---
--- A group the member holds brings the groups it inherits with it: holding
--- `supervisor`, which extends `patrol`, really does put them in patrol.
---
--- @return table set of group keys
function Perms.groupsFor(discordId, agencyId)
    local roleIds = Perms.memberRoles(discordId)
    local rolesToGroups = cache.roleMap[agencyId] or {}
    local ancestry = cache.groupAncestry or {}
    local held = {}

    for index = 1, #roleIds do
        local groupKeys = rolesToGroups[tostring(roleIds[index])]

        for position = 1, #(groupKeys or {}) do
            local key = groupKeys[position]

            -- Precomputed at reload; a group the cache has never heard of
            -- contributes only itself, so a gate naming it still fails closed.
            for ancestor in pairs(ancestry[key] or { [key] = true }) do
                held[ancestor] = true
            end
        end
    end

    return held
end

--- Effective permissions for a member in one agency.
--- @return table set of permission keys
function Perms.effectiveFor(discordId, agencyId)
    local roleIds = Perms.memberRoles(discordId)
    local rolesToGroups = cache.roleMap[agencyId] or {}

    return Perms.computeEffective(roleIds, rolesToGroups, cache.groupPermissions)
end

--- What a set of Discord roles would grant in one agency -- for asking what a
--- role is worth before it is handed out (ADR-022).
--- @return table set of permission keys
function Perms.ofRoles(roleIds, agencyId)
    return Perms.computeEffective(roleIds, cache.roleMap[agencyId] or {}, cache.groupPermissions or {})
end

--- Every agency that maps this Discord role to a group. Role actions refuse
--- a role worth something in another agency: the guards only weigh it in
--- the actor's own (ADR-022).
--- @return table list of agency ids
function Perms.agenciesMapping(roleId)
    local agencies = {}
    for agencyId, roles in pairs(cache.roleMap or {}) do
        if roles[roleId] then agencies[#agencies + 1] = agencyId end
    end
    return agencies
end

--- Permissions in `required` that `effective` does not already satisfy.
---
--- Used to stop an administrator granting a group that is worth more than what
--- they hold themselves. `admin.permissions.edit` lets someone map roles to
--- groups; without this, it also lets them map a role they hold to any group,
--- including one carrying record clearance the seed deliberately withheld from
--- `admin` (spec 4.3, Appendix C).
---
--- @param required table set of permission keys
--- @param effective table set the actor holds
--- @return table sorted list of what is missing; empty means the actor may grant it
function Perms.missing(required, effective)
    local missing = {}

    for permission in pairs(required) do
        if not Perms.satisfies(effective, permission) then
            missing[#missing + 1] = permission
        end
    end

    table.sort(missing)
    return missing
end

--- The expanded permission set of one group, or nil when it does not exist.
function Perms.permissionsOf(groupKey)
    return cache.groupPermissions[groupKey]
end

--- Exposed for the admin screen and for tests.
function Perms.groupKeys()
    local keys = {}
    for key in pairs(cache.groupPermissions) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

FredPD.Core.perms = Perms
