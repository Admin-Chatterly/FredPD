--- Suggesting real citizens and vehicles from ESX's own tables.
---
--- Two thin routes over `server/bridges/framework.lua`'s two ESX-table reads.
--- No `service.lua` or `repo.lua`: there is no FredPD-owned table here and
--- nothing to unit-test that is not already the bridge's own logic, so a
--- repo.lua for this module would be an empty file that existed to satisfy a
--- convention rather than to hold anything.
---
--- **Always a suggestion, never a link.** Picking a result prefills a form
--- the officer is still filling in -- registering a vehicle, creating a
--- person -- and every field it fills stays exactly as editable as if it had
--- been typed. Nothing here writes to a FredPD table, and nothing FredPD
--- later reads treats a person or vehicle as "the same as" the ESX row that
--- suggested it, beyond whatever the officer chose to copy in.
---
--- **Access is still the record's own**, not a new key for reading ESX data
--- itself: `esx.character.search` is useful only where a person could be
--- created (`rms.person.edit`) and `esx.vehicle.search` only where one could
--- be registered (`rms.vehicle.edit`), so both reuse the permission that
--- already gates the form this fills in, rather than inventing a separate
--- grant for "may see ESX's tables" that Appendix B would then have to carry
--- forever.

local route = FredPD.Core.route
local framework = FredPD.Bridge.framework

--- The shortest term worth a query against a table with no agency scope of
--- its own -- unlike FredPD's own registers, "browse everything" here would
--- mean everyone on the whole server, in every agency, which is a much
--- bigger disclosure than a short list of near-matches while typing.
local MIN_TERM = 2

local function normalizeTerm(value)
    if type(value) ~= 'string' then return nil end

    local text = value:match('^%s*(.-)%s*$') or ''
    if #text < MIN_TERM then return nil end

    return text
end

route.define({
    name = 'esx.character.search',
    perm = 'rms.person.edit',
    schema = 'EsxCharacterSearch',
    limit = { per = 30, window = 60 },
    handler = function(_session, input)
        local term = normalizeTerm(input.term)
        if not term then return route.refuse(FredPD.ErrorCode.INVALID, { term = 'too_short' }) end

        return { characters = framework.searchCharacters(term, input.limit) }
    end,
})

route.define({
    name = 'esx.vehicle.search',
    perm = 'rms.vehicle.edit',
    schema = 'EsxVehicleSearch',
    limit = { per = 30, window = 60 },
    handler = function(_session, input)
        local term = normalizeTerm(input.term)
        if not term then return route.refuse(FredPD.ErrorCode.INVALID, { term = 'too_short' }) end

        return { vehicles = framework.searchOwnedVehicles(term, input.limit) }
    end,
})
