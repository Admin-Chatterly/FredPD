--- Placement logic (spec 3.10, ADR-006).
---
--- Pure: no natives, no database, so busted tests it directly. The proximity
--- rule in particular is the control that makes access points mean anything, so
--- it is worth testing rather than trusting.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Placements = {}

--- How much slack to allow on top of a placement's radius.
---
--- The player's reported position and the server's view of it drift by a little
--- under latency, and a legitimate officer standing at the counter should not be
--- refused because of it. Small enough that it cannot be used to reach a
--- terminal from outside the room.
local TOLERANCE_METRES <const> = 1.0

--- Squared distance, to avoid a square root on a check that runs per route call.
function Placements.distanceSquared(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return dx * dx + dy * dy + dz * dz
end

--- Is a position close enough to a placement to count as standing at it?
---
--- @param placement table with x, y, z and radius
--- @param x number
--- @param y number
--- @param z number
--- @return boolean
function Placements.isWithin(placement, x, y, z)
    if not placement then return false end

    local reach = (placement.radius or 1.5) + TOLERANCE_METRES

    return Placements.distanceSquared(placement.x, placement.y, placement.z, x, y, z) <= reach * reach
end

--- Can this session use this placement at all, ignoring distance?
---
--- A placement bound to one agency is not an entrance for another, and a
--- disabled placement is not an entrance for anyone.
---
--- @param placement table
--- @param agencyId string the session's agency
--- @param expectedKind string|nil the kind the route requires
--- @return boolean ok
--- @return string|nil reason
function Placements.isUsableBy(placement, agencyId, expectedKind)
    if not placement then return false, 'not_found' end
    if placement.enabled == false then return false, 'disabled' end

    if expectedKind and placement.kind ~= expectedKind then
        return false, 'wrong_kind'
    end

    -- A NULL agency means shared between agencies (spec 3.10).
    if placement.agencyId ~= nil and placement.agencyId ~= agencyId then
        return false, 'other_agency'
    end

    return true
end

--- What a placement looks like to a client.
---
--- Deliberately narrow: coordinates, model and label key, and nothing about
--- permissions. A client knowing a door exists is not a client that can open it
--- (ADR-006), and the route it eventually calls checks the permission anyway.
function Placements.forClient(placement)
    return {
        id = placement.id,
        kind = placement.kind,
        interaction = placement.interaction,
        model = placement.model,
        x = placement.x,
        y = placement.y,
        z = placement.z,
        heading = placement.heading,
        radius = placement.radius,
        labelKey = placement.labelKey,
    }
end

--- Validates a placement beyond what the schema can express.
---
--- @return string|nil error code, nil when fine
--- @return table|nil fields
function Placements.validate(input)
    -- A prop or ped placement without a model has nothing to bind to or spawn.
    if (input.interaction == 'prop' or input.interaction == 'ped') and not input.model then
        return 'invalid', { model = 'required' }
    end

    -- A zone needs no model, and accepting one would imply an entity that is
    -- never created.
    if input.interaction == 'zone' and input.model then
        return 'invalid', { model = 'not_allowed' }
    end

    return nil
end

FredPD.Modules.placements = Placements
