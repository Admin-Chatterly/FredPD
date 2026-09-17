--- The route layer (spec 3.5, invariant 3).
---
--- Every client-to-server call goes through here. This wrapper is the security
--- boundary, and the order of its checks is fixed:
---
---   session -> staleness -> permission -> context -> rate limit -> schema
---   -> handler (pcall) -> audit -> response
---
--- Record-level access checks happen inside services, on every read they do.
--- This layer cannot do them: it does not know what the handler is about to
--- fetch.
---
--- Response envelope: { ok = true, data = ... } or { ok = false, err = code }.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Route = {}

local registered = {}

-- -----------------------------------------------------------------------------
-- Lists in the response envelope
--
-- An empty Lua table is both `{}` and `[]`. Every encoder between this function
-- and the NUI has to guess which one it is, and they all guess object: a route
-- that returns an empty list -- a group created from the editor with no
-- permissions of its own, a search with no hits, a case with no notes -- reaches
-- the interface as `{}`, where `list.length` is `undefined` and `{#each}` over
-- it throws. That is a broken page on the first click after a create, in every
-- module, so it is fixed here rather than once per module.
--
-- The guess is only settled by a marker the encoder itself recognises. FiveM's
-- Lua JSON is lua-cjson, which decides from the marker metatables it exports
-- (`json.array_mt`, and `json.empty_array_mt` for the empty case) and not from
-- one of our own invention -- a plain `{ __jsontype = 'array' }` is the fix that
-- looks right and encodes nothing differently. A runtime that exports neither
-- (busted, and any encoder that already writes a sequence as an array) leaves
-- `ARRAY_MT` nil and the walk below becomes a no-op rather than an error.
-- -----------------------------------------------------------------------------

local ARRAY_MT = (type(json) == 'table' and (rawget(json, 'array_mt') or rawget(json, 'empty_array_mt'))) or nil

--- How deep the walk goes. A response is a record, not a tree; anything past
--- this is a bug somewhere else and is left alone rather than chased.
local MAX_DEPTH <const> = 12

--- True when `value` is a sequence: the keys 1..n, or no keys at all.
---
--- An empty table counts, which is the whole point -- and is also the one
--- judgement call here. A route that means to return an empty *object* has to
--- say so some other way, because nothing in the table itself can say it.
local function isSequence(value)
    local count = 0

    for key in pairs(value) do
        if type(key) ~= 'number' then return false end
        count = count + 1
    end

    return count == #value
end

--- Marks every list in a response so it encodes as a JSON array.
---
--- Walks the whole value: a list of rows each carrying lists of their own is the
--- normal shape here, and the empty one is usually the nested one. A table that
--- already carries a metatable is left alone, and a cycle is visited once.
function Route.markArrays(value, seen, depth)
    if type(value) ~= 'table' then return value end

    depth = depth or 1
    if depth > MAX_DEPTH then return value end

    seen = seen or {}
    if seen[value] then return value end
    seen[value] = true

    for _, entry in pairs(value) do
        Route.markArrays(entry, seen, depth + 1)
    end

    if ARRAY_MT and getmetatable(value) == nil and isSequence(value) then
        setmetatable(value, ARRAY_MT)
    end

    return value
end

--- Context conditions (spec 4.3). These *restrict* a granted permission; none
--- of them ever grants one.
local conditions = {}

--- Must be on duty, as p_policejob sees it (spec 3.11).
function conditions.onDuty(session)
    return FredPD.Bridge.policejob.isOnDuty(session.src)
end

--- Must be standing at a placement of the given kind (spec 3.10, ADR-006).
---
--- The client sends which placement it is using; the server checks the player
--- is genuinely within its radius. Without this, "only at the property
--- terminal" would be worth nothing, because any client could claim to be there.
function conditions.accessPoint(session, input, expectedKind)
    local placementId = input and input.placementId
    if type(placementId) ~= 'number' then return false end

    return FredPD.Core.placements.playerIsAt(session.src, placementId, expectedKind)
end

--- Must be in an agency vehicle.
function conditions.inAgencyVehicle(session)
    return FredPD.Bridge.policejob.isInAgencyVehicle(session.src)
end

--- Runs a route's context conditions.
--- @return boolean ok
--- @return string|nil which condition failed
local function checkContext(definition, session, input)
    local context = definition.context
    if not context then return true end

    for name, expected in pairs(context) do
        local check = conditions[name]

        -- An unknown condition is a typo in a route definition. Failing closed
        -- turns that into a visible refusal rather than a silent bypass.
        if not check then return false, name end

        if not check(session, input, expected) then
            return false, name
        end
    end

    return true
end

