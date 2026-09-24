--- Who is standing at a public desk (spec 7.29, ADR-023).
---
--- The subject tier's identity: resolved here, by the server, from the player
--- and the placement -- never from anything the client sends (invariant 1).
--- A player is a subject only while standing at a public placement, and only
--- as the character the framework says they are playing.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Subject = {}

--- @param src number
--- @param placementId number the desk the player says they are at
--- @return table|nil subject { src, placementId, agencyId, identifier, name, personId }
--- @return string|nil reason 'not_here' | 'no_character'
function Subject.resolve(src, placementId)
    local placement = FredPD.Core.placements.publicAt(src, placementId)
    if not placement then return nil, 'not_here' end

    local character = FredPD.Bridge.framework.getCharacter(src)
    if not character or type(character.identifier) ~= 'string' or character.identifier == '' then
        return nil, 'no_character'
    end

    -- A desk shared between agencies (no agency of its own) answers for the
    -- server's.
    local agencyId = placement.agencyId or FredPD.Config.server.agency.id
    local name = ('%s %s'):format(character.firstName or '', character.lastName or ''):match('^%s*(.-)%s*$')

    return {
        src = src,
        placementId = placement.id,
        placementKind = placement.kind,
        agencyId = agencyId,
        identifier = character.identifier,
        name = name ~= '' and name or character.identifier,
        personId = FredPD.Repo.persons.byIdentifier(agencyId, character.identifier),
    }
end

FredPD.Core.subject = Subject

return Subject
