--- Dispatch (CAD) SQL (spec 7.16, 7.17, 7.18; migration 0007). Parameterized
--- only (invariant 8).
---
--- Six rules shape every statement in this file.
---
--- **The queue and the board are read every few seconds by every open console**
--- (3.6), so every read here names the index that serves it and what it costs.
--- The one shape that is never acceptable is a scan of `fpd_calls`: that table
--- grows for the life of the server, and a queue drawn by scanning it gets
--- slower every day nothing is wrong. `queue_priority` is the stored generated
--- column that makes the queue a range read -- the priority while a call is
--- open, NULL once it is closed -- so drawing the queue costs what the *open*
--- calls cost and not what the history costs.
---
--- **The constraints in 0007 are the specification, not an obstacle.** Several
--- of them refuse a write that looks perfectly reasonable: a call whose status
--- is `on_scene` with no `on_scene_at`, a `cleared` call with no disposition, a
--- panic call closed with nobody having acknowledged it. Every one of those is a
--- state somebody would later have to explain in an inquiry, so the answer is
--- always to write the row correctly here -- never to relax the constraint.
---
--- **The database enforces what two dispatchers can race on.**
--- `uq_fpd_call_units_live` is `(call_id, discord_id, active)`, so what it
--- enforces is "a unit is on a *given* call once" -- read it carefully, because
--- it is not "a unit is on one call". `uq_fpd_call_units_lead` means "at most
--- one live lead unit". Both are in the database, so the writes below attempt
--- the insert and let it fail: a check-then-insert in Lua is two statements two
--- dispatchers can interleave, and what it would let through is a call with two
--- units who each think the other is in charge. A refused insert rolls its whole
--- transaction back and the route answers `already_assigned`.
---
--- **A unit is live on one call, and `assignUnits` is the one place that is
--- made true.** No key in 0007 can say it -- a unique key cannot span two calls
--- -- so it is one rule in one function: putting a unit on a call closes
--- whatever else they were live on first, in the same transaction, with the
--- `unit_left` line on the abandoned call that says so and the status reset that
--- goes with it (`Cad.statusAfterCall`). Everything downstream assumes it: the
--- board's `LEFT JOIN` returns one row per unit, `activeAssignment` answers with
--- one call, and the count of units on a call is the count of units who are
--- actually coming. The case that produces a second live assignment without it
--- is not exotic -- it is an officer already on a call pressing panic.
---
--- **A write that must not happen twice is one guarded UPDATE, and its caller
--- reads the affected-row count** -- clearing a call, acknowledging an
--- emergency, taking a broadcast off the air. "Query succeeded" is not "row
--- changed" (11.3), and the guard in the WHERE clause is what makes the second
--- attempt a refusal somebody can read rather than a silent overwrite of who did
--- it first.
---
--- **No position is ever written from input.** `fpd_units.x/y/z` and
--- `fpd_alpr_reads.x/y/z` are written from the ped, server-side (0007's header,
--- invariant 1). Nothing in this file takes a position from a route.
---
--- A note on values lists, inherited from `evidence/repo.lua`: parameters are
--- assigned by index and never appended, because a nil appended into the middle
--- of a list silently fills its slot and shifts every placeholder after it.
--- Where the natural last column is nullable, the statement lists a NOT NULL
--- column last instead, so a values list can never end in a nil.
---
--- A note on return values: a function whose caller has to distinguish "nothing
--- changed" returns a **boolean**, not a row count, wherever the caller writes
--- `if not repo.x(...)`. Zero is truthy in Lua, so a count returned there would
--- read as success. Each one below says which it is.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

local function service()
    return FredPD.Modules.cad
end

-- -----------------------------------------------------------------------------
-- Columns
-- -----------------------------------------------------------------------------

--- Every column a call card, the queue and the map need, and no more.
---
--- `agencyId` is aliased because `Access.control` reads it: a call carries a
--- classification, so a read of one goes through the same check a record read
--- does (invariant 4).
---
--- `receivedAtUnix` sits beside the formatted timestamp because the pure logic
--- compares ages as numbers (`Cad.aheadInQueue`). `UNIX_TIMESTAMP` converts from
--- the session time zone to real epoch seconds, so it agrees with `os.time()`
--- whatever time zone the database is running in.
local CALL_COLUMNS <const> = [[
    c.id, c.agency_id AS agencyId, c.call_number AS callNumber, c.type, c.priority,
    c.status, c.x, c.y, c.z, c.location_text AS locationText, c.beat_id AS beatId,
    c.caller_name AS callerName, c.caller_phone AS callerPhone,
    c.source, c.source_resource AS sourceResource, c.classification, c.version,
    c.received_at AS receivedAt, UNIX_TIMESTAMP(c.received_at) AS receivedAtUnix,
    c.dispatched_at AS dispatchedAt, c.en_route_at AS enRouteAt,
    c.on_scene_at AS onSceneAt, c.cleared_at AS clearedAt,
    c.disposition, c.cleared_by AS clearedBy,
    c.acknowledged_by AS acknowledgedBy, c.acknowledged_at AS acknowledgedAt,
    c.created_by AS createdBy, c.created_at AS createdAt
]]

--- The board's columns.
---
--- `statusSinceUnix` and `positionAtUnix` come back beside the formatted
--- timestamps because the welfare timer and the recommendation compare them as
--- numbers, and `Cad.needsWelfareCheck` takes a clock rather than an age.
local UNIT_COLUMNS <const> = [[
    u.officer_id AS officerId, u.agency_id AS agencyId, u.discord_id AS discordId,
    u.callsign, u.status, u.status_since AS statusSince,
    UNIX_TIMESTAMP(u.status_since) AS statusSinceUnix,
    u.beat_id AS beatId, u.division,
    u.vehicle_plate AS vehiclePlate, u.vehicle_model AS vehicleModel,
    u.x, u.y, u.z, u.heading, u.position_at AS positionAt,
    UNIX_TIMESTAMP(u.position_at) AS positionAtUnix, u.signed_on_at AS signedOnAt
]]

--- What a unit is on right now, joined onto the board.
---
--- A join rather than a column on `fpd_units`, which is the whole reason 0007
--- keeps no `current_call_id`: a copy has a window in which it disagrees with
--- `fpd_call_units`, and what a dispatcher sees through that window is a unit
--- shown as free while the call it is on is still open. `idx_fpd_call_units_unit
--- (agency_id, discord_id, active)` makes it a key seek per unit.
---
--- `onCallPriority` is here for the recommendation: a unit already on a P1 is
--- not available, and one on a P4 two streets from a shooting is exactly who to
--- send (`Cad.recommendUnits`).
local UNIT_ASSIGNMENT_JOIN <const> = [[
    LEFT JOIN fpd_call_units cu
           ON cu.agency_id = u.agency_id AND cu.discord_id = u.discord_id AND cu.active = 1
    LEFT JOIN fpd_calls c ON c.id = cu.call_id AND c.agency_id = cu.agency_id
]]

local UNIT_ASSIGNMENT_COLUMNS <const> = [[
    cu.call_id AS onCallId, cu.is_lead AS onCallLead,
    c.call_number AS onCallNumber, c.priority AS onCallPriority, c.status AS onCallStatus
]]

-- -----------------------------------------------------------------------------
-- The narrative log (7.16.1)
-- -----------------------------------------------------------------------------

--- Appending a line to a call's log.
---
--- `entry_type` is listed last because every other column here is nullable and a
--- values list must never end in a nil (see the header). A line has two halves
--- and only ever one of them: `body` for what a person typed, `message_key` plus
--- `message_args` for what the system wrote. `ck_fpd_call_log_content` refuses
--- any other combination, which is invariant 6 enforced by the schema rather
--- than by discipline -- the i18n checker cannot see a sentence that reaches the
--- database.
local LOG_INSERT <const> = [[INSERT INTO fpd_call_log
        (agency_id, call_id, body, message_key, message_args,
         officer_id, discord_id, callsign, entry_type)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]]

--- The same insert against the call the current transaction has just created.
---
--- `@fpd_call` is set from `LAST_INSERT_ID()` immediately after the call's own
--- INSERT and before any other insert can move it: `LAST_INSERT_ID()` is the id
--- of the *previous* insert on the connection, so a log line written after a
--- second insert would be filed against that one instead. A user variable is per
--- connection and a transaction is one connection, so it holds for exactly as
--- long as it is needed.
local LOG_INSERT_NEW <const> = [[INSERT INTO fpd_call_log
        (agency_id, call_id, body, message_key, message_args,
         officer_id, discord_id, callsign, entry_type)
     VALUES (?, @fpd_call, ?, ?, ?, ?, ?, ?, ?)]]

--- The same insert, written only if the statement it belongs to changed a row.
---
--- `fpd_call_log` is append-only, so a line written by a transaction that then
--- turned out to have changed nothing is a line nobody can take back: a second
--- "cleared" on a call somebody else cleared, or a "unit left" naming a unit
--- that was not on the call. An `INSERT … SELECT` is how a log line gets a
--- WHERE clause of its own.
---
--- `@fpd_changed` is captured from `ROW_COUNT()` in the statement immediately
--- after the guarded UPDATE, the same per-connection trick `createCall` uses for
--- `@fpd_call` and for the same reason -- a transaction is one connection, and
--- `ROW_COUNT()` reports the statement before it, so the capture has to be the
--- very next statement and the guard reads it afterwards.
---
--- The call supplies `agency_id` and `call_id` rather than a parameter: the row
--- has to exist for the line to be filed against it anyway, and a line can then
--- never be filed against an agency the call is not in.
local LOG_INSERT_CHANGED <const> = [[INSERT INTO fpd_call_log
        (agency_id, call_id, body, message_key, message_args,
         officer_id, discord_id, callsign, entry_type)
     SELECT c.agency_id, c.id, ?, ?, ?, ?, ?, ?, ?
       FROM fpd_calls c
      WHERE c.agency_id = ? AND c.id = ? AND @fpd_changed > 0]]

--- Captures the affected-row count of the statement before it.
---
--- A fresh table each time rather than one shared constant, because the caller
--- puts it in a list the db layer walks and a shared table in several lists is
--- one edit away from being a shared bug.
local function captureChanged()
    return { query = 'SET @fpd_changed = ROW_COUNT()', values = {} }
