--- The population register: which framework keys FredPD already has a record
--- for. Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local function marks(count)
    local out = {}
    for index = 1, count do out[index] = '?' end
    return table.concat(out, ', ')
end

--- The set of `values` present in `column` of `tableName` for this agency.
--- `tableName` and `column` are this file's own literals, never input.
local function present(tableName, column, agencyId, values)
    local set = {}
    if #values == 0 then return set end

    local params = { agencyId }
    for _, value in ipairs(values) do params[#params + 1] = value end

    local rows = db().query(
        ('SELECT %s AS value FROM %s WHERE agency_id = ? AND %s IN (%s)')
            :format(column, tableName, column, marks(#values)),
        params)

    for _, row in ipairs(rows) do set[row.value] = true end
    return set
end

--- Which character identifiers already have a person record here.
function Repo.identifiersOnFile(agencyId, identifiers)
    return present('fpd_persons', 'identifier', agencyId, identifiers)
end

--- Which plates already have a vehicle record here.
function Repo.platesOnFile(agencyId, plates)
    return present('fpd_vehicles', 'plate', agencyId, plates)
end

FredPD.Repo.population = Repo
