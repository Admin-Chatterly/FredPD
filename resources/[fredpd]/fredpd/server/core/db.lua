--- Database access (spec 3.3, invariant 8).
---
--- A thin wrapper over oxmysql. Its one job beyond convenience is to make the
--- parameterized form the easy form: every function here takes placeholders and
--- a values table, and nothing in FredPD builds SQL by concatenation.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Db = {}

--- Rows for a query.
--- @param query string SQL with `?` placeholders
--- @param values table|nil
--- @return table rows
function Db.query(query, values)
    return MySQL.query.await(query, values or {}) or {}
end

--- The first row, or nil.
function Db.single(query, values)
    return MySQL.single.await(query, values or {})
end

--- A single scalar from the first row, or nil.
function Db.scalar(query, values)
    return MySQL.scalar.await(query, values or {})
end

--- Runs a statement and returns the number of rows it affected.
function Db.execute(query, values)
    return MySQL.update.await(query, values or {}) or 0
end

--- Runs an INSERT and returns the new id.
function Db.insert(query, values)
    return MySQL.insert.await(query, values or {})
end

--- Runs several statements in one transaction.
--- @param statements table list of { query = string, values = table }
--- @return boolean committed
function Db.transaction(statements)
    local prepared = {}

    for index = 1, #statements do
        prepared[index] = { query = statements[index].query, values = statements[index].values or {} }
    end

    return MySQL.transaction.await(prepared)
end

--- Confirms the schema is present before anything tries to use it.
---
--- Migrations are applied by the operator (M1 adds the runner), so the failure
--- mode this guards against is a server started against an empty or outdated
--- database, where every route would otherwise fail one confusing query at a
--- time (spec 16).
--- @param required table list of table names
function Db.verifySchema(required)
    local missing = {}

    for index = 1, #required do
        local name = required[index]
        local found = Db.scalar(
            'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?',
            { name }
        )

        if not found or found == 0 then
            missing[#missing + 1] = name
        end
    end

    if #missing > 0 then
        error(('[fredpd] database is missing %s. Apply database/migrations in order.'):format(
            table.concat(missing, ', ')
        ))
    end
end

FredPD.Core.db = Db