end

--- One guarded log statement, in the order `LOG_INSERT_CHANGED` reads.
---
--- The trailing three parameters are `entry_type`, `agency_id` and `id`, all
--- NOT NULL, so this values list cannot end in a nil (see the header).
local function changedLogStatement(agencyId, callId, entry)
    local values = {}

    values[1] = entry.body
    values[2] = entry.messageKey
    values[3] = entry.args and json.encode(entry.args) or nil
    values[4] = entry.officerId
    values[5] = entry.discordId
    values[6] = entry.callsign
    values[7] = entry.entryType
    values[8] = agencyId
    values[9] = callId

    return { query = LOG_INSERT_CHANGED, values = values }
end

local LOG_COLUMNS <const> = [[
    l.id, l.call_id AS callId, l.entry_type AS entryType, l.body,
    l.message_key AS messageKey, l.message_args AS messageArgs,
    l.officer_id AS officerId, l.discord_id AS discordId, l.callsign,
    l.created_at AS createdAt, UNIX_TIMESTAMP(l.created_at) AS createdAtUnix
]]

--- The values both log statements expect, in order.
---
--- @param entry table { entryType, messageKey, args, body, officerId,
---   discordId, callsign }
--- @param withCall boolean true for the statement that names the call itself
local function logValues(agencyId, callId, entry, withCall)
    local values = {}
    local slot = 1

    values[slot] = agencyId
    slot = slot + 1

    if withCall then
        values[slot] = callId
        slot = slot + 1
    end

    values[slot] = entry.body
    values[slot + 1] = entry.messageKey
    values[slot + 2] = entry.args and json.encode(entry.args) or nil
    values[slot + 3] = entry.officerId
    values[slot + 4] = entry.discordId
    values[slot + 5] = entry.callsign
    values[slot + 6] = entry.entryType

    return values
end

--- One statement appending a line to an existing call's log.
local function logStatement(agencyId, callId, entry)
    return { query = LOG_INSERT, values = logValues(agencyId, callId, entry, true) }
end

--- Appends a line to the narrative log (7.16.1).
---
--- Append-only: nothing in this file updates or deletes a row in
--- `fpd_call_log`. It is the record of what was known and when, which is the
--- half of a call that is read back in an inquiry, and a narrative that can be
--- edited afterwards is worth nothing in one.
---
--- Cost: one insert. `idx_fpd_call_log_call` is maintained on write and is what
--- makes the card's read a range scan rather than a sort.
---
--- @return number rows written
function Repo.addLog(agencyId, callId, entry)
    return db().execute(LOG_INSERT, logValues(agencyId, callId, entry, true))
end

-- -----------------------------------------------------------------------------
-- Calls (7.16)
-- -----------------------------------------------------------------------------

