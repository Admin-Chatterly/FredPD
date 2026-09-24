--- The population register (folkbokföringen): the pure part.
---
--- Every character and every owned vehicle the framework knows exists in the
--- world before FredPD has a record of it. A search that looks only in
--- FredPD's own registers cannot find a citizen nobody has run a check on --
--- the officer's own character included -- so person and vehicle searches
--- also show the matches that are *not yet on file*, and opening one creates
--- the record from the framework's own data (`routes.lua`).
---
--- No natives and no database (`spec/population_spec.lua`).

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Population = {}

--- The shortest term the framework's tables are searched for: they have no
--- agency scope, so "browse" would be everyone on the server.
Population.MIN_TERM = 2

--- How many not-yet-on-file matches a search shows. They are suggestions
--- under the real results, not a register of their own.
Population.LIMIT = 10

--- A search term worth taking to the framework's tables, or nil.
function Population.term(value)
    if type(value) ~= 'string' then return nil end

    local text = value:match('^%s*(.-)%s*$') or ''
    if #text < Population.MIN_TERM then return nil end

    return text:sub(1, 128)
end

--- The rows whose key is not already on file, in order, at most `limit`.
---
--- A key on file counts whatever the record's access: a citizen whose
--- record this reader may not see is not offered as "not yet on file"
--- either, so the suggestion never says a hidden record is missing (4.5).
---
--- @param rows table
--- @param key function(row) -> string|nil
--- @param onFile table set of keys
--- @param limit number|nil
function Population.notOnFile(rows, key, onFile, limit)
    local out, seen = {}, {}
    for _, row in ipairs(rows or {}) do
        local value = key(row)
        if value and not onFile[value] and not seen[value] then
            seen[value] = true
            out[#out + 1] = row
            if #out >= (limit or Population.LIMIT) then break end
        end
    end
    return out
end

--- What a person suggestion shows: who, and the identifier that opens it.
--- The phone number stays in the framework until the record is opened.
function Population.person(row)
    return {
        identifier = row.identifier,
        firstName = row.firstName ~= '' and row.firstName or nil,
        lastName = row.lastName ~= '' and row.lastName or nil,
        dateOfBirth = row.dateOfBirth ~= '' and row.dateOfBirth or nil,
    }
end

--- What a vehicle suggestion shows: the plate that opens it. The owner's
--- identifier stays on the server.
function Population.vehicle(plate)
    return { plate = plate }
end

FredPD.Modules.population = Population

return Population
