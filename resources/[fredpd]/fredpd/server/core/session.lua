--- Sessions (spec 4.1, 4.6, invariant 1).
---
--- A session is what the server knows about a connected player: their Discord
--- identity, their bound character, their agency, and the permissions those
--- Discord roles currently grant.
---
--- Everything authoritative about an officer comes from here, never from route
--- input. A handler reads `session.discordId`; it never reads `input.officerId`.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Session = {}

--- server id -> session
local sessions = {}

--- Builds a session for a connected player, or returns nil with a reason.
---
--- @param src number server id
--- @return table|nil session
--- @return string|nil reason
function Session.open(src)
    local framework = FredPD.Bridge.framework

    local discordId = framework.getDiscordId(src)
    if not discordId then
        return nil, 'no_discord'
    end

    local character = framework.getCharacter(src)
    if not character then
        return nil, 'no_character'
    end

    -- The roster decides which character may open FredPD for which agency. A
    -- Discord user holds one bound character per agency, so agency access
    -- cannot be used from a criminal alt (spec 4.1).
    local officer = FredPD.Core.db.single(
        [[SELECT id, agency_id, callsign, name, identifier, active
            FROM fpd_officers
           WHERE discord_id = ? AND active = 1
           LIMIT 1]],
        { discordId }
    )

    if not officer then
        return nil, 'not_personnel'
    end

    if officer.identifier and officer.identifier ~= character.identifier then
        return nil, 'wrong_character'
    end

    local roles, snapshotAge = FredPD.Core.perms.memberRoles(discordId)

    local session = {
        src = src,
        discordId = discordId,
        officerId = officer.id,
        agencyId = officer.agency_id,
        callsign = officer.callsign,
        name = officer.name or (character.firstName .. ' ' .. character.lastName),
        identifier = character.identifier,
        roleCount = #roles,
        -- Stored as *when* the snapshot was taken, not how old it was at open.
        -- An age frozen at open never grows, so the outage policy below would
        -- never fire for anyone already connected -- which is exactly the
        -- window a gateway outage opens (spec 4.2).
        snapshotAt = snapshotAge and (os.time() - snapshotAge) or nil,
        permissions = FredPD.Core.perms.effectiveFor(discordId, officer.agency_id),
        openedAt = os.time(),
    }

    sessions[src] = session
    return session, nil
end

--- The session for a server id, opening one on first use.
function Session.get(src)
    local existing = sessions[src]
    if existing then return existing end

    return (Session.open(src))
end

function Session.drop(src)
    sessions[src] = nil
end

--- Recomputes permissions for every open session.
---
--- Called when the gateway pushes a Discord role change, and when an
--- administrator edits the role map. An open MDT loses pages the moment a role
--- is removed (spec 4.2), which only works because this exists.
function Session.refreshAll()
    for src, session in pairs(sessions) do
        session.permissions = FredPD.Core.perms.effectiveFor(session.discordId, session.agencyId)
        local _, age = FredPD.Core.perms.memberRoles(session.discordId)
        session.snapshotAt = age and (os.time() - age) or nil

        FredPD.Core.push.toSession(src, 'fredpd:permissions', {
            modules = Session.allowedModules(session),
        })
    end
end

--- How old this session's permission snapshot is, right now.
---
--- Returns nil when the gateway has never seen this member, which every caller
--- below treats as maximally stale: we know nothing about their roles.
function Session.snapshotAge(session)
    if session.snapshotAt == nil then return nil end

    return os.time() - session.snapshotAt
end

--- True when the snapshot is too old to trust for a sensitive action
--- (spec 4.2). Degrades toward less access, never toward more.
function Session.isStale(session)
    local age = Session.snapshotAge(session)
    if age == nil then return true end

    return age > FredPD.Config.server.discord.sensitiveStaleAfterSeconds
end

--- True when the snapshot is old enough that the session may only read
--- (spec 4.2, second tier). A gateway that has been down for hours must not
--- leave officers writing records against role data nobody can vouch for.
function Session.isReadOnly(session)
    local age = Session.snapshotAge(session)
    if age == nil then return true end

    return age > FredPD.Config.server.discord.readOnlyAfterSeconds
end

--- Which modules this session may open, for the NUI's module rail.
---
--- The list is derived from permissions on the server. The UI draws what it is
--- given and decides nothing (invariant 4).
function Session.allowedModules(session)
    local modules = {}
    local pages = {
        records = 'page.records',
        dispatch = 'page.dispatch',
        evidence = 'page.evidence',
        lab = 'page.lab',
        intel = 'page.intel',
        court = 'page.court',
        personnel = 'page.personnel',
        comms = 'page.comms',
        admin = 'page.admin',
    }

    -- Stable order, so the rail does not reshuffle between sessions.
    local order = { 'records', 'dispatch', 'evidence', 'lab', 'intel', 'court', 'personnel', 'comms', 'admin' }

    for index = 1, #order do
        local name = order[index]
        if FredPD.Core.perms.satisfies(session.permissions, pages[name]) then
            modules[#modules + 1] = name
        end
    end

    return modules
end

--- Every open session, for the push layer to filter.
function Session.all()
    return sessions
end

AddEventHandler('playerDropped', function()
    Session.drop(source)
end)

FredPD.Core.session = Session