--- Declares a route.
---
--- @param definition table
---   name    string   'placement.create' -> callback 'fredpd:placement.create'
---   perm    string   a permission key from Appendix B
---   schema  string|nil  a key in FredPD.Schema
---   context table|nil   context conditions
---   limit   table|nil   { per, window }; defaults to the server config
---   audit   string|nil  action name written to the audit log on success
---   writes  boolean|nil  changes state; refused in read-only mode (4.2)
---   sensitive boolean|nil  refuse when the Discord snapshot is stale (4.2)
---   handler function(session, input) -> data
function Route.define(definition)
    assert(definition.name, 'route needs a name')
    assert(definition.perm, 'route needs a permission: ' .. tostring(definition.name))
    assert(definition.handler, 'route needs a handler: ' .. definition.name)
    assert(not registered[definition.name], 'route defined twice: ' .. definition.name)

    registered[definition.name] = definition

    local limit = definition.limit or FredPD.Config.server.rateLimit

    lib.callback.register('fredpd:' .. definition.name, function(src, input)
        local audit = FredPD.Core.audit

        -- 0. Shape. Schema validation happens at step 6, but context conditions
        --    at step 4 already read fields off `input`, and indexing a number
        --    raises in Lua -- which would throw outside the handler's pcall,
        --    skipping the audit entirely. Reject anything that is not a table
        --    here, where it costs one comparison.
        if input ~= nil and type(input) ~= 'table' then
            return { ok = false, err = FredPD.ErrorCode.INVALID, fields = { _input = 'type' } }
        end

        -- 1. Session
        local session = FredPD.Core.session.get(src)
        if not session then
            return { ok = false, err = FredPD.ErrorCode.NO_SESSION }
        end

        -- 2. Staleness, in the two tiers spec 4.2 defines. Both degrade toward
        --    less access: a gateway that stops answering must never widen what
        --    anyone can do. Reads keep working in either tier, so an outage
        --    does not lock officers out of the records entirely.
        if definition.sensitive and FredPD.Core.session.isStale(session) then
            audit.denied(session, definition.name, 'stale_permissions')
            return { ok = false, err = FredPD.ErrorCode.STALE_PERMISSIONS }
        end

        if definition.writes and FredPD.Core.session.isReadOnly(session) then
            audit.denied(session, definition.name, 'read_only')
            return { ok = false, err = FredPD.ErrorCode.STALE_PERMISSIONS }
        end

        -- 3. Permission
        if not FredPD.Core.perms.satisfies(session.permissions, definition.perm) then
            audit.denied(session, definition.name, 'forbidden')
            return { ok = false, err = FredPD.ErrorCode.FORBIDDEN }
        end

        -- 4. Context conditions
        local contextOk, failed = checkContext(definition, session, input)
        if not contextOk then
            audit.denied(session, definition.name, 'context:' .. tostring(failed))
            return { ok = false, err = FredPD.ErrorCode.CONTEXT }
        end

        -- 5. Rate limit
        local allowed = FredPD.Core.ratelimit.take(src, definition.name, limit)
        if not allowed then
            return { ok = false, err = FredPD.ErrorCode.RATE_LIMITED }
        end

        -- 6. Schema. The handler receives only declared fields, so a client
        --    cannot smuggle in a key the route never asked for (invariant 1).
        local cleaned = input
        if definition.schema then
            local fields
            cleaned, fields = FredPD.Core.validate.check(definition.schema, input)

            if not cleaned then
                return { ok = false, err = FredPD.ErrorCode.INVALID, fields = fields }
            end
        end

        -- 7. Handler
        local ok, result = pcall(definition.handler, session, cleaned)

        if not ok then
            -- The error text may name tables and columns, so it goes to the
            -- server console and the audit log, never to the client.
            print(('[fredpd] route %s failed: %s'):format(definition.name, tostring(result)))
            audit.write({
                action = definition.name,
                discordId = session.discordId,
                agencyId = session.agencyId,
                outcome = 'error',
                detail = { error = tostring(result) },
            })
            return { ok = false, err = FredPD.ErrorCode.INTERNAL }
        end

        -- A handler may refuse with a code of its own -- 'not_found',
        -- 'restricted', 'conflict' -- by returning a table shaped like this.
        if type(result) == 'table' and result.__err then
            audit.denied(session, definition.name, result.__err, definition.subjectType)
            return { ok = false, err = result.__err, fields = result.fields }
        end

        -- 8. Audit
        if definition.audit then
            audit.write({
                action = definition.audit,
                discordId = session.discordId,
                agencyId = session.agencyId,
                subjectType = definition.subjectType,
                subjectId = type(result) == 'table' and tostring(result.id or '') or nil,
                detail = definition.auditDetail and definition.auditDetail(cleaned, result) or nil,
            })
        end

        -- 9. Response. The wrapper order above is unchanged: marking lists is
        --    part of writing the answer, not a check, and it runs after the
        --    audit entry so nothing a handler returns can be audited as one
        --    shape and answered as another.
        return { ok = true, data = Route.markArrays(result) }
    end)
end

--- A handler's way of refusing with a specific code.
function Route.refuse(code, fields)
    return { __err = code, fields = fields }
end

--- Every registered route name, for the admin health screen.
function Route.names()
    local names = {}
    for name in pairs(registered) do names[#names + 1] = name end
    table.sort(names)
    return names
end

FredPD.Core.route = Route
