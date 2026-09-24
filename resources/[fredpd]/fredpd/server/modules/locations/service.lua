--- Locations and premises (spec 7.6): the pure part.
---
--- No natives, no database, so busted exercises it (`spec/locations_spec.lua`).
--- What lives here is geometry and time: whether a call is *at* a premise, and
--- whether a hazard still stands.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Locations = {}

--- How far from its point a call still counts as at a premise, by default.
Locations.DEFAULT_RADIUS = 30

--- The furthest any premise reaches. Bounds the square the repo searches, so
--- a call never has to be measured against every address on the server.
Locations.MAX_RADIUS = 500

--- The address as the index keeps it: trimmed, one space between words. Nil
--- for nothing at all.
function Locations.normalizeLabel(value)
    if type(value) ~= 'string' then return nil end

    local label = value:gsub('%s+', ' '):match('^%s*(.-)%s*$')
    if label == '' then return nil end

    return label
end

--- Do two addresses name the same place? Case and spacing do not count:
--- "12 alta street" typed on a phone call is "12 Alta Street" in the index.
function Locations.sameLabel(a, b)
    local left, right = Locations.normalizeLabel(a), Locations.normalizeLabel(b)
    return left ~= nil and right ~= nil and left:lower() == right:lower()
end

--- Is this point within the premise? A premise with no position is never
--- *at* a point; it can still be matched by its address.
function Locations.contains(location, point)
    if type(location) ~= 'table' or type(point) ~= 'table' then return false end
    if not location.x or not location.y or not point.x or not point.y then return false end

    local radius = tonumber(location.radius) or Locations.DEFAULT_RADIUS
    local dx, dy = point.x - location.x, point.y - location.y

    return (dx * dx + dy * dy) <= radius * radius
end

--- Does a hazard still stand? Cancelled is gone; expired is gone; a hazard
--- with no expiry stands until somebody cancels it.
---
--- @param hazard table { cancelledAt, expiresAt } epoch seconds or nil
--- @param now number epoch seconds
function Locations.isLive(hazard, now)
    if type(hazard) ~= 'table' or hazard.cancelledAt then return false end
    return hazard.expiresAt == nil or hazard.expiresAt > now
end

--- The premises a call is at: by position when it has one, and by address
--- when its location text names one exactly. Deduplicated, in the order given.
---
--- @param locations table candidate premises (already near, or matched by text)
--- @param call table { x, y, locationText }
function Locations.premisesFor(locations, call)
    local out, seen = {}, {}

    for _, location in ipairs(locations or {}) do
        local at = Locations.contains(location, call)
            or Locations.sameLabel(location.label, call.locationText)

        if at and not seen[location.id] then
            seen[location.id] = true
            out[#out + 1] = location
        end
    end

    return out
end

FredPD.Modules.locations = Locations

return Locations
