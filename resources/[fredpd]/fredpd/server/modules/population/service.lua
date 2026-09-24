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
---
--- LIKE's own wildcards are taken out first: `__` would otherwise pass the
--- two-character minimum and match every row of a table with no agency
--- scope, which is the browse the minimum exists to prevent.
function Population.term(value)
    if type(value) ~= 'string' then return nil end

    local text = value:gsub('[%%_\\]', ' '):match('^%s*(.-)%s*$') or ''
    if #text < Population.MIN_TERM then return nil end

    return text:sub(1, 128)
end

-- -----------------------------------------------------------------------------
-- References (the key a suggestion carries)
-- -----------------------------------------------------------------------------
--
-- A suggestion does not carry the framework's key -- a character identifier
-- is a player's licence -- but a short reference, valid for the officer it
-- was offered to, for a while. Opening takes the reference and nothing else,
-- so only what the server itself offered can be opened: a key learned
-- anywhere else cannot be tried (ADR-026).

--- How long an offered reference can be opened, in seconds.
Population.REF_TTL = 600

--- How many live references one officer holds; the oldest go first.
Population.REF_CAP = 40

--- Records `key` as offered to `officer`, and returns its reference.
---
--- @param store table the module's own, keyed by officer
--- @param officer string the session's Discord id
--- @param kind string 'person' | 'vehicle'
--- @param key string the framework's key
--- @param now number epoch seconds
--- @return string ref
function Population.remember(store, officer, kind, key, now)
    local own = store[officer]
    if not own then
        own = { next = 0, order = {}, entries = {} }
        store[officer] = own
    end

    own.next = own.next + 1
    local ref = ('%s%d'):format(kind:sub(1, 1), own.next)
    own.entries[ref] = { kind = kind, key = key, at = now }
    own.order[#own.order + 1] = ref

    while #own.order > Population.REF_CAP do
        own.entries[table.remove(own.order, 1)] = nil
    end

    return ref
end

--- The key a reference was offered for, or nil: another officer's, another
--- kind's, expired or never offered all answer the same.
function Population.recall(store, officer, kind, ref, now)
    local own = store[officer]
    local entry = own and type(ref) == 'string' and own.entries[ref]
    if not entry or entry.kind ~= kind or now - entry.at > Population.REF_TTL then return nil end

    return entry.key
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

--- What a person suggestion shows: who, and the reference that opens it.
--- The identifier and the phone number stay on the server.
function Population.person(row, ref)
    return {
        ref = ref,
        firstName = row.firstName ~= '' and row.firstName or nil,
        lastName = row.lastName ~= '' and row.lastName or nil,
        dateOfBirth = row.dateOfBirth ~= '' and row.dateOfBirth or nil,
    }
end

--- What a vehicle suggestion shows: the plate, and the reference that opens
--- it. The owner stays on the server.
function Population.vehicle(plate, ref)
    return { ref = ref, plate = plate }
end

FredPD.Modules.population = Population

return Population