--- The INSERT that raises a call, with its number allocated inline.
---
--- The number comes from `fpd_counters` under a row lock, inside the same
--- transaction (13.1, ADR-012), and the counter row is scoped to the *day*,
--- because a call number restarts daily (Appendix D). `Cad.dayKey` and
--- `Cad.callNumberPrefix` own the scope key and the format, so there is one
--- definition of each and busted reads it.
local CALL_INSERT <const> = [[INSERT INTO fpd_calls
        (call_number, agency_id, priority, x, y, z, location_text, beat_id,
         caller_name, caller_phone, source_resource, classification, created_by,
         source, type)
     VALUES (%s, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]]

--- Raises a call, with its opening narrative line (7.16 intake, Appendix D).
---
--- The `created` line goes in the same transaction as the call. A call with no
--- opening line is a call that appears to have been raised by nobody, and the
--- two writes must not be separable by a crash.
---
--- `details` is what the caller said. It is content, so it goes in the line's
--- `body` beside that line's own `message_key` -- `ck_fpd_call_log_content`
--- requires the key on every entry that is not a note and says nothing about the
--- body, which is exactly this row.
---
--- Reading the id back afterwards is the shape `createScene` uses
--- (`evidence/repo.lua`), for the same reason: a transaction reports only
--- whether it committed. It is scoped as tightly as the row allows -- one
--- Discord account holds one session, so a call raised by an officer cannot have
--- been interleaved with another of their own. A call raised by the `CreateCall`
--- export (11.2) has no author at all, so that path is scoped by the resource,
--- the type and the location instead. What is left is two identical calls from
--- one resource in the same tick, which is a duplicate call rather than a
--- mix-up.
---
--- **A column that is NULL is matched by `IS NULL` and binds no parameter.**
--- Three of the columns this reads back are nullable, and `created_by` is NULL
--- on the export path by definition. Writing them as `<=> ?` and binding nil
--- would be a values list with a hole in it and a nil at the end -- the one
--- shape the header forbids, because `#` on a table with a hole is undefined in
--- Lua and a trailing nil shortens it, and what oxmysql then receives is a list
--- with the wrong number of parameters in it for the placeholders in the query.
--- So each predicate is chosen from the value: present means `= ?` and one more
--- parameter, absent means `IS NULL` and none. The two forms select exactly the
--- same rows `<=>` would, and the list is dense and starts with the two columns
--- that are NOT NULL.
---
--- @param input table { type, priority, locationText, x, y, z, beatId,
---   callerName, callerPhone, source, sourceResource, classification, details }
--- @param actor table|nil { discordId, officerId, callsign }; nil for an export
--- @return table|nil { id, callNumber }
function Repo.createCall(agencyId, input, actor)
    local counters = FredPD.Core.counters
    local cad = service()
    local author = actor or {}
    local external = input.source == 'export'
    local dayKey = cad.dayKey()
    local prefix, width = cad.callNumberPrefix(dayKey)

    local values = counters.numberValues(prefix, width, 'call', agencyId, dayKey)
    local base = #values

    values[base + 1] = agencyId
    values[base + 2] = input.priority
    values[base + 3] = input.x
    values[base + 4] = input.y
    values[base + 5] = input.z
    values[base + 6] = input.locationText
    values[base + 7] = input.beatId
    values[base + 8] = input.callerName
    values[base + 9] = input.callerPhone
    values[base + 10] = input.sourceResource
    values[base + 11] = input.classification or 'internal'
    values[base + 12] = author.discordId
    values[base + 13] = input.source or 'dispatcher'
    values[base + 14] = input.type

    local created = {
        entryType = 'created',
        messageKey = cad.logMessageKey('created', { external = external }),
        args = external and { resource = input.sourceResource } or nil,
        body = input.details,
        officerId = author.officerId,
        discordId = author.discordId,
        callsign = author.callsign,
    }

    local committed = db().transaction(counters.transaction('call', agencyId, dayKey, {
        { query = CALL_INSERT:format(counters.numberSql()), values = values },
        -- Captured before anything else can insert, so the log line below lands
        -- on this call rather than on whatever was written next.
        { query = 'SET @fpd_call = LAST_INSERT_ID()', values = {} },
        { query = LOG_INSERT_NEW, values = logValues(agencyId, nil, created, false) },
    }))

    if not committed then return nil end

    local where = { 'agency_id = ?', 'type = ?' }
    local scope = { agencyId, input.type }

    -- The column names are constants in this file and never come from input
    -- (invariant 8): what the value decides is which of two fixed predicates is
    -- used, not any part of the SQL text.
    local function match(column, value)
        if value == nil then
            where[#where + 1] = column .. ' IS NULL'
        else
            where[#where + 1] = column .. ' = ?'
            scope[#scope + 1] = value
        end
    end

    match('created_by', author.discordId)

    if not author.discordId then
        match('source_resource', input.sourceResource)
        match('location_text', input.locationText)
    end

    return db().single(
        ('SELECT id, call_number AS callNumber FROM fpd_calls WHERE %s ORDER BY id DESC LIMIT 1')
            :format(table.concat(where, ' AND ')),
        scope
    )
end

--- One call.
---
--- Cost: a primary-key lookup with the agency checked on the row, so a call id
--- from another agency answers nothing rather than answering somebody else's
--- call. FredPD is multi-agency and a read that forgets the agency does not
--- return an empty list -- it returns the sheriff's calls to a city dispatcher,
--- quietly (0007).
function Repo.getCall(agencyId, id)
    return db().single(
        ([[SELECT %s FROM fpd_calls c WHERE c.agency_id = ? AND c.id = ?]]):format(CALL_COLUMNS),
        { agencyId, id }
    )
end

--- The pending queue, and every other list of calls (7.16).
---
--- Two shapes, and the difference is which index answers:
---
---   * **The queue** (no `status` filter). `queue_priority IS NOT NULL` reads
---     `idx_fpd_calls_queue (agency_id, queue_priority, received_at)` forward
---     from the first open call and stops when the page is full. No sort, and
---     the cost does not grow with the number of calls the server has ever
---     taken, because every closed call collapses into one NULL region at the
---     front of the index that a single seek skips. This is the read every
---     console makes every few seconds (12.1), and it is why `queue_priority`
---     exists at all.
---   * **A closed-call list** (a `status` filter). `idx_fpd_calls_status
---     (agency_id, status, received_at)` -- one status is one range, newest
---     first, which is the day's history rather than the queue.
---
--- `mineDiscordId` is answered by an EXISTS over `idx_fpd_call_units_unit
--- (agency_id, discord_id, active)`: a key seek, and the session's own id, never
--- an officer named in input (invariant 1).
---
--- `unitCount` is a correlated subquery over `idx_fpd_call_units_call` -- one
--- seek per row *returned*, bounded by the limit and not by the table.
---
--- @param filter table { status, priority, beatId, mineDiscordId, limit }
function Repo.listCalls(agencyId, filter)
    local where = { 'c.agency_id = ?' }
    local values = { agencyId }
    local order

    if filter.status then
        where[#where + 1] = 'c.status = ?'
        values[#values + 1] = filter.status
        order = 'c.received_at DESC'
    else
        where[#where + 1] = 'c.queue_priority IS NOT NULL'
        order = 'c.queue_priority, c.received_at'
    end

    if filter.priority then
        where[#where + 1] = 'c.priority = ?'
        values[#values + 1] = filter.priority
    end

    if filter.beatId then
        where[#where + 1] = 'c.beat_id = ?'
        values[#values + 1] = filter.beatId
    end

    if filter.mineDiscordId then
        where[#where + 1] = [[EXISTS (SELECT 1 FROM fpd_call_units mu
                                       WHERE mu.call_id = c.id AND mu.agency_id = c.agency_id
                                         AND mu.discord_id = ? AND mu.active = 1)]]
        values[#values + 1] = filter.mineDiscordId
    end

    values[#values + 1] = filter.limit or 100

    return db().query(
        ([[SELECT %s,
                  (SELECT COUNT(*) FROM fpd_call_units cu
                    WHERE cu.call_id = c.id AND cu.active = 1) AS unitCount
             FROM fpd_calls c
            WHERE %s
            ORDER BY %s
            LIMIT ?]]):format(CALL_COLUMNS, table.concat(where, ' AND '), order),
        values
    )
end

--- Who is on a call, in join order, including the assignments that have ended.
---
--- `active` says which: 1 while the unit is on the call, NULL once `left_at` is
--- stamped. Closed rows come back because "who was sent" is one of the three
--- questions a call is read back to answer, and a unit that was pulled off to
--- something more urgent is part of that answer.
---
--- Cost: a range read of `idx_fpd_call_units_call (call_id, agency_id,
--- joined_at)`, a handful of rows.
function Repo.callUnits(agencyId, callId)
    return db().query(
        [[SELECT cu.id, cu.officer_id AS officerId, cu.discord_id AS discordId,
                 cu.callsign, cu.is_lead AS isLead, cu.assigned_by AS assignedBy,
                 cu.joined_at AS joinedAt, cu.left_at AS leftAt, cu.active
            FROM fpd_call_units cu
           WHERE cu.call_id = ? AND cu.agency_id = ?
           ORDER BY cu.joined_at, cu.id]],
        { callId, agencyId }
    )
end

--- The narrative log of a call (7.16.1).
---
--- Keyset pagination on `id` (12.2) rather than an offset: a long call has
--- hundreds of lines and `OFFSET` re-walks all of them on every page.
---
--- `message_args` is decoded here, beside the polygon in `listBeats` and for the
--- same reason: it is a JSON column, it comes back as text, and a caller that
--- forgot to decode it renders `{"callsign":"3A-12"}` at a dispatcher. Decoding
--- is not logic, so it belongs in the repo -- the service stays loadable without
--- `json`, which is what keeps it testable.
---
--- Cost: a range read of `idx_fpd_call_log_call (call_id, agency_id, id)`.
---
--- @param afterId number|nil the last id the caller already has
function Repo.callLog(agencyId, callId, limit, afterId)
    local where = { 'l.call_id = ?', 'l.agency_id = ?' }
    local values = { callId, agencyId }

    if afterId then
        where[#where + 1] = 'l.id > ?'
        values[#values + 1] = afterId
    end

    values[#values + 1] = limit or 200

    local rows = db().query(
        ([[SELECT %s FROM fpd_call_log l
            WHERE %s
            ORDER BY l.id
            LIMIT ?]]):format(LOG_COLUMNS, table.concat(where, ' AND ')),
        values
    )

    for index = 1, #rows do
        if type(rows[index].messageArgs) == 'string' then
            rows[index].messageArgs = json.decode(rows[index].messageArgs)
        end
    end

    return rows
end

--- Persons and vehicles linked to a call (7.16).
---
--- Cost: a range read of `idx_fpd_call_links_call`.
function Repo.callLinks(agencyId, callId)
    return db().query(
        [[SELECT k.id, k.target_type AS targetType, k.target_id AS targetId,
                 k.role, k.label, k.detail, k.created_by AS createdBy, k.created_at AS createdAt
            FROM fpd_call_links k
           WHERE k.call_id = ? AND k.agency_id = ?
           ORDER BY k.created_at, k.id]],
        { callId, agencyId }
    )
end

--- What a link would point at: the label to record, and the access control the
--- caller must check before writing it.
---
--- `fpd_call_links` has no foreign key to the register -- 0007 explains why a
--- polymorphic link cannot have one -- so the database cannot check that a link
--- points at this agency's record. This read is that check, and the
--- `classification` it returns is what the caller runs the register's own access
--- check against: linking a person to a call is a read of that person, and a
--- link is one of the few places a client supplies a record id at all
--- (invariant 4).
---
--- Cost: one primary-key lookup with the agency on the row.
---
--- @param kind string `person` or `vehicle`
--- @return table|nil { id, agencyId, classification, label }
function Repo.linkTarget(agencyId, kind, targetId)
    if kind == 'person' then
        return db().single(
            [[SELECT p.id, p.agency_id AS agencyId, p.classification,
                     TRIM(CONCAT(COALESCE(p.first_name, ''), ' ', COALESCE(p.last_name, ''))) AS label
                FROM fpd_persons p WHERE p.agency_id = ? AND p.id = ?]],
            { agencyId, targetId }
        )
    end

    if kind == 'vehicle' then
        return db().single(
            [[SELECT v.id, v.agency_id AS agencyId, v.classification, v.plate AS label
                FROM fpd_vehicles v WHERE v.agency_id = ? AND v.id = ?]],
            { agencyId, targetId }
        )
    end

    return nil
end

--- Links a person or a vehicle to a call, or changes the role of a link.
---
--- `ON DUPLICATE KEY UPDATE` on `uq_fpd_call_links_target`: linking the same
--- record twice changes the role rather than stacking a second row nobody would
--- think to remove. The log line goes in the same transaction, so a link that
--- exists always has a line saying who made it.
---
--- @param link table { targetType, targetId, role, label, detail }
--- @param actor table { discordId, officerId, callsign }
--- @return boolean committed
function Repo.setLink(agencyId, callId, link, actor)
    local values = {}

    values[1] = agencyId
    values[2] = callId
    values[3] = link.targetType
    values[4] = link.targetId
    values[5] = link.label
    values[6] = link.detail
    values[7] = actor.discordId
    values[8] = link.role or 'involved'

    return db().transaction({
        {
            -- `role` last: it is NOT NULL, so the values list cannot end in a
            -- nil (see the header).
            query = [[INSERT INTO fpd_call_links
                          (agency_id, call_id, target_type, target_id, label, detail,
                           created_by, role)
                      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                      ON DUPLICATE KEY UPDATE
                          role = VALUES(role), label = VALUES(label), detail = VALUES(detail)]],
            values = values,
        },
        logStatement(agencyId, callId, {
            entryType = 'linked',
            messageKey = service().logMessageKey('linked'),
            -- The role travels as the enum member, never as a rendered label:
            -- the NUI resolves it through `cad.linkRole.<role>` in the reader's
            -- language (7.16.1). A label written here would put the writer's
            -- language inside a Swedish officer's log line.
            args = { label = link.label, role = link.role or 'involved' },
            officerId = actor.officerId,
            discordId = actor.discordId,
            callsign = actor.callsign,
        }),
    })
end

--- Removes a link, and says so in the log.
---
--- The row is deleted rather than stamped: unlike an assignment or a broadcast,
--- a link asserts nothing about what happened -- it is an index entry -- and the
--- log line is the record that it was made and taken away.
---
--- @param link table { targetType, targetId, label }
--- @return boolean committed
function Repo.removeLink(agencyId, callId, link, actor)
    return db().transaction({
        {
            query = [[DELETE FROM fpd_call_links
                       WHERE agency_id = ? AND call_id = ? AND target_type = ? AND target_id = ?]],
            values = { agencyId, callId, link.targetType, link.targetId },
        },
        logStatement(agencyId, callId, {
            entryType = 'unlinked',
            messageKey = service().logMessageKey('unlinked'),
            args = { label = link.label },
            officerId = actor.officerId,
            discordId = actor.discordId,
            callsign = actor.callsign,
        }),
    })
end

-- -----------------------------------------------------------------------------
-- Assignment (7.16)
-- -----------------------------------------------------------------------------

--- Stamping the call as the first unit is assigned to it.
---
--- `dispatched_at` is stamped once and never moved (0007's header): a
--- response-time report is arithmetic over those five columns, and a column that
--- moves when a second unit is added is a report that gives a different answer
--- each time it is read. `COALESCE` is what makes it once.
---
--- The status moves only out of `pending`, so a call that is already `on_scene`
--- does not go back to `dispatched` because dispatch sent a second car.
--- `ck_fpd_calls_dispatched` then holds by construction: the stamp and the
--- status are set in one statement, and a CHECK is evaluated on the finished
--- row.
local DISPATCH_STAMP <const> = [[UPDATE fpd_calls
       SET dispatched_at = COALESCE(dispatched_at, CURRENT_TIMESTAMP(3)),
           status = CASE WHEN status = 'pending' THEN 'dispatched' ELSE status END,
           updated_by = ?, version = version + 1
     WHERE agency_id = ? AND id = ? AND status NOT IN ('cleared', 'cancelled')]]

--- Closing whatever else a unit was live on, so that they are on one call.
---
--- Three statements, and the order is the whole of the correctness: the log line
--- and the status reset both read the live row, and the third closes it.
---
---   * the `unit_left` line on the *abandoned* call, written by an
---     `INSERT … SELECT` over `idx_fpd_call_units_unit` so that a unit who was
---     on nothing produces no line at all;
---   * the status, back to what `Cad.statusAfterCall` says a diverted unit
---     holds -- they are not on scene at the call they have just been taken off,
---     and leaving `on_scene` there would keep the welfare timer counting from
---     a scene they are driving away from;
---   * the assignment itself, `left_at` stamped and the lead flag dropped,
---     exactly as `releaseUnits` closes one.
---
--- `call_id <> ?` is what makes all three a no-op for the ordinary case of a
--- unit joining their first call, and what stops a re-dispatch to the call they
--- are already on from closing the assignment it is about to refuse.
local function divertStatements(agencyId, callId, unit, actor)
    local cad = service()
    local statuses, freed = cad.statusesClearedByCall(cad.CALL_DIVERTED)
    local left = {}
    local status = {}
    local holders = {}

    left[1] = cad.logMessageKey('unit_left')
    left[2] = json.encode({ callsign = unit.callsign })
    left[3] = actor.officerId
    left[4] = actor.discordId
    left[5] = actor.callsign
    left[6] = 'unit_left'
    left[7] = agencyId
    left[8] = unit.discordId
    left[9] = callId

    status[1] = freed
    status[2] = agencyId
    status[3] = unit.discordId

    for index = 1, #statuses do
        holders[index] = '?'
        status[3 + index] = statuses[index]
    end

    status[4 + #statuses] = agencyId
    status[5 + #statuses] = unit.discordId
    status[6 + #statuses] = callId

    return {
        {
            -- `body` is the literal NULL of a generated line rather than a bound
            -- nil, so nothing in this values list is absent (see the header).
            query = [[INSERT INTO fpd_call_log
                          (agency_id, call_id, body, message_key, message_args,
                           officer_id, discord_id, callsign, entry_type)
                       SELECT cu.agency_id, cu.call_id, NULL, ?, ?, ?, ?, ?, ?
                         FROM fpd_call_units cu
                        WHERE cu.agency_id = ? AND cu.discord_id = ?
                          AND cu.active = 1 AND cu.call_id <> ?]],
            values = left,
        },
        {
            -- Only a unit that was genuinely on another call: the EXISTS is why
            -- a unit sitting at `on_scene` with no assignment at all keeps the
            -- status they chose rather than having it overwritten by a dispatch.
            query = ([[UPDATE fpd_units
                          SET status = ?, status_since = CURRENT_TIMESTAMP(3)
                        WHERE agency_id = ? AND discord_id = ? AND status IN (%s)
                          AND EXISTS (SELECT 1 FROM fpd_call_units cu
                                       WHERE cu.agency_id = ? AND cu.discord_id = ?
                                         AND cu.active = 1 AND cu.call_id <> ?)]])
                :format(table.concat(holders, ', ')),
            values = status,
        },
        {
            query = [[UPDATE fpd_call_units
                         SET left_at = CURRENT_TIMESTAMP(3), is_lead = 0
                       WHERE agency_id = ? AND discord_id = ?
                         AND active = 1 AND call_id <> ?]],
            values = { agencyId, unit.discordId, callId },
        },
    }
end

--- Puts units on a call (7.16: assign, self-assign, add units).
---
--- One transaction for the whole dispatch: every unit row, the call's stamp and
--- a log line each. A dispatch that half happened -- two of three units on the
--- call, no `dispatched_at`, a log naming units that are not on it -- is a call
--- card that disagrees with itself in front of somebody reading it over a radio.
---
--- **A unit already on the call makes the insert fail, and that is deliberate.**
--- `uq_fpd_call_units_live (call_id, discord_id, active)` is the check, and it
--- lives in the database because two dispatchers pressing Dispatch in the same
--- moment is exactly what a `SELECT` followed by an `INSERT` gets wrong. The
--- transaction rolls back whole and the caller answers `already_assigned`.
---
--- **A unit already on a *different* call is taken off it here** (see
--- `divertStatements` and the header). That key cannot span two calls, so this
--- is the one place the rule lives -- and it is not a rare path: an officer who
--- is already working a call and presses panic is assigned to their own P1 by
--- `unit.emergency`, and without this they would sit on both. What that costs is
--- specific: two board rows for one officer, two "closest available" slots
--- filled by one callsign, a status line landing on whichever of the two calls a
--- `LIMIT 1` happened to return, and a call still counting a unit who is never
--- coming, which is a call no dispatcher re-dispatches.
---
--- `discord_id` and `callsign` are recorded as they are now, so the row stays
--- readable after the officer leaves the roster and `officer_id` is nulled.
---
--- @param units table list of { officerId, discordId, callsign }
--- @param options table { assignedBy, selfAssigned, actor }
--- @return boolean committed
function Repo.assignUnits(agencyId, callId, units, options)
    local actor = options.actor or {}
    -- 7.16.1 gives a unit that took a call and a unit that was sent to one
    -- different message keys, on the same `unit_joined` row: the log is read
    -- back to tell those two facts apart.
    local messageKey = service().logMessageKey('unit_joined', {
        selfAssigned = options.selfAssigned == true,
    })

    local statements = {
        { query = DISPATCH_STAMP, values = { actor.discordId, agencyId, callId } },
    }

    for index = 1, #units do
        local unit = units[index]
        local values = {}

        values[1] = agencyId
        values[2] = callId
        values[3] = unit.officerId
        values[4] = unit.callsign
        values[5] = options.assignedBy
        values[6] = unit.discordId

        -- Off everything else first, in this same transaction: the insert below
        -- would otherwise be the second live assignment for this unit, which
        -- `uq_fpd_call_units_live` permits and nothing downstream expects.
        local divert = divertStatements(agencyId, callId, unit, actor)

        for step = 1, #divert do statements[#statements + 1] = divert[step] end

        statements[#statements + 1] = {
            -- `discord_id` last: it is NOT NULL where `callsign` and
            -- `assigned_by` are not (see the header).
            query = [[INSERT INTO fpd_call_units
                          (agency_id, call_id, officer_id, callsign, assigned_by, discord_id)
                      VALUES (?, ?, ?, ?, ?, ?)]],
            values = values,
        }

        statements[#statements + 1] = logStatement(agencyId, callId, {
            entryType = 'unit_joined',
            messageKey = messageKey,
            args = { callsign = unit.callsign },
            officerId = actor.officerId,
            discordId = actor.discordId,
            callsign = actor.callsign,
        })
    end

    return db().transaction(statements)
end

--- Takes units off a call (7.16).
---
--- `left_at` closes the assignment; nothing is deleted, because the assignment
--- is half the answer to "who was sent", and a unit pulled off to something more
--- urgent is part of that answer. Closing the row also drops it out of
--- `uq_fpd_call_units_live`, so the same unit can be assigned again later.
---
--- `is_lead = 0` goes with it: a lead unit that has left the call is a call
--- where nobody is in charge and the card still says somebody is.
---
--- **And the unit's status comes back with it.** A unit a dispatcher takes off
--- a call is in exactly the position of a unit whose call was cleared, and
--- `Cad.statusAfterCall` is the one rule both of them go through: the statuses
--- the call itself put them in go back to `available`, and a unit that has
--- moved on under its own steam -- `transporting` a prisoner from this call,
--- say -- keeps what they chose. Without it a released unit reads `on_scene`
--- for the rest of the shift, at a scene it is not at, with the welfare timer
--- counting up from the moment it arrived there.
---
--- Both the status and the line are guarded on the release having actually
--- closed a row (`@fpd_changed`, see `LOG_INSERT_CHANGED`). Releasing a unit
--- that was not on the call must not write "unit left" about a unit that was
--- never there, into a log nothing can edit afterwards, nor free a unit that is
--- on scene at somebody else's call.
---
--- @param units table list of { discordId, callsign }
--- @return boolean committed
function Repo.releaseUnits(agencyId, callId, units, actor)
    local statements = {}
    local cad = service()
    local statuses, freed = cad.statusesClearedByCall(cad.CALL_ENDED)
    local holders = {}

    for index = 1, #statuses do holders[index] = '?' end

    local freeReleased <const> = ([[UPDATE fpd_units
                 SET status = ?, status_since = CURRENT_TIMESTAMP(3)
               WHERE agency_id = ? AND discord_id = ? AND status IN (%s)
                 AND @fpd_changed > 0]]):format(table.concat(holders, ', '))

    for index = 1, #units do
        local unit = units[index]
        local status = {}

        status[1] = freed
        status[2] = agencyId
        status[3] = unit.discordId

        for step = 1, #statuses do status[3 + step] = statuses[step] end

        statements[#statements + 1] = {
            query = [[UPDATE fpd_call_units
                         SET left_at = CURRENT_TIMESTAMP(3), is_lead = 0
                       WHERE agency_id = ? AND call_id = ? AND discord_id = ? AND left_at IS NULL]],
            values = { agencyId, callId, unit.discordId },
        }

        statements[#statements + 1] = captureChanged()
        statements[#statements + 1] = { query = freeReleased, values = status }

        statements[#statements + 1] = changedLogStatement(agencyId, callId, {
            entryType = 'unit_left',
            messageKey = cad.logMessageKey('unit_left'),
            args = { callsign = unit.callsign },
            officerId = actor.officerId,
            discordId = actor.discordId,
            callsign = actor.callsign,
        })
    end

    if #statements == 0 then return true end

    return db().transaction(statements)
end

--- Transfers the lead unit (7.16).
---
--- Cleared first, then set, in one transaction: `uq_fpd_call_units_lead` allows
--- at most one live lead per call, so setting before clearing would be refused
--- by the database rather than merely be wrong. The order is the whole of the
--- correctness here, which is why this is one function and not two calls from a
--- route.
---
--- @param unit table { discordId, callsign }
--- @return boolean committed
function Repo.setLead(agencyId, callId, unit, actor)
    return db().transaction({
        {
            query = [[UPDATE fpd_call_units SET is_lead = 0
                       WHERE agency_id = ? AND call_id = ? AND left_at IS NULL AND is_lead = 1]],
            values = { agencyId, callId },
        },
        {
            query = [[UPDATE fpd_call_units SET is_lead = 1
                       WHERE agency_id = ? AND call_id = ? AND left_at IS NULL AND discord_id = ?]],
            values = { agencyId, callId, unit.discordId },
        },
        logStatement(agencyId, callId, {
            entryType = 'lead_changed',
            messageKey = service().logMessageKey('lead_changed'),
            args = { callsign = unit.callsign },
            officerId = actor.officerId,
            discordId = actor.discordId,
            callsign = actor.callsign,
        }),
    })
end

--- Is this unit live on this call?
---
--- The check every write makes before it acts, and the one a schema cannot make:
--- `uq_fpd_call_units_lead` guarantees there is never more than one live lead,
--- not that the unit being made lead is on the call at all.
---
--- Keyed on the Discord id, which is the identity `fpd_call_units` records and
--- what its live-assignment unique key is on -- `officer_id` beside it is nulled
--- when a roster row goes, so it cannot be the key that decides who is on a
--- call.
---
--- Cost: one seek on `idx_fpd_call_units_call`.
---
--- @return boolean
function Repo.isAssigned(agencyId, callId, discordId)
    local found = db().scalar(
        [[SELECT 1 FROM fpd_call_units
           WHERE agency_id = ? AND call_id = ? AND discord_id = ? AND active = 1]],
        { agencyId, callId, discordId }
    )

    return found ~= nil
end

--- The call this unit is live on, if any.
---
--- 0007 keeps no `current_call_id` on `fpd_units` -- it would be a copy of this
--- row with a window in which the two disagree -- so this seek is the answer
--- instead. `idx_fpd_call_units_unit (agency_id, discord_id, active)` makes it a
--- key lookup.
---
--- **There is one live row, and the ORDER BY is what happens if there is not.**
--- `assignUnits` closes a unit's other assignments, so the `LIMIT 1` normally
--- has nothing to choose between. A row written before that rule was enforced,
--- or one left by a transaction that failed halfway, would otherwise make this
--- answer whichever row the storage engine reached first -- and the caller is
--- `logUnitStatus`, so what "whichever" means in practice is an officer's
--- status line filed against an arbitrary one of two calls. Newest first, which
--- is the call they are actually on.
function Repo.activeAssignment(agencyId, discordId)
    return db().single(
        [[SELECT cu.call_id AS callId, cu.is_lead AS isLead, cu.joined_at AS joinedAt,
                 c.call_number AS callNumber, c.priority, c.status
            FROM fpd_call_units cu
            JOIN fpd_calls c ON c.id = cu.call_id AND c.agency_id = cu.agency_id
           WHERE cu.agency_id = ? AND cu.discord_id = ? AND cu.active = 1
           ORDER BY cu.joined_at DESC, cu.id DESC
           LIMIT 1]],
        { agencyId, discordId }
    )
end

-- -----------------------------------------------------------------------------
-- Call status (7.16, Appendix E)
-- -----------------------------------------------------------------------------

--- One statement per rung of the call's status ladder.
---
--- Each stamps its own timestamp with `COALESCE` -- once, never moved -- and
--- moves the status only from below, so a second unit reporting en route to a
--- call that is already on scene stamps nothing and moves nothing. The CHECK for
--- each status (`ck_fpd_calls_en_route`, `ck_fpd_calls_on_scene`) holds by
--- construction, because the stamp and the status are written in one statement.
---
--- An allowlist of whole statements rather than a column name pasted into one
--- query: nothing is built from input, and each rung can be read on its own.
local ADVANCE <const> = {
    en_route = [[UPDATE fpd_calls
       SET en_route_at = COALESCE(en_route_at, CURRENT_TIMESTAMP(3)),
           status = CASE WHEN status IN ('pending', 'dispatched') THEN 'en_route' ELSE status END,
           updated_by = ?, version = version + 1
     WHERE agency_id = ? AND id = ? AND status NOT IN ('cleared', 'cancelled')]],
    on_scene = [[UPDATE fpd_calls
       SET on_scene_at = COALESCE(on_scene_at, CURRENT_TIMESTAMP(3)),
           status = CASE WHEN status IN ('pending', 'dispatched', 'en_route')
                         THEN 'on_scene' ELSE status END,
           updated_by = ?, version = version + 1
     WHERE agency_id = ? AND id = ? AND status NOT IN ('cleared', 'cancelled')]],
}

--- A unit reporting its progress on a call: en route, on scene (7.16).
---
--- Three rows deep in one transaction: the unit's own status and `status_since`,
--- the call's status and its stamp, and the log line. They have to move together
--- -- a unit that reads `on_scene` on the board while the call it is on still
--- reads `dispatched` is two screens disagreeing about whether anybody has
--- arrived.
---
--- The status travels into the log line as the enum member and never as a
--- rendered label: the NUI resolves it through `cad.unitStatus.<status>` in the
--- *reader's* language (7.16.1).
---
--- **`status <> ?` carries the same weight here as it does in `setUnitStatus`,
--- and this is the second path to the same two statuses.** Pressing "On scene"
--- a second time must not restamp `status_since`: 7.16's welfare check is the
--- one alert written for a unit that has gone quiet, and a timer any key press
--- resets is a timer that never fires for the unit it exists for -- a bored
--- officer pressing the same button every nineteen minutes would defeat it
--- entirely, and so would a console that re-sent the status on a reconnect. The
--- log line carries the guard too, because it is the same press: a line per
--- press is a narrative that reads as a unit arriving four times.
---
--- The line therefore goes **before** the UPDATE. `u.status <> ?` is only true
--- while the status has not moved yet, so a guard read after the write would be
--- false on every press including the real one.
---
--- The call's own rung still advances unconditionally: a unit who set
--- `on_scene` off the call and then reports arriving on it has not changed
--- status, and the call still has to be stamped. `ADVANCE` is `COALESCE`d and
--- moves the status only from below, so running it twice costs nothing.
---
--- @param status string `en_route` or `on_scene`
--- @param unit table { officerId, discordId, callsign }
--- @return boolean committed; a press that changed nothing still commits
function Repo.reportProgress(agencyId, callId, status, unit)
    local advance = ADVANCE[status]
    if not advance then return false end

    local line = {}

    line[1] = callId
    line[2] = service().logMessageKey('unit_status')
    line[3] = json.encode({ callsign = unit.callsign, status = status })
    line[4] = unit.officerId
    line[5] = unit.discordId
    line[6] = unit.callsign
    line[7] = 'unit_status'
    line[8] = agencyId
    line[9] = unit.officerId
    line[10] = status

    return db().transaction({
        {
            -- `body` is a literal NULL rather than a bound nil, and the three
            -- trailing parameters are NOT NULL, so this values list neither has
            -- a hole at its end nor ends in one (see the header).
            query = [[INSERT INTO fpd_call_log
                          (agency_id, call_id, body, message_key, message_args,
                           officer_id, discord_id, callsign, entry_type)
                       SELECT u.agency_id, ?, NULL, ?, ?, ?, ?, ?, ?
                         FROM fpd_units u
                        WHERE u.agency_id = ? AND u.officer_id = ? AND u.status <> ?]],
            values = line,
        },
        {
            query = [[UPDATE fpd_units SET status = ?, status_since = CURRENT_TIMESTAMP(3)
                       WHERE agency_id = ? AND officer_id = ? AND status <> ?]],
            values = { status, agencyId, unit.officerId, status },
        },
        { query = advance, values = { unit.discordId, agencyId, callId } },
    })
end

--- Clears or cancels a call with a disposition (7.16).
---
--- Four things happen together, and none of them is safe on its own: the call
--- closes, every live assignment closes with it, the closing line is written,
--- and the units that were on it go back to `available`.
---
--- Two refusals live in the first statement's WHERE clause:
---
---   * `status NOT IN ('cleared', 'cancelled')` -- clearing a call twice changes
---     nothing, rather than overwriting who closed it and when;
---   * `source <> 'panic' OR acknowledged_at IS NOT NULL` -- 7.16's "cannot be
---     cleared without supervisor acknowledgement". The caller checks it too,
---     which is what produces the readable `needs_acknowledgement` refusal; this
---     closes the race between that check and this write, so the worst case is a
---     call that stays open rather than `ck_fpd_calls_panic_ack` surfacing as an
---     `internal` error.
---
--- **The transaction commits either way**, because a transaction reports only
--- that it committed and not what each statement matched. So the caller reads
--- the call back and looks at its status: that is the one place "did I close
--- it?" can be answered honestly, and 11.3 is explicit that "query succeeded" is
--- not "row changed".
---
--- **Every other statement here is written so that losing the race costs
--- nothing, and `@fpd_changed` is what makes that true rather than nearly
--- true.** The close runs first and its affected-row count is captured in the
--- very next statement; everything after it carries `@fpd_changed > 0`. Two of
--- them are inserts into a log nothing can edit afterwards, so without the guard
--- the second dispatcher to press Clear writes a second "cleared" line, signed
--- by them, onto a call somebody else closed -- and their note underneath it.
--- The two updates are guarded for the same reason a beat less obviously: a unit
--- the winner already freed, who has since gone `en_route` to something else, is
--- not a unit the loser may set `available`.
---
--- `ck_fpd_calls_disposition` requires a disposition on a `cleared` call and
--- `ck_fpd_calls_closed` requires `cleared_at` on both terminal statuses; both
--- are written here. Which of the two statuses this is comes from
--- `Cad.closureFor` -- a call closed as a duplicate, or stood down by the
--- caller, did not happen, and counting it as cleared inflates every workload
--- report by the calls nobody went to.
---
--- Which statuses come back to `available` comes from `Cad.statusAfterCall`,
--- which is the same rule `releaseUnits` and the divert in `assignUnits` go
--- through. Reading that list here rather than writing it into the SQL is what
--- put `emergency` on it: the officer who pressed panic can leave that status by
--- no other route -- it is on neither `SELF_SET_UNIT_STATUSES` nor
--- `SUPERVISOR_UNIT_STATUSES` -- so a clear that skipped it left them reading as
--- in distress on the board indefinitely, and `Cad.isFree` excludes `emergency`,
--- so nothing would ever recommend them again.
---
--- @param params table { status, disposition, note }
--- @param units table list of { officerId } still on the call
--- @return boolean committed
function Repo.clearCall(agencyId, callId, params, units, actor)
    local cad = service()
    local statuses, freed = cad.statusesClearedByCall(cad.CALL_ENDED)
    local holders = {}

    for index = 1, #statuses do holders[index] = '?' end

    local statements = {
        {
            query = [[UPDATE fpd_calls
                         SET status = ?, disposition = ?, cleared_at = CURRENT_TIMESTAMP(3),
                             cleared_by = ?, updated_by = ?, version = version + 1
                       WHERE agency_id = ? AND id = ?
                         AND status NOT IN ('cleared', 'cancelled')
                         AND (source <> 'panic' OR acknowledged_at IS NOT NULL)]],
            values = {
                params.status, params.disposition, actor.discordId, actor.discordId,
                agencyId, callId,
            },
        },
        -- Immediately after the close and before anything else: `ROW_COUNT()`
        -- reports the statement before it, so one statement in between would
        -- capture that one instead.
        captureChanged(),
        {
            query = [[UPDATE fpd_call_units SET left_at = CURRENT_TIMESTAMP(3)
                       WHERE agency_id = ? AND call_id = ? AND left_at IS NULL
                         AND @fpd_changed > 0]],
            values = { agencyId, callId },
        },
    }

    if params.note then
        statements[#statements + 1] = changedLogStatement(agencyId, callId, {
            entryType = 'note',
            body = params.note,
            officerId = actor.officerId,
            discordId = actor.discordId,
            callsign = actor.callsign,
        })
    end

    statements[#statements + 1] = changedLogStatement(agencyId, callId, {
        entryType = 'cleared',
        messageKey = cad.logMessageKey('cleared', { disposition = params.disposition }),
        -- The disposition travels as the enum member; the NUI renders it through
        -- `cad.disposition.<value>` (7.16.1).
        args = { disposition = params.disposition },
        officerId = actor.officerId,
        discordId = actor.discordId,
        callsign = actor.callsign,
    })

    local freeWorked <const> = ([[UPDATE fpd_units
                 SET status = ?, status_since = CURRENT_TIMESTAMP(3)
               WHERE agency_id = ? AND officer_id = ? AND status IN (%s)
                 AND @fpd_changed > 0]]):format(table.concat(holders, ', '))

    for index = 1, #units do
        local values = {}

        values[1] = freed
        values[2] = agencyId
        values[3] = units[index].officerId

        for step = 1, #statuses do values[3 + step] = statuses[step] end

        -- Only a unit the call itself had working goes back to available. A
        -- unit that has already moved on -- transporting a prisoner from this
        -- call, say -- keeps the status it chose, which is why the WHERE names
        -- the statuses the call put them in rather than clearing whatever they
        -- are doing now.
        statements[#statements + 1] = { query = freeWorked, values = values }
    end

    return db().transaction(statements)
end

--- A supervisor acknowledging an emergency call (7.16).
---
--- Stamped once, by the first supervisor to press it: `acknowledged_at IS NULL`
--- in the WHERE means a second press changes nothing rather than overwriting who
--- acknowledged it. Who acknowledged an officer's emergency is not a field to be
--- rewritten later, so the caller reads the row count and reports the second
--- press as a conflict.
---
--- The log line rides on `call_status`, because that is what happened -- the
--- call's acknowledgement state moved -- and `ck_fpd_call_log_type` has no entry
--- type of its own for it. `cad.log.acknowledged` is the key 7.16 asks for.
---
--- @return number rows affected
function Repo.acknowledgeCall(agencyId, callId, actor)
    local affected = db().execute(
        [[UPDATE fpd_calls
             SET acknowledged_by = ?, acknowledged_at = CURRENT_TIMESTAMP(3),
                 updated_by = ?, version = version + 1
           WHERE agency_id = ? AND id = ? AND acknowledged_at IS NULL]],
        { actor.discordId, actor.discordId, agencyId, callId }
    )

    if affected > 0 then
        Repo.addLog(agencyId, callId, {
            entryType = 'call_status',
            messageKey = 'cad.log.acknowledged',
            args = { callsign = actor.callsign },
            officerId = actor.officerId,
            discordId = actor.discordId,
            callsign = actor.callsign,
        })
    end

    return affected
end

-- -----------------------------------------------------------------------------
-- The unit board and AVL (7.1, 7.16, 7.17)
-- -----------------------------------------------------------------------------

--- The board, with what each unit is on (7.16: every unit, status, assignment,
--- time in status).
---
--- Cost: a range read of `idx_fpd_units_board (agency_id, status,
--- status_since)`, which serves the filter and the order together, plus one seek
--- per unit on `idx_fpd_call_units_unit` and one primary-key lookup for the call
--- behind it. The board is the size of the shift, not of the history, and this
--- is the other read every console makes every few seconds (12.1).
---
--- @param filter table|nil { status, beatId, limit, includeOffDuty }
function Repo.listUnits(agencyId, filter)
    filter = filter or {}

    local where = { 'u.agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        where[#where + 1] = 'u.status = ?'
        values[#values + 1] = filter.status
    elseif not filter.includeOffDuty then
        -- No status filter means the board, and the board is who is working. A
        -- signed-off unit keeps its row so it comes back on the same call after
        -- a reconnect (0007), and it is not on the board until it does.
        where[#where + 1] = "u.status <> 'off_duty'"
    end

    if filter.beatId then
        where[#where + 1] = 'u.beat_id = ?'
        values[#values + 1] = filter.beatId
    end

    values[#values + 1] = filter.limit or 200

    return db().query(
        ([[SELECT %s, %s
             FROM fpd_units u %s
            WHERE %s
            ORDER BY u.status, u.status_since
            LIMIT ?]]):format(UNIT_COLUMNS, UNIT_ASSIGNMENT_COLUMNS, UNIT_ASSIGNMENT_JOIN,
            table.concat(where, ' AND ')),
        values
    )
end

--- One unit, by the officer it belongs to.
---
--- `fpd_units.officer_id` is the whole primary key -- the table has no `id`
--- column -- so this is a primary-key lookup, with the agency checked on the row
--- so another agency's unit answers nothing. Which is what lets a dispatch
--- naming an unknown officer be refused as unknown rather than as another
--- agency's callsign: a refusal that told those apart would be a way to
--- enumerate them.
function Repo.getUnit(agencyId, officerId)
    return db().single(
        ([[SELECT %s, %s FROM fpd_units u %s
            WHERE u.agency_id = ? AND u.officer_id = ?]])
            :format(UNIT_COLUMNS, UNIT_ASSIGNMENT_COLUMNS, UNIT_ASSIGNMENT_JOIN),
        { agencyId, officerId }
    )
end

--- Signs a unit on, or brings one back after a reconnect (7.1).
---
--- **The reconnect case is the whole of the difficulty.** A unit is per officer
--- and not per session precisely so that an officer whose game crashed mid-call
--- comes back as the same unit, on the same call, with the same time in status
--- (0007). So the duplicate-key branch must not reset `status` or `status_since`
--- for a unit that is already working: that would report them as having gone
--- available at the moment their game crashed, and would restart the welfare
--- timer for a unit lying in a ditch.
---
--- It does reset both for a unit that was `off_duty`, which is an ordinary
--- sign-on.
---
--- The order of the assignments is load-bearing: MariaDB applies them left to
--- right, so `status_since` and `signed_on_at` are written before `status`, or
--- their CASE reads the value this same statement has just written and never
--- fires.
---
--- **Nothing calls this yet, and until something does there are no units.**
--- `fpd_units` is new in 0007 and 7.1's unit log-on has no route among M4's
--- schemas, so every CAD route that needs a unit answers `no_unit` until the
--- sign-on path -- the duty bridge, or a route of its own -- calls this. It is
--- written here because the reconnect rule above is the part that is easy to get
--- wrong and expensive to get wrong.
---
--- @param unit table { officerId, discordId, callsign, beatId, division,
---   vehiclePlate, vehicleModel }
--- @return number rows affected
function Repo.signOn(agencyId, unit)
    local values = {}

    values[1] = agencyId
    values[2] = unit.discordId
    values[3] = unit.beatId
    values[4] = unit.division
    values[5] = unit.vehiclePlate
    values[6] = unit.vehicleModel
    values[7] = unit.officerId
    values[8] = unit.callsign

    return db().execute(
        [[INSERT INTO fpd_units
              (agency_id, discord_id, beat_id, division, vehicle_plate, vehicle_model,
               officer_id, callsign)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE
              discord_id = VALUES(discord_id),
              callsign = VALUES(callsign),
              beat_id = VALUES(beat_id),
              division = VALUES(division),
              vehicle_plate = VALUES(vehicle_plate),
              vehicle_model = VALUES(vehicle_model),
              status_since = CASE WHEN status = 'off_duty'
                                  THEN CURRENT_TIMESTAMP(3) ELSE status_since END,
              signed_on_at = CASE WHEN status = 'off_duty'
                                  THEN CURRENT_TIMESTAMP(3) ELSE signed_on_at END,
              status = CASE WHEN status = 'off_duty' THEN 'available' ELSE status END]],
        values
    )
end

--- Sets a unit's status and stamps the time in status (7.1, 7.16).
---
--- `status <> ?` at the end makes setting a status the unit already holds a
--- no-op that affects no rows, so the caller can answer `nothing_to_change`
--- rather than restarting the welfare timer for a unit that did nothing.
---
--- This is the only place `status_since` is written outside sign-on, the boot
--- sweep and a unit's own progress on a call, which is what 0007 requires: the
--- AVL sweep writes this row every second or two, and a `status_since` that
--- moved with it would mean the welfare check never fired -- and never fired for
--- the unit that has stopped moving, which is the only unit it is for.
---
--- @return number rows affected
function Repo.setUnitStatus(agencyId, officerId, status)
    return db().execute(
        [[UPDATE fpd_units SET status = ?, status_since = CURRENT_TIMESTAMP(3)
           WHERE agency_id = ? AND officer_id = ? AND status <> ?]],
        { status, agencyId, officerId, status }
    )
end

--- Changes a unit's callsign, beat or division (7.16 unit management).
---
--- Status is deliberately not here: it goes through `setUnitStatus`, which is
--- the one place `status_since` is stamped. A second path that set the status
--- without the stamp is how `ck_fpd_units_status` stays satisfied while the
--- board's time-in-status column quietly starts lying.
---
--- @param fields table { callsign, beatId, division }
--- @return number rows affected
function Repo.updateUnit(agencyId, officerId, fields)
    local sets, values = {}, {}

    if fields.callsign ~= nil then
        sets[#sets + 1] = 'callsign = ?'
        values[#values + 1] = fields.callsign
    end

    if fields.beatId ~= nil then
        sets[#sets + 1] = 'beat_id = ?'
        values[#values + 1] = fields.beatId
    end

    if fields.division ~= nil then
        sets[#sets + 1] = 'division = ?'
        values[#values + 1] = fields.division
    end

    if #sets == 0 then return 0 end

    values[#values + 1] = agencyId
    values[#values + 1] = officerId

    return db().execute(
        ('UPDATE fpd_units SET %s WHERE agency_id = ? AND officer_id = ?')
            :format(table.concat(sets, ', ')),
        values
    )
end

--- Writes the AVL positions the server read off the peds (7.17, 3.6).
---
--- One transaction of primary-key updates -- one round trip per sweep rather
--- than one per unit. The sweep runs every one to two seconds for every agency
--- with a session watching the map, so the number of round trips is the part of
--- it that has to stay flat at two hundred players (12.1).
---
--- `status_since` is untouched, which is the point of this being its own
--- statement rather than part of any other write to `fpd_units`.
---
--- @param positions table list of { officerId, x, y, z, heading }
--- @return boolean committed
function Repo.savePositions(agencyId, positions)
    if type(positions) ~= 'table' or #positions == 0 then return true end

    local statements = {}

    for index = 1, #positions do
        local at = positions[index]

        statements[index] = {
            query = [[UPDATE fpd_units
                         SET x = ?, y = ?, z = ?, heading = ?, position_at = CURRENT_TIMESTAMP(3)
                       WHERE agency_id = ? AND officer_id = ?]],
            values = { at.x, at.y, at.z, at.heading, agencyId, at.officerId },
        }
    end

    return db().transaction(statements)
end

--- Signs every unit off at boot (0007).
---
--- A unit row survives a restart, and after a restart there is no session to
--- contradict it, so every row is a ghost until its officer comes back and says
--- otherwise. This writes a status nobody asked for, and that is the right
--- direction to be wrong in: a board that has forgotten a real unit is corrected
--- by that unit pressing one key, and a board still showing a unit who left two
--- hours ago sends somebody to a call nobody is going to.
---
--- Every agency at once, because a restart is not per agency.
---
--- **Nothing calls this yet.** It belongs on the resource's own start-up path,
--- and until it is called there a restart leaves yesterday's board on screen.
---
--- @return number rows affected
function Repo.signOffAllUnits()
    return db().execute(
        [[UPDATE fpd_units SET status = 'off_duty', status_since = CURRENT_TIMESTAMP(3)
           WHERE status <> 'off_duty']]
    )
end

-- -----------------------------------------------------------------------------
-- Beats (7.17)
-- -----------------------------------------------------------------------------

local BEAT_COLUMNS <const> = [[
    b.id, b.agency_id AS agencyId, b.code, b.label_key AS labelKey, b.kind, b.polygon,
    b.min_x AS minX, b.min_y AS minY, b.max_x AS maxX, b.max_y AS maxY,
    b.precedence, b.enabled
]]

--- Every beat and district of one agency, most specific first (7.17).
---
--- Cost: a range read of `idx_fpd_beats_active (agency_id, enabled,
--- precedence)`, read backwards for `DESC` -- an index costs the same either
--- way. The set is small by design: 0007 budgets the tagger against an agency
--- that has drawn thirty districts, and the map needs all of them at once or it
--- draws a district with a hole in it.
---
--- The polygon is decoded here rather than in the service, because `json.decode`
--- is a runtime global that busted does not have, and a decoder inside
--- `service.lua` would make the point-in-polygon test untestable to save one
--- line here.
---
--- @param includeDisabled boolean|nil for a caller that must tell "no such beat"
---   from "that district was retired last week"
function Repo.listBeats(agencyId, includeDisabled)
    local rows = db().query(
        ([[SELECT %s FROM fpd_beats b
            WHERE b.agency_id = ?%s
            ORDER BY b.precedence DESC, b.id]])
            :format(BEAT_COLUMNS, includeDisabled and '' or ' AND b.enabled = 1'),
        { agencyId }
    )

    for index = 1, #rows do
        local row = rows[index]

        if type(row.polygon) == 'string' then
            row.polygon = json.decode(row.polygon)
        end
    end

    return rows
end

--- Writes a beat, with the bounding box the service computed.
---
--- The box is the one derived value in 0007 the database cannot compute --
--- deriving it needs `JSON_TABLE`, which is not allowed in a generated column --
--- and no route may accept one from input: `ck_fpd_beats_bbox` catches an
--- inverted box, but a box that is merely too small is valid SQL that silently
--- stops tagging calls in part of a district, which reads as a quiet beat rather
--- than as a bug. So it is computed here, from the polygon being written, in the
--- same statement, and never passed in.
---
--- **No route reaches this yet.** M4 draws and reads beats and has no beat
--- editor -- `BeatList` is the only beat schema in `packages/schema` -- so a
--- server seeds `fpd_beats` by hand today. It lives here so that whoever adds
--- that editor writes the polygon and its box together, which is the only way
--- the invariant above can hold.
---
--- @param beat table { code, labelKey, kind, polygon (a table), precedence }
--- @return number rows affected, or 0 when the polygon is not one
function Repo.saveBeat(agencyId, beat, discordId)
    local box = service().boundingBox(beat.polygon)
    if not box then return 0 end

    local values = {}

    values[1] = agencyId
    values[2] = beat.labelKey
    values[3] = json.encode(beat.polygon)
    values[4] = box.minX
    values[5] = box.minY
    values[6] = box.maxX
    values[7] = box.maxY
    values[8] = beat.precedence or 0
    values[9] = discordId
    values[10] = discordId
    values[11] = beat.kind or 'beat'
    values[12] = beat.code

    return db().execute(
        [[INSERT INTO fpd_beats
              (agency_id, label_key, polygon, min_x, min_y, max_x, max_y,
               precedence, created_by, updated_by, kind, code)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE
              label_key = VALUES(label_key), polygon = VALUES(polygon),
              min_x = VALUES(min_x), min_y = VALUES(min_y),
              max_x = VALUES(max_x), max_y = VALUES(max_y),
              precedence = VALUES(precedence), kind = VALUES(kind),
              updated_by = VALUES(updated_by)]],
        values
    )
end

-- -----------------------------------------------------------------------------
-- Broadcasts (7.16 [S], 7.26)
-- -----------------------------------------------------------------------------

--- Puts a broadcast on the air (7.16 [S]).
---
--- The expiry is computed by the database from its own clock, because a client
--- sends minutes and never a timestamp (invariant 1). `DATE_ADD` with a NULL
--- interval is NULL, so a broadcast meant to stand until somebody takes it off
--- needs no second statement -- but the caller passes the configured default
--- rather than nil, because a board nobody clears is what that default exists to
--- prevent. `ck_fpd_broadcasts_expiry` then requires the result to be after
--- `created_at`, which the five-minute floor in the schema guarantees.
---
--- @param broadcast table { kind, priority, title, body, plate, callId, minutes }
--- @return number|nil id
function Repo.createBroadcast(agencyId, broadcast, discordId)
    local values = {}

    values[1] = agencyId
    values[2] = broadcast.priority or 3
    values[3] = broadcast.title
    values[4] = broadcast.plate
    values[5] = broadcast.callId
    values[6] = broadcast.minutes
    values[7] = discordId
    values[8] = broadcast.kind or 'all_units'
    values[9] = broadcast.body

    return db().insert(
        [[INSERT INTO fpd_broadcasts
              (agency_id, priority, title, plate, call_id, expires_at, created_by, kind, body)
          VALUES (?, ?, ?, ?, ?, DATE_ADD(CURRENT_TIMESTAMP(3), INTERVAL ? MINUTE), ?, ?, ?)]],
        values
    )
end

--- Takes a broadcast off the air.
---
--- Stamped, never deleted: "what was out on the air at the time" is a question
--- asked after an arrest, and the answer has to survive the shift it was asked
--- about. `cancelled_at IS NULL` means a second cancellation changes nothing
--- rather than rewriting who took it off.
---
--- Answers a boolean and not a count, because the caller writes
--- `if not repo.cancelBroadcast(...)` and zero is truthy in Lua (see the
--- header).
---
--- @return boolean whether this call took it off the air
function Repo.cancelBroadcast(agencyId, id, discordId)
    local affected = db().execute(
        [[UPDATE fpd_broadcasts
             SET cancelled_at = CURRENT_TIMESTAMP(3), cancelled_by = ?
           WHERE agency_id = ? AND id = ? AND cancelled_at IS NULL]],
        { discordId, agencyId, id }
    )

    return affected > 0
end

--- The broadcast board (7.16 [S]).
---
--- Cost: `idx_fpd_broadcasts_live (agency_id, cancelled_at, expires_at)` for
--- what is on the air -- two equalities and a range, the shape
--- `fpd_vehicle_flags` uses in 0005 -- and `idx_fpd_broadcasts_history
--- (agency_id, created_at)` for the history. That is why `includeExpired` is a
--- flag rather than a date window: they are two different index reads, and a
--- window would be neither.
---
--- @param filter table { includeExpired, kind, callId, limit }
function Repo.listBroadcasts(agencyId, filter)
    local where = { 'b.agency_id = ?' }
    local values = { agencyId }

    if not filter.includeExpired then
        where[#where + 1] = 'b.cancelled_at IS NULL'
        where[#where + 1] = '(b.expires_at IS NULL OR b.expires_at > CURRENT_TIMESTAMP(3))'
    end

    if filter.kind then
        where[#where + 1] = 'b.kind = ?'
        values[#values + 1] = filter.kind
    end

    if filter.callId then
        where[#where + 1] = 'b.call_id = ?'
        values[#values + 1] = filter.callId
    end

    values[#values + 1] = filter.limit or 100

    return db().query(
        ([[SELECT b.id, b.kind, b.priority, b.title, b.body, b.plate,
                  b.call_id AS callId, b.expires_at AS expiresAt,
                  b.cancelled_at AS cancelledAt, b.cancelled_by AS cancelledBy,
                  b.created_by AS createdBy, b.created_at AS createdAt
             FROM fpd_broadcasts b
            WHERE %s
            ORDER BY b.priority, b.created_at DESC
            LIMIT ?]]):format(table.concat(where, ' AND ')),
        values
    )
end

-- -----------------------------------------------------------------------------
-- ALPR (7.18)
-- -----------------------------------------------------------------------------

local HOTLIST_COLUMNS <const> = [[
    h.id, h.plate, h.reason, h.detail, h.case_number AS caseNumber, h.silent,
    h.expires_at AS expiresAt, h.cancelled_at AS cancelledAt,
    h.cancelled_by AS cancelledBy, h.created_by AS createdBy, h.created_at AS createdAt
]]

--- Every live hotlist entry for a plate (7.18).
---
--- Cost: one seek on `idx_fpd_hotlist_check (agency_id, plate, live,
--- expires_at)`, which covers the whole predicate -- so a plate that is not
--- listed never touches the table, which is almost every plate a patrol car
--- drives past. This is the check a plate read makes, and plate reads are the
--- highest-volume event in the suite.
---
--- Every match comes back rather than the first, because `silent` is per entry
--- (7.18, and section 9): a plate can be listed twice for different reasons, and
--- whether a unit is shown a banner is decided per entry by the caller.
---
--- This is not a hot-file cache and nothing may sync one into it: a stolen car
--- is derived at query time from `fpd_vehicle_flags`, which is the record that
--- is the truth for it (0005, 0007). This table is the layer underneath it --
--- entries no record can produce.
---
--- **Nothing calls this yet.** 7.18 is [S] and the radar bridge that would feed
--- it is not built; this and `recordRead` are the two functions that bridge will
--- call, and they are written beside the hotlist because the check and the read
--- are one decision.
function Repo.hotlistHits(agencyId, plate)
    return db().query(
        ([[SELECT %s FROM fpd_hotlist h
            WHERE h.agency_id = ? AND h.plate = ? AND h.live = 1
              AND (h.expires_at IS NULL OR h.expires_at > CURRENT_TIMESTAMP(3))]])
            :format(HOTLIST_COLUMNS),
        { agencyId, plate }
    )
end

--- Records a plate read (7.18).
---
--- The position comes from the server, off the unit's ped, exactly as the AVL
--- sweep does -- never from the radar resource's client (invariant 1). `hit` and
--- `hotlist_id` record what the read matched *at the time*, which is not what
--- the hotlist says now, and that is the point: "was this car flagged when the
--- camera saw it" is the question a stop is justified by.
---
--- Cost: one insert into the narrowest table in the suite. There is deliberately
--- no read here -- resolving a plate to a registration happens when the reads
--- are looked at, not when they are taken, because the plate may have changed
--- hands since (`fpd_vehicle_plates`, 0005).
---
--- **Nothing calls this yet**, for the reason `hotlistHits` gives.
---
--- @param read table { plate, x, y, z, officerId, discordId, callsign, camera,
---   hit, hotlistId }
--- @return number|nil id
function Repo.recordRead(agencyId, read)
    local values = {}

    values[1] = agencyId
    values[2] = read.officerId
    values[3] = read.discordId
    values[4] = read.callsign
    values[5] = read.camera
    values[6] = read.hit and 1 or 0
    values[7] = read.hotlistId
    values[8] = read.x
    values[9] = read.y
    values[10] = read.z
    values[11] = read.plate

    return db().insert(
        [[INSERT INTO fpd_alpr_reads
              (agency_id, officer_id, discord_id, callsign, camera, hit, hotlist_id,
               x, y, z, plate)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        values
    )
end

--- Plate reads, filtered (7.18).
---
--- Cost, by filter: a plate reads `idx_fpd_alpr_reads_plate (agency_id, plate,
--- read_at)`, "hits only" reads `idx_fpd_alpr_reads_hit`, and everything else
--- reads `idx_fpd_alpr_reads_time (agency_id, read_at)` -- which is also the
--- index the retention sweep deletes by. The window is in hours rather than a
--- pair of timestamps, so the range is always bounded from the server's clock.
---
--- The hotlist entry a read matched is joined in for one reason: `silent` and
--- the entry's author are what decide whether this reader may be told there was
--- a hit at all (7.18, section 9), and without them the caller has to read the
--- whole hotlist to find out. Cost: one primary-key seek per row that matched
--- something, which on a patrol car's reads is almost none of them.
---
--- @param filter table { plate, officerId, sinceHours, hitsOnly, limit }
function Repo.listReads(agencyId, filter)
    local where = { 'r.agency_id = ?' }
    local values = { agencyId }

    if filter.plate then
        where[#where + 1] = 'r.plate = ?'
        values[#values + 1] = filter.plate
    end

    if filter.officerId then
        where[#where + 1] = 'r.officer_id = ?'
        values[#values + 1] = filter.officerId
    end

    if filter.hitsOnly then
        where[#where + 1] = 'r.hit = 1'
    end

    if filter.sinceHours then
        where[#where + 1] = 'r.read_at >= DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? HOUR)'
        values[#values + 1] = filter.sinceHours
    end

    values[#values + 1] = filter.limit or 100

    return db().query(
        ([[SELECT r.id, r.plate, r.read_at AS readAt,
                  UNIX_TIMESTAMP(r.read_at) AS readAtUnix, r.x, r.y, r.z,
                  r.officer_id AS officerId, r.discord_id AS discordId, r.callsign,
                  r.camera, r.hit, r.hotlist_id AS hotlistId,
                  h.reason AS hotlistReason, h.silent, h.created_by AS hotlistCreatedBy
             FROM fpd_alpr_reads r
             LEFT JOIN fpd_hotlist h ON h.id = r.hotlist_id
            WHERE %s
            ORDER BY r.read_at DESC
            LIMIT ?]]):format(table.concat(where, ' AND ')),
        values
    )
end

--- Adds a plate to the hotlist, or extends the entry that is already there.
---
--- `ON DUPLICATE KEY UPDATE` on `uq_fpd_hotlist_live (agency_id, plate, reason,
--- live)`: adding a plate that is already listed for the same reason extends
--- that row -- including re-arming one whose expiry has passed -- rather than
--- stacking a second row that raises two banners and that nobody would think to
--- cancel twice. Cancelled rows drop out of the key, because NULLs are distinct
--- in a MariaDB unique index, so a plate can be listed again after it was taken
--- off.
---
--- @param entry table { plate, reason, detail, caseNumber, silent, minutes }
--- @return number rows affected
function Repo.addHotlist(agencyId, entry, discordId)
    local values = {}

    values[1] = agencyId
    values[2] = entry.detail
    values[3] = entry.caseNumber
    values[4] = entry.silent and 1 or 0
    values[5] = entry.minutes
    values[6] = discordId
    values[7] = entry.plate
    values[8] = entry.reason

    return db().execute(
        [[INSERT INTO fpd_hotlist
              (agency_id, detail, case_number, silent, expires_at, created_by, plate, reason)
          VALUES (?, ?, ?, ?, DATE_ADD(CURRENT_TIMESTAMP(3), INTERVAL ? MINUTE), ?, ?, ?)
          ON DUPLICATE KEY UPDATE
              detail = VALUES(detail), case_number = VALUES(case_number),
              silent = VALUES(silent), expires_at = VALUES(expires_at)]],
        values
    )
end

--- Takes a plate off the hotlist (7.18).
---
--- Stamped rather than deleted, for the reason a broadcast is: the reads it
--- matched are evidence that a stop was justified when it was made, and
--- `fpd_alpr_reads.hotlist_id` still points at this row.
---
--- One entry at a time -- `uq_fpd_hotlist_live` is per reason, so a plate can be
--- listed for several -- because the caller decides which of them this session
--- may see at all: a silent entry is a covert watch (7.18, section 9), and one
--- that a supervisor tidying the board could end, or merely count, is a covert
--- watch disclosed to most of the department.
---
--- @return number rows taken off
function Repo.cancelHotlist(agencyId, plate, reason, discordId)
    return db().execute(
        [[UPDATE fpd_hotlist
             SET cancelled_at = CURRENT_TIMESTAMP(3), cancelled_by = ?
           WHERE agency_id = ? AND plate = ? AND reason = ? AND cancelled_at IS NULL]],
        { discordId, agencyId, plate, reason }
    )
end

--- The hotlist, for the screen that manages it (7.18).
---
--- Cost: `idx_fpd_hotlist_manage (agency_id, cancelled_at, created_at)` for the
--- live list; a plate filter uses `idx_fpd_hotlist_check` instead.
---
--- `silent` and `createdBy` come back so the caller can drop the entries this
--- reader may not be told about. Filtering here instead would mean this function
--- knowing who is asking, which is the route's job and not the repo's.
---
--- @param filter table { plate, reason, includeExpired, limit }
function Repo.listHotlist(agencyId, filter)
    local where = { 'h.agency_id = ?' }
    local values = { agencyId }

    if not filter.includeExpired then
        where[#where + 1] = 'h.cancelled_at IS NULL'
        where[#where + 1] = '(h.expires_at IS NULL OR h.expires_at > CURRENT_TIMESTAMP(3))'
    end

    if filter.plate then
        where[#where + 1] = 'h.plate = ?'
        values[#values + 1] = filter.plate
    end

    if filter.reason then
        where[#where + 1] = 'h.reason = ?'
        values[#values + 1] = filter.reason
    end

    values[#values + 1] = filter.limit or 100

    return db().query(
        ([[SELECT %s FROM fpd_hotlist h
            WHERE %s
            ORDER BY h.created_at DESC
            LIMIT ?]]):format(HOTLIST_COLUMNS, table.concat(where, ' AND ')),
        values
    )
end

--- Deletes plate reads past the retention window (7.18, 13.3, 11.4).
---
--- The one table in FredPD whose rows are meant to be deleted on a schedule: a
--- permanent record of every car every patrol has driven past is a movement
--- database, and 11.4 is why it does not become one.
---
--- **One bounded batch per call**, by `(agency_id, read_at)` through
--- `idx_fpd_alpr_reads_time`; the caller loops until it returns zero. This is
--- the largest table in the suite by an order of magnitude, and a single
--- unbounded DELETE holds locks over a range of it for as long as it takes --
--- which on a server that has not swept for a month is long enough to stall
--- every plate check a patrol unit makes.
---
--- **Nothing calls this yet.** 7.18 gives the sweep to the gateway scheduler and
--- the gateway is off by default (ADR-010), so the retention window is not being
--- enforced anywhere; this is the statement whichever scheduler ends up owning
--- it should call.
---
--- @param batch number|nil rows per call
--- @return number rows deleted in this batch
function Repo.purgeReads(agencyId, days, batch)
    return db().execute(
        [[DELETE FROM fpd_alpr_reads
           WHERE agency_id = ? AND read_at < DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? DAY)
           LIMIT ?]],
        { agencyId, days, batch or 1000 }
    )
end

FredPD.Repo.cad = Repo
