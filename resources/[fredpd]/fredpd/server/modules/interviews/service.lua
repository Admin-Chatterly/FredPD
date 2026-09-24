--- Field interviews and stop data (spec 7.14): the pure part.
---
--- No natives, no database (`spec/interviews_spec.lua`).

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Interviews = {}

Interviews.MAX_ASSOCIATES = 10

--- The associate ids a card names, as integers, deduplicated, without the
--- subject themselves. Nil and a reason for anything that is not a list of
--- positive integers.
---
--- @param values string[]|nil as the schema delivers them
--- @param subjectId number|nil the card's own person
--- @return table|nil ids
--- @return string|nil reason 'format' or 'too_many'
function Interviews.associateIds(values, subjectId)
    if values == nil then return {} end
    if type(values) ~= 'table' then return nil, 'format' end
    if #values > Interviews.MAX_ASSOCIATES then return nil, 'too_many' end

    local out, seen = {}, {}

    for _, value in ipairs(values) do
        local id = tonumber(value)
        if not id or id < 1 or id ~= math.floor(id) then return nil, 'format' end

        if id ~= subjectId and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end

    return out
end

--- Does a card say anything at all? A person, a vehicle or a narrative.
function Interviews.hasSubject(input)
    return input.personId ~= nil or input.vehicleId ~= nil
        or (type(input.narrative) == 'string' and input.narrative:match('%S') ~= nil)
end

FredPD.Modules.interviews = Interviews

return Interviews
