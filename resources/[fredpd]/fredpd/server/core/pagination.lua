--- Keyset pagination (spec 12.2).
---
--- Every list in this suite capped at a fixed page with no way past it, so
--- the 51st wanted notice could never be reached no matter how an officer
--- filtered. This is the shared cursor codec every paginated `repo.lua`
--- function builds its own keyset `WHERE` clause around -- the codec is
--- generic, the clause is not, because a mixed-direction sort like
--- `priority ASC, issued_at DESC` needs `WHERE priority > ? OR (priority = ?
--- AND issued_at < ?)`, and a single `created_at DESC` needs only
--- `WHERE (created_at, id) < (?, ?)`. There is no single fragment both of
--- those are a special case of without either overcomplicating the simple
--- one or quietly getting the mixed one wrong.
---
--- A cursor is opaque to the client in the sense that matters -- it is never
--- interpreted as anything but "the last row's sort key values" -- but it is
--- not encrypted or signed. It carries nothing sensitive (a timestamp, an id,
--- a priority), and a forged one only ever produces a differently-scoped page
--- of rows the reader was already allowed to see: every row a cursor's WHERE
--- clause reaches still goes through the same `agency_id` filter and the same
--- `access.filterSearch` the first page does.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Pagination = {}

local SEPARATOR <const> = ':'

--- @param values table array of integers (epoch seconds, ids, small enums)
--- @return string
function Pagination.encode(values)
    local parts = {}
    for index = 1, #values do
        parts[index] = tostring(math.floor(values[index]))
    end

    return table.concat(parts, SEPARATOR)
end

--- @param cursor string|nil
--- @param count integer how many integers the cursor must carry
--- @return table|nil values, or nil if `cursor` is nil, empty, or malformed
function Pagination.decode(cursor, count)
    if cursor == nil or cursor == '' then return nil end
    if type(cursor) ~= 'string' then return nil end

    local values = {}
    for part in cursor:gmatch('([^' .. SEPARATOR .. ']+)') do
        -- Digits only, optionally signed -- never handed to SQL as anything
        -- but a bound parameter, but a cursor that is not even a number is a
        -- cursor that was not one of ours.
        if not part:match('^%-?%d+$') then return nil end
        values[#values + 1] = math.floor(tonumber(part))
    end

    if #values ~= count then return nil end

    return values
end

FredPD.Core.pagination = Pagination

return Pagination
