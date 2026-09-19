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
--- There are two tiers, and one gateway. `Route.define` is the officer tier and
--- the one nearly everything uses. `Route.public` (ADR-013) is for the handful
--- of actions spec 8.10 says every player may take -- leaving a trace, cleaning
--- one up -- which no session could ever cover, because a criminal has no
--- `fpd_officers` row and therefore no session at all. It drops the session and
--- everything built on one, and keeps the envelope, the limiter and the schema.
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

        -- 9. Response. The wrapper order above is unchanged: marking lists is
        --    part of writing the answer, not a check, and it runs after the
        --    audit entry so nothing a handler returns can be audited as one
        --    shape and answered as another.
        return { ok = true, data = FredPD.markArrays(result) }
    end)
end

--- Fields that only mean something with a session behind them.
---
--- A public route has no session, so each of these would be a check that
--- silently never runs. `perm` is the one that matters: a route declaring a
--- permission it does not enforce is a route whose author believed it was
--- protected, which is worse than one that never claimed to be.
local SESSION_ONLY <const> = {
    'perm', 'context', 'audit', 'auditDetail', 'writes', 'sensitive', 'subjectType',
}

--- Declares a route every player can call, officer or not (spec 8.10, ADR-013).
---
--- Same gateway, same envelope, same limiter, same validator as `Route.define`
--- (invariant 3). What it drops is the session and therefore everything built on
--- one. The order is:
---
---   shape -> rate limit -> schema -> handler (pcall) -> response
---
--- The handler receives the numeric `src`, not a session, so it cannot reach for
--- `session.agencyId` or `session.officerId` and cannot touch a record: every
--- record path in this codebase needs a session for the agency and the access
--- check. A public handler acts on the world, never on the files.
---
--- The signature is what makes that natural, but it is not on its own what makes
--- it true: a handler holding a number can still write
--- `FredPD.Core.session.get(src)` and have the whole session back, agency and
--- permissions included. So the claim is enforced rather than hoped for.
--- `tools/wiring-check.ts` reads every `route.public` handler body and fails the
--- build on a reference to `FredPD.Core.session`, `FredPD.Core.perms`,
--- `FredPD.Core.access`, `FredPD.Modules.access` or a repo. Do not route around
--- that check; if a public action genuinely needs one of them, it is not a
--- public action, and ADR-013 says what to write instead.
---
--- @param definition table
---   name    string   'forensics.destroy' -> callback 'fredpd:forensics.destroy'
---   schema  string   a key in FredPD.Schema; required, see below
---   limit   table     { per, window }; required, see below
---   handler function(src, input) -> data
function Route.public(definition)
    assert(definition.name, 'public route needs a name')
    assert(definition.handler, 'public route needs a handler: ' .. tostring(definition.name))

    -- Not defaulted, unlike `Route.define`'s. A permissioned route is bounded
    -- twice -- by who holds the permission, and then by the limit -- so falling
    -- back to the server default costs it little. A public route has only the
    -- limit, so a missing one is an unbounded call path open to every connected
    -- player. Refusing to start is the loud version of that.
    -- Both halves, because a `limit` missing its `window` raises inside the
    -- limiter on the first call rather than at load, which is a route that
    -- starts and then answers `internal` to everyone who touches it.
    assert(
        type(definition.limit) == 'table'
            and type(definition.limit.per) == 'number'
            and type(definition.limit.window) == 'number',
        'public route needs an explicit limit { per, window }: ' .. tostring(definition.name)
    )

    -- Not optional, unlike `Route.define`'s, and for the same reason the limit
    -- is not. The schema is the only thing that caps the size of what arrives
    -- and drops the keys the route never asked for (invariant 1); on a
    -- permissioned route a missing one is still behind a permission, while here
    -- it is an unvalidated table from anybody who can connect. A public route
    -- taking no arguments declares a schema with no fields rather than none at
    -- all, which costs one line and says so on purpose.
    assert(
        type(definition.schema) == 'string',
        'public route needs a schema: ' .. tostring(definition.name)
    )

    for index = 1, #SESSION_ONLY do
        local field = SESSION_ONLY[index]

        assert(
            definition[field] == nil,
            ('public route %s declares %s, which needs a session it will never have')
                :format(definition.name, field)
        )
    end

    -- The same table `Route.define` writes to, so a public route colliding with
    -- a permissioned one is still caught here rather than at the second
    -- `lib.callback.register`, and so `Route.names()` lists both tiers.
    assert(not registered[definition.name], 'route defined twice: ' .. definition.name)

    registered[definition.name] = definition

    local limit = definition.limit

    lib.callback.register('fredpd:' .. definition.name, function(src, input)
        -- 0. Shape, for the same reason `Route.define` checks it: indexing a
        --    number raises, and here it would raise outside the handler's pcall.
        if input ~= nil and type(input) ~= 'table' then
            return { ok = false, err = FredPD.ErrorCode.INVALID, fields = { _input = 'type' } }
        end

        -- 1. Rate limit. First rather than fifth, because there is no session,
        --    permission or context ahead of it: this is the only thing standing
        --    between a looping client and the handler.
        if not FredPD.Core.ratelimit.take(src, definition.name, limit) then
            return { ok = false, err = FredPD.ErrorCode.RATE_LIMITED }
        end

        -- 2. Schema. Unknown keys are dropped here exactly as they are for a
        --    permissioned route (invariant 1). Unconditional, because the
        --    assertion above means a public route without one never loaded.
        local cleaned, fields = FredPD.Core.validate.check(definition.schema, input)

        if not cleaned then
            return { ok = false, err = FredPD.ErrorCode.INVALID, fields = fields }
        end

        -- 3. Handler, with `src` and not a session.
        local ok, result = pcall(definition.handler, src, cleaned)

        if not ok then
            -- The error text may name tables and columns, so it goes to the
            -- console and never to the client. There is no audit row to write
            -- with it: an audit entry is attributed to a `discordId`, and a
            -- public caller has no session to take one from. This is not an
            -- omission -- see ADR-013.
            --
            -- Nor is it a claim that everything a public route does turns up in
            -- the log later. `forensics.observe` does: a trace lands in a record
            -- when an officer collects it, and `evidence.collect` audits that.
            -- `forensics.destroy` does not, and cannot: destruction leaves
            -- nothing behind to audit, only a trace missing from the in-memory
            -- grid and a number added to the grid's `destroyed` total. That
            -- total is what the `admin.health` route returns and the Health tab
            -- of the Administration screen draws, behind `admin.health.view`,
            -- and it is the compensating control ADR-013 argues from: without a
            -- reader, a trace destroyed by a sessionless caller would leave no
            -- observable signal on the server at all. It counts since the
            -- resource last started, which the screen says, so it is a signal
            -- and not a ledger.
            -- The one row destruction can produce is written on that route's own
            -- side and never here, because only it can tell its two callers
            -- apart: a caller who does happen to hold a session is an officer
            -- destroying evidence, and has a `discordId` to name; a criminal has
            -- none, so there is nothing to attribute a row to, which is the case
            -- this whole tier exists for.
            print(('[fredpd] public route %s failed: %s'):format(definition.name, tostring(result)))
            return { ok = false, err = FredPD.ErrorCode.INTERNAL }
        end

        -- A handler refuses with its own code the same way, and it answers the
        -- identical envelope. No `audit.denied` for the reason above.
        if type(result) == 'table' and result.__err then
            return { ok = false, err = result.__err, fields = result.fields }
        end

        -- 4. Response.
        return { ok = true, data = FredPD.markArrays(result) }
    end)
end

--- A handler's way of refusing with a specific code.
---
--- Works from both tiers: `Route.public` reads `__err` the same way.
function Route.refuse(code, fields)
    return { __err = code, fields = fields }
end

--- Every registered route name, both tiers.
---
--- Two callers, and both want the count rather than the names: the boot banner
--- in `server/main.lua`, and the `admin.health` route, which reports how many
--- routes came up on the Health tab. Both take `#` of what comes back, so this
--- must keep returning a sequence -- a set keyed by name would read as zero on
--- both, on a server that is perfectly healthy, with nothing failing anywhere.
function Route.names()
    local names = {}
    for name in pairs(registered) do names[#names + 1] = name end
    table.sort(names)
    return names
end

FredPD.Core.route = Route
