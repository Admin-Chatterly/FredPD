--- Placement runtime (spec 3.10, ADR-006).
---
--- Holds the placement cache and answers the one question the route layer needs
--- for the `accessPoint` context condition: is this player actually standing at
--- the placement they claim to be using?
---
--- This lives in core rather than in the module because it uses natives to read
--- the player's position, and `service.lua` files stay native-free so they can
--- be unit-tested (spec 3.4). The distance rule itself is in the service; this
--- only supplies the coordinates.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Placements = {}

--- id -> placement
local byId = {}

--- Reloads the cache and pushes the new world geometry to every client.
function Placements.reload()
    local rows = FredPD.Repo.placements.all()

    byId = {}
    for index = 1, #rows do
        byId[rows[index].id] = rows[index]
    end

    Placements.pushToAll()
    print(('[fredpd] placements loaded: %d'):format(#rows))
end

function Placements.get(id)
    return byId[id]
end

function Placements.all()
    return byId
end

--- The enabled placements a client should draw.
---
--- Geometry only -- no permissions (ADR-006). Agency-scoped placements are
--- filtered so an officer does not see another agency's terminals, but that is
--- tidiness, not access control: the route checks the permission regardless.
function Placements.forSession(session)
    local list = {}

    for _, placement in pairs(byId) do
        local usable = FredPD.Modules.placements.isUsableBy(placement, session.agencyId)

        if usable then
            list[#list + 1] = FredPD.Modules.placements.forClient(placement)
        end
    end

    return list
end

--- Pushes placements to one session.
function Placements.pushTo(src)
    local session = FredPD.Core.session.get(src)
    if not session then return end

    FredPD.Core.push.toSession(src, 'fredpd:placements', { placements = Placements.forSession(session) })
end

--- Pushes to every open session, after an edit.
function Placements.pushToAll()
    for src in pairs(FredPD.Core.session.all()) do
        Placements.pushTo(src)
    end
end

--- Is the player genuinely at this placement? (The control behind access points.)
---
--- The client tells us which placement it is using; this checks that claim
--- against the player's server-side position. Without it, "only at the property
--- terminal" would be worth nothing.
---
--- @param src number
--- @param placementId number
--- @param expectedKind string|nil
--- @return boolean
function Placements.playerIsAt(src, placementId, expectedKind)
    local placement = byId[placementId]
    if not placement then return false end

    local session = FredPD.Core.session.get(src)
    if not session then return false end

    local usable = FredPD.Modules.placements.isUsableBy(placement, session.agencyId, expectedKind)
    if not usable then return false end

    local ped = GetPlayerPed(src)
    if ped == 0 then return false end

    local position = GetEntityCoords(ped)

    return FredPD.Modules.placements.isWithin(placement, position.x, position.y, position.z)
end

FredPD.Core.placements = Placements
