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

        return { ok = true, data = result }
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
