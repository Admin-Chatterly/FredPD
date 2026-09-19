--- Agencies (spec 3.9, 7.30).
---
--- Small, cached and read-often: the NUI shell asks for the agency name on every
--- session open, and nothing about an agency changes at runtime except through
--- the admin screen, which reloads this.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Agencies = {}

local byId = {}

function Agencies.reload()
    local rows = FredPD.Core.db.query(
        'SELECT id, name, short_name AS shortName, accent_color AS accentColor FROM fpd_agencies WHERE enabled = 1'
    )

    byId = {}
    for index = 1, #rows do
        byId[rows[index].id] = rows[index]
    end

    print(('[fredpd] agencies loaded: %d'):format(#rows))
end

function Agencies.get(id)
    return byId[id]
end

--- The display name, falling back to the id.
---
--- A missing agency here means the roster references one that was deleted, which
--- should be visible in the UI rather than rendered as a blank.
function Agencies.nameOf(id)
    local agency = byId[id]
    return agency and agency.name or id
end

function Agencies.all()
    return byId
end

FredPD.Core.agencies = Agencies
