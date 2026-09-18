--- Dispatch (CAD) routes: calls, the unit board, the map, broadcasts and ALPR
--- (spec 7.16, 7.17, 7.18).
---
--- Everything a dispatcher or a unit can do to a call arrives here, and five
--- things are decided in this file and nowhere else.
---
---   * **Who may do what to a call.** Self-assigning is not dispatching;
---     clearing the call you are on is not clearing somebody else's; a
---     supervisor moving another unit's status is not an officer setting their
---     own. Appendix B splits those into separate keys and the handlers below
---     split them the same way, refusing with a code the card can render --
---     `not_assigned`, `no_unit`, `needs_acknowledgement` -- rather than a bare
---     `forbidden`, which tells an officer holding a radio nothing.
---   * **Where the console is required.** `call.create` and `call.dispatch` are
---     pinned to a `dispatch_console` placement (3.10), because those are the
---     two things a dispatcher does sitting down. Nothing else is pinned: an
---     officer in a car is not standing at the console, and a field route pinned
---     to it is dead for exactly the person it was written for.
---   * **That no position is ever accepted.** The emergency button takes no
---     arguments at all; its position is read off the ped, server-side. See
---     `avl.lua` for the argument, which is the one 0007's header also makes.
---   * **That a generated log line is a locale key.** Every status change,
---     assignment, lead transfer and clearing writes a line, and
---     `ck_fpd_call_log_content` makes an English sentence in `body` unstorable
---     for anything but a `note`. The key/argument pairing is 7.16.1's table and
---     lives in `service.logMessageKey`; the repo builds most lines from it, and
---     the two this file writes directly go through `logLine` below.
---   * **That nothing here is broadcast.** A call goes to the sessions of this
---     agency that hold `page.dispatch` and may read that call, and to nobody
---     else (invariant 5). The emergency is narrower still: dispatchers,
---     supervisors, and the units actually in range -- range measured
---     server-side, off their peds.
---
--- ## How a call is access-checked, and where that stops short
---
--- `fpd_calls` carries a `classification`, and the repo aliases `agency_id`
--- beside it so that `Access.control` can read the row. Every call this file
--- *reads back or pushes* has been through `accessRules.canRead`: one card,
--- every row of a list, the map payload, the recipient list of every push
--- (invariant 4, and invariant 5's "same checks as a read"), and -- the one that
--- had to be found rather than designed -- every call carried on a payload that
--- is nominally about something else. A call the reader may not see is absent
--- rather than stubbed: on a queue a placeholder would carry the count, the
--- priority and the position, which is most of what a call discloses. The two
--- routes that *create* a call answer with the row they have just written, to
--- the session that wrote it, which is the one reader whose clearance the write
--- itself already settled.
---
--- **The unit board is a call payload, and it does not look like one.**
--- `Repo.listUnits` and `Repo.getUnit` LEFT JOIN `fpd_calls` and alias five
--- columns off it -- `onCallId`, `onCallLead`, `onCallNumber`, `onCallPriority`,
--- `onCallStatus` -- so a board row carries the number, the urgency and the
--- stage of whatever its unit is working. Filtered on `page.dispatch` and the
--- agency and nothing else, that hands a reader who was correctly refused a call
--- on the queue that same call's number, priority and status one array further
--- down the same response.
---
--- That rule now lives in `board.lua` and not in this file, and the move is the
--- point rather than tidying. It was a local here, and this is one of *three*
--- places in the module that ships a board row: `events.lua` pushes one on
--- sign-on and sign-off, and `avl.lua`'s welfare prompt carries a call id and a
--- call number. Neither masked, and because the NUI replaces a unit row rather
--- than merging it, the sign-on push actively un-masked what this file had just
--- masked -- a hole in an access check that healed itself on the next duty pass.
--- So `board.mayRead`, `board.boardFor`, `board.withoutCall`, `board.readable`,
--- `board.callChanged` and `board.unitChanged` are that file's, every push below
--- goes through them, and a fourth sender gets the rule for free instead of
--- having to know it exists.
---
--- `Cad.recommendUnits` reasons over the *unmasked* board on purpose: a unit
--- shown as free because its reader may not see what it is on is a unit a
--- dispatcher sends to a second call. Only its answer is masked, and the only
--- field in that answer naming a call is `divertFromCallId`.
---
--- It is `Access.canRead` (the pure service) and not `Repo.read` (the register's
--- path) for one checkable reason: `call` is not in the `RECORD_TYPES` allowlist
--- in `access/repo.lua`, so `Repo.prepare` asserts on it. Three things therefore
--- do not happen for a call that a person or a vehicle gets -- compartments,
--- explicit grants, and the `access.read` audit row for a restricted read. That
--- is tolerable only because nothing in M4 writes a call above the column
--- default of `internal`: there is no route or export field that sets one. The
--- day a call can be classified higher, `call` goes into that allowlist and
--- `call.get` becomes `accessRepo.read` -- **and that fixes the card and nothing
--- else.** The queue, the board, the map and every push select their own rows
--- and hand them to `board.mayRead` directly; none of them goes through `Repo.read`,
--- so the allowlist entry never reaches them and each one would still need its
--- compartments and grants loaded by hand. The milestone report says so rather
--- than leaving it for somebody to infer from this comment.
---
--- `call.get` audits the restricted case and only that (`cad.call.read`), which
--- is what invariant 11 asks for. It audited every card it opened until the
--- console started refetching on every `fredpd:cad:call` push: one P1 with four
--- units then wrote dozens of `cad.call.read` rows per open console, none of
--- them a read anybody performed, and enough of them to spend the route's own
--- rate limit in the middle of the incident. `call.list` and `map.view` do not
--- audit either, for the older half of the same reason: they are polled every
--- few seconds by every open console (12.1), and an audit row per poll would
--- bury the log this invariant exists to keep readable.

local route = FredPD.Core.route
local service = FredPD.Modules.cad
local repo = FredPD.Repo.cad
local accessRules = FredPD.Modules.access
local accessRepo = FredPD.Repo.access
local perms = FredPD.Core.perms
-- No `FredPD.Core.push` here, and its absence is load-bearing: every push this
-- file makes goes through `board.lua`, which is what applies the page key, the
-- agency and the access check on whatever call the payload carries. A local
-- back to the raw push layer is how the fourth sender of a board row starts.
local audit = FredPD.Core.audit
local agencies = FredPD.Core.agencies
local ratelimit = FredPD.Core.ratelimit
local avl = FredPD.Cad.avl
local board = FredPD.Cad.board

--- The module's settings, merged once. `Cad.settings` is a pure merge over
--- `Cad.defaults`, so this is the same table the busted spec asserts against.
local settings = service.settings(FredPD.Config.server.cad)

-- -----------------------------------------------------------------------------
-- The permissions this file reasons about beyond each route's own `perm`
-- -----------------------------------------------------------------------------

--- The dispatch reads (Appendix B): the queue, a card, the board, the map and
--- the broadcast board are gated on the page key and on nothing else.
---
--- Taken from `board.lua` rather than written out again: that file pushes on the
--- same key, and a second copy of the string is how a rename leaves half a
--- module answering on a permission the other half no longer sends to.
local READ <const> = board.READ

--- "May act on a call this session is not a unit on."
---
--- `cad.unit.manage` and not `cad.call.dispatch`, because the three groups that
--- hold it -- supervisor, command, dispatch -- are exactly the people who work a
--- call from outside it, and Appendix B already uses this key for 7.16's
--- supervisor acknowledgement for the same reason. A patrol officer holds
--- `cad.call.clear` and not this one, so they can close the call they attended
--- and not the one two districts away.
local SUPERVISE <const> = 'cad.unit.manage'

--- The recommendation list is a dispatcher's tool (7.16 "recommend closest
--- available units"), so the card carries it for the sessions that can act on it
--- and leaves it off every other card rather than drawing it to be ignored.
local ASSIGNS <const> = 'cad.call.dispatch'

--- The two statuses that close a call, and the field code each refuses with.
---
--- `queue_priority` goes NULL for both (0007), so these are also exactly the
--- calls that have left the queue. Both codes are in `REASONS` in
--- `web/src/modules/shared/failure.ts` and in both locale files.
local CLOSED <const> = { cleared = 'call_cleared', cancelled = 'call_cancelled' }

--- Unit statuses that cannot be sent to a call, and the code each refuses with.
---
--- `off_duty` is a unit that is not working and `out_of_service` is one that has
--- been taken off the road; the dispatcher reads which it was, because the fix
--- differs. Everything else -- busy, transporting, already on a call -- is
--- assignable: moving a unit off what they are doing to something more urgent is
--- the job (7.16), and `service.recommendUnits` ranks that case rather than
--- hiding it.
local UNASSIGNABLE <const> = { off_duty = 'off_duty', out_of_service = 'unavailable' }

--- What the emergency button raises (7.16).
---
--- Fixed here rather than taken from the call: the button sends nothing, so
--- there is nothing to take. A P1 of type `officer_emergency` with source
--- `panic` -- and `panic` is the value `ck_fpd_calls_panic_ack` keys the
--- acknowledgement rule on, so changing this constant would quietly disable that
--- rule rather than fail.
local EMERGENCY <const> = {
    type = 'officer_emergency',
    priority = 1,
    source = 'panic',
}

--- How far an emergency carries, in metres.
---
--- 7.16: "tone for all dispatchers and units in range". Dispatchers are told
--- wherever they are; everyone else only if they could plausibly get there.
--- Measured on the server against each recipient's own ped, because a client
--- that decided whether it was in range would be a client deciding whether it
--- hears an officer calling for help.
local EMERGENCY_RANGE <const> = 800.0

--- The call types an outside resource may name, read off the generated enum
--- rather than restated. A hand-copied list disagrees with `packages/schema` the
--- day somebody adds a value, and `pnpm enum:check` cannot see a copy that lives
--- in a Lua table.
local CALL_TYPES <const> = {}

for _, value in pairs(FredPD.CallType) do CALL_TYPES[value] = true end

-- -----------------------------------------------------------------------------
-- Shared rules
-- -----------------------------------------------------------------------------

--- Trims a string to nil when it is blank, so an empty box is not stored as one.
local function text(value)
    if type(value) ~= 'string' then return nil end

    local trimmed = value:match('^%s*(.-)%s*$')
    return trimmed ~= '' and trimmed or nil
end

--- A plate as every plate column in the suite stores one: trimmed, upper-cased.
local function plate(value)
    local trimmed = text(value)

    return trimmed and trimmed:upper() or nil
end

--- Assembles one line of the narrative log (7.16.1).
---
--- Most lines are built by the repo, inside the transaction of the write they
--- describe. This is for the two the repo cannot build, because they belong to a
--- call it was not told about: a note, and a unit status changed off the back of
--- a call the unit happens to be on.
---
--- The key comes from `service.logMessageKey`, which is the only mapping from an
--- entry type to a locale key in the codebase. An argument that names a
--- vocabulary carries the enum member and never a rendered label -- `en_route`,
--- not "En route" -- because the line renders in the reader's language, not the
--- writer's.
---
--- @param entryType string a `FredPD.CallLogKind` member
--- @param args table|nil `message_args`
--- @param body string|nil what a person typed
--- @param actor table { discordId, officerId, callsign }
--- @return table the shape `Repo.addLog` takes
local function logLine(entryType, args, body, actor)
    return {
        entryType = entryType,
        messageKey = service.logMessageKey(entryType),
        args = args,
        body = body,
        officerId = actor.officerId,
        discordId = actor.discordId,
        callsign = actor.callsign,
    }
end

--- The author of a log line or an assignment, as the server knows them.
---
--- Never from input. The callsign is copied into `fpd_call_units` and
--- `fpd_call_log` as it was at the time, so the row stays readable after a
--- roster row is deleted and `officer_id` is nulled (0007).
local function actorOf(session, unit)
    return {
        discordId = session.discordId,
        officerId = session.officerId,
        callsign = unit and unit.callsign or session.callsign,
    }
end

--- Takes the diverted-from call off the recommendations naming one this reader
--- may not open.
---
--- The recommendation itself stays: that a unit is on scene somewhere and can be
--- pulled off it is the unit's own status, which the board already carries. What
--- comes off is the id of the call they would be pulled from, which is a call
--- this reader was refused. At most `recommendLimit` entries, so at most that
--- many lookups, and none for a board where nobody is divertible.
local function withoutDiverts(session, list)
    if list == nil then return nil end

    local calls = {}

    for index = 1, #list do
        local id = list[index].divertFromCallId

        if id ~= nil then
            if calls[id] == nil then calls[id] = repo.getCall(session.agencyId, id) or false end

            if not board.mayRead(session, calls[id] or nil) then
                list[index].divertFromCallId = nil
            end
        end
    end

    return list
end

-- Every push below is `board.lua`'s, because `events.lua` and `avl.lua` send the
-- same three messages and each had its own copy of the filters (see the header):
--
--   * `board.callChanged` -- the queue and the card. **Every route below that
--     writes anything to a call sends it**, including the ones whose only write
--     is a narrative line, so a client that handles that event alone is never
--     left showing a stale card.
--   * `board.unitChanged` -- one board row, which is a call payload in disguise,
--     so it goes out in two complementary halves.
--   * `board.toDispatch` -- the same delivery with no call on the payload at
--     all: a broadcast, a cancellation, a log line whose call has already been
--     checked.

--- Sends one narrative line to the sessions that may read the call it is on.
---
--- An optimisation on top of `board.callChanged` and never a replacement for
--- it: a card that is open can append the line without refetching a long log
--- (12.2's keyset pagination is what it would be paging through). It carries no
--- id and no timestamp, because the insert does not report them.
local function logPushed(agencyId, call, entry)
    if not call then return end

    board.toDispatch(agencyId, 'fredpd:cad:log', {
        callId = call.id,
        entry = entry,
    }, function(session)
        return board.mayRead(session, call)
    end)
end

--- The session's own unit row, or a refusal saying why there is not one.
---
--- `fpd_units.officer_id` is the whole primary key and is a foreign key to
--- `fpd_officers.id`, so the session's own officer id is the only lookup needed
--- -- and it is the session's, never input's (invariant 1).
---
--- A dispatcher at a console has no `fpd_units` row, and that is not an error:
--- they are not a unit, and nothing on this path is for them. `no_unit` says
--- exactly that and is held apart from `off_duty`, which is a unit that exists
--- and is not working -- the fix for one is to sign on and for the other to go
--- on duty, and one code would send half the people who met it to the wrong one.
---
--- @return table|nil unit
--- @return table|nil refusal
local function ownUnit(session, field)
    local unit = repo.getUnit(session.agencyId, session.officerId)

    if not unit then
        return nil, route.refuse(FredPD.ErrorCode.CONFLICT, { [field] = 'no_unit' })
    end

    if unit.status == FredPD.UnitStatus.OFF_DUTY then
        return nil, route.refuse(FredPD.ErrorCode.CONFLICT, { [field] = 'off_duty' })
    end

    return unit, nil
end

--- Loads a call that can still be worked, or refuses with the reason it cannot.
---
--- One place, because every write below needs the same three answers and the
--- third has to be readable: a call cleared while the officer was typing is not
--- "invalid input", it is a call somebody else closed, and `call_cleared` is
--- what the card renders for that.
---
--- @return table|nil call
--- @return table|nil refusal
local function openCall(session, callId, field)
    local call = repo.getCall(session.agencyId, callId)

    -- Another agency's call, and one this reader may not see, are both
    -- `not_found`: FredPD is multi-agency, whether a call exists is itself
    -- information, and a refusal that told the two apart is how the queue gets
    -- enumerated by somebody who may not read it.
    if not board.mayRead(session, call) then
        return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND)
    end

    local closed = CLOSED[call.status]
    if closed then
        return nil, route.refuse(FredPD.ErrorCode.CONFLICT, { [field or 'callId'] = closed })
    end

    return call, nil
end

--- May this session work a call it is not a unit on?
local function supervises(session)
    return perms.satisfies(session.permissions, SUPERVISE)
end

--- Turns a list of officer id strings into integers, or refuses.
---
--- The validator has no integer-list type, so `CallDispatch` sends ids as
--- strings and they are checked here rather than trusted -- the treatment
--- `LabRequestCreate` gets. Anything that is not a whole positive number fails
--- the whole dispatch: sending three of the four units a dispatcher selected,
--- silently, is worse than sending none and saying so.
---
--- An absent list is an empty list and not an error; all three of
--- `CallDispatch`'s lists are optional, because a dispatch may only be moving
--- the lead.
---
--- @return table|nil ids
--- @return table|nil refusal
local function officerIds(list, field)
    if list == nil then return {}, nil end
    if type(list) ~= 'table' then
        return nil, route.refuse(FredPD.ErrorCode.INVALID, { [field] = 'type' })
    end

    local ids, seen = {}, {}

    for index = 1, #list do
        local id = tonumber(list[index])

        if not id or id ~= math.floor(id) or id < 1 then
            return nil, route.refuse(FredPD.ErrorCode.INVALID, { [field] = 'not_integer' })
        end

        -- The same unit named twice would be one assignment and two log lines.
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end

    return ids, nil
end

--- Resolves a beat the caller named, or refuses.
---
--- A beat is a row, so naming one discloses nothing about where anybody is --
--- but it still has to be this agency's and still in use. `disabled` is held
--- apart from `unknown` because "there is no such beat" and "that district was
--- retired last week" are different mistakes, and the second is a dispatcher's
--- muscle memory rather than an attack.
---
--- The disabled ones are asked for precisely so the two can be told apart; the
--- set is small by design (0007 budgets the tagger against thirty districts).
---
--- @return table|nil refusal
local function checkBeat(session, beatId, field)
    if beatId == nil then return nil end

    local beats = repo.listBeats(session.agencyId, true)
    local key = field or 'beatId'

    for index = 1, #beats do
        if beats[index].id == beatId then
            if beats[index].enabled == 1 or beats[index].enabled == true then
                return nil
            end

            return route.refuse(FredPD.ErrorCode.INVALID, { [key] = 'disabled' })
        end
    end

    return route.refuse(FredPD.ErrorCode.INVALID, { [key] = 'unknown' })
end

--- The units still live on a call, in the shape the assignment writes take.
local function liveUnits(agencyId, callId)
    local rows = repo.callUnits(agencyId, callId)
    local live = {}

    for index = 1, #rows do
        if rows[index].active == 1 then
            live[#live + 1] = {
                officerId = rows[index].officerId,
                discordId = rows[index].discordId,
                callsign = rows[index].callsign,
            }
        end
    end

    return live
end

--- The unit board with the positions the server has just read laid over it.
---
--- The row's own `x`/`y` are the last position the AVL sweep persisted, which is
--- honest but can be ten seconds old, and older than that when nobody has had
--- the map open. `avl.livePositions` reads the peds now. Both are the server's;
--- neither has been through a client, which is the only property that matters
--- here (invariant 1).
---
--- @return table board rows, in the shape `service.recommendUnits` documents
local function boardWithPositions(agencyId, filter)
    local units = repo.listUnits(agencyId, filter)
    local live = avl.livePositions(agencyId)

    for index = 1, #units do
        local position = live[units[index].officerId]

        if position then
            units[index].x = position.x
            units[index].y = position.y
            units[index].z = position.z
            units[index].heading = position.heading
            units[index].positionAtUnix = position.at
        end
    end

    return units
end

--- Writes a `unit_status` line onto the call a unit is working, if any.
---
--- A status change made *off* a call is deliberately not recorded anywhere:
--- 0007 leaves `fpd_unit_status_log` out, because the shift-long activity report
--- it would serve is a personnel question (7.22, M6) and a required table nobody
--- writes to is worse than an honest gap. So this writes a line when there is a
--- call to write it to, and nothing when there is not -- and it tells the boards
--- and the open cards either way.
local function logUnitStatus(agencyId, subject, status, actor)
    local assignment = repo.activeAssignment(agencyId, subject.discordId)
    if not assignment then return nil end

    local entry = logLine(
        FredPD.CallLogKind.UNIT_STATUS,
        -- The *subject's* callsign, not the actor's: the line reads "3A-12: out
        -- of service", and who wrote it is the author columns beside it.
        { callsign = subject.callsign, status = status },
        nil,
        actor
    )

    if repo.addLog(agencyId, assignment.callId, entry) == 0 then return nil end

    local call = repo.getCall(agencyId, assignment.callId)

    board.callChanged(agencyId, call)
    logPushed(agencyId, call, entry)

    return assignment.callId
end

-- =============================================================================
-- Calls (7.16)
-- =============================================================================

route.define({
    name = 'call.create',
    perm = 'cad.call.create',
    schema = 'CallCreate',
    -- 7.16 intake, by hand, at the console (3.10). The condition fails closed
    -- when `placementId` is missing, and `CallCreate` declares the field, which
    -- is the only reason this route is reachable at all.
    context = { accessPoint = 'dispatch_console' },
    writes = true,
    audit = 'cad.call.created',
    subjectType = 'call',
    auditDetail = function(input, result)
        return {
            number = result and result.call and result.call.callNumber or nil,
            type = input.type,
            priority = input.priority,
        }
    end,
    handler = function(session, input)
        -- Trimmed before it is judged, not after.
        --
        -- `CallCreate` bounds `locationText` at one character and the validator
        -- counts the spaces, so three of them pass the schema, come back out of
        -- `text` as nil, and reach `ck_fpd_calls_where` -- which refuses the
        -- INSERT, which answers `internal`, which the dispatcher reads as
        -- "something went wrong" while losing the form they had typed. Every
        -- required free-text field in this file is trimmed first and refused
        -- with `required`, which the box can render under itself.
        local locationText = text(input.locationText)

        if locationText == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { locationText = 'required' })
        end

        local refusal = checkBeat(session, input.beatId)
        if refusal then return refusal end

        -- No position, and none is missing: a call taken over the phone happens
        -- where the *caller* says it does, and the dispatcher is at a desk.
        -- Taking the console's coordinates would file every phone call at the
        -- station and put a marker there for the map to send units to.
        local created = repo.createCall(session.agencyId, {
            type = input.type,
            priority = input.priority,
            locationText = locationText,
            beatId = input.beatId,
            callerName = text(input.callerName),
            callerPhone = text(input.callerPhone),
            source = 'dispatcher',
            -- What the caller said opens the narrative. It is content, so the
            -- repo puts it in `body` beside the generated line's own key -- the
            -- one row shape `ck_fpd_call_log_content` accepts for an entry that
            -- is not a note.
            details = text(input.details),
        }, actorOf(session))

        if not created then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        local call = repo.getCall(session.agencyId, created.id)

        board.callChanged(session.agencyId, call)

        -- Server-local, for the resources spec 14 says may listen. Never a
        -- client event: the payload names a record.
        TriggerEvent('fredpd:callCreated', {
            id = created.id,
            agencyId = session.agencyId,
            callNumber = created.callNumber,
            type = input.type,
            priority = input.priority,
        })

        return { id = created.id, call = call }
    end,
})

route.define({
    name = 'call.list',
    perm = READ,
    schema = 'CallList',
    -- The queue is the console's home screen and every MDT reads it coming on
    -- shift, so the ceiling is above the default. It is still a ceiling: the
    -- read is a range scan over `idx_fpd_calls_queue`, and a client in a loop
    -- would make it the most expensive query on the server.
    limit = { per = 60, window = 60 },
    handler = function(session, input)
        -- `mine` is a flag and never an officer id (invariant 1): the server
        -- fills in the session's own Discord id, so this cannot become a way to
        -- ask which calls somebody else is working.
        local calls = repo.listCalls(session.agencyId, {
            status = input.status,
            priority = input.priority,
            beatId = input.beatId,
            mineDiscordId = input.mine and session.discordId or nil,
            limit = input.limit or 100,
        })

        return { calls = board.readable(session, calls) }
    end,
})

route.define({
    name = 'call.get',
    perm = READ,
    schema = 'CallGet',
    limit = { per = 60, window = 60 },
    -- No declarative `audit`: this route audits the restricted case and only
    -- that, from the handler, because `route.define`'s entry has no condition to
    -- hang on. `subjectType` stays -- `audit.denied` still uses it for the
    -- refusal below, which is the read attempt worth keeping either way.
    subjectType = 'call',
    handler = function(session, input)
        local call = repo.getCall(session.agencyId, input.id)
        if not board.mayRead(session, call) then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        -- Invariant 11: *reads of restricted records* are audited. Not every
        -- read -- the console refetches this card on every `fredpd:cad:call`
        -- push, so auditing them all wrote dozens of rows for one P1 with four
        -- units on it, none of which was a read a person performed, and buried
        -- the entries this log exists to hold. `isRestricted` is the same
        -- generous test `accessRepo.read` applies: above `internal`, in a
        -- compartment, sealed, or classified as something nobody recognises.
        if accessRules.isRestricted(call) then
            audit.write({
                action = 'cad.call.read',
                discordId = session.discordId,
                agencyId = session.agencyId,
                subjectType = 'call',
                subjectId = tostring(input.id),
                -- What was opened and how far up the scale it sat. Never what
                -- was in it: an audit row that copies the record defeats the
                -- access control on the record.
                detail = { classification = call.classification },
            })
        end

        local log = repo.callLog(session.agencyId, input.id)

        for index = 1, #log do
            -- `message_args` is a JSON column and comes back as text.
            -- `Repo.listBeats` decodes its polygon in the repo and this belongs
            -- there too; until it moves, decoding here is what stops the card
            -- rendering `{"callsign":"3A-12"}` at a dispatcher.
            if type(log[index].messageArgs) == 'string' then
                log[index].messageArgs = json.decode(log[index].messageArgs)
            end
        end

        -- The closest available units (7.16), for the session that can send them
        -- and for nobody else. A call with no coordinates -- a phone call the
        -- caller could only describe -- has nothing to measure from, and no list
        -- is the honest answer rather than the whole board sorted by an invented
        -- distance.
        local recommended = nil

        if call.x and perms.satisfies(session.permissions, ASSIGNS) then
            -- The *unmasked* board goes in. `Cad.isFree` reads `onCallId`, so a
            -- board masked first would offer a unit standing at somebody else's
            -- shooting as available, and the dispatcher would send them. The
            -- ranking is the server reasoning about its own rows; only the
            -- answer leaves the server, and `divertFromCallId` is the one field
            -- in it that names a call (invariant 4; see the header).
            recommended = withoutDiverts(session, service.recommendUnits(
                boardWithPositions(session.agencyId, { limit = 200 }),
                { x = call.x, y = call.y },
                { callPriority = call.priority, config = settings }
            ))
        end

        return {
            id = input.id,
            call = call,
            units = repo.callUnits(session.agencyId, input.id),
            log = log,
            links = repo.callLinks(session.agencyId, input.id),
            recommended = recommended,
        }
    end,
})

route.define({
    name = 'call.dispatch',
    perm = 'cad.call.dispatch',
    schema = 'CallDispatch',
    -- Pinned like `call.create`: sending units is the other half of working the
    -- console. An officer who wants to take a call themselves uses
    -- `call.self_assign`, which is pinned to nothing and carries a different key.
    context = { accessPoint = 'dispatch_console' },
    writes = true,
    audit = 'cad.call.dispatched',
    subjectType = 'call',
    auditDetail = function(input, result)
        return {
            joined = result and result.joined or 0,
            left = result and result.left or 0,
            lead = input.leadOfficerId,
        }
    end,
    handler = function(session, input)
        local _, refusal = openCall(session, input.callId)
        if refusal then return refusal end

        -- Add and remove, never "here is the new set of units": a replacement
        -- set silently undoes a self-assignment made between the card loading
        -- and the dispatcher pressing send, and the log would then record the
        -- dispatcher removing a unit they never saw.
        local join, leave, lead
        join, refusal = officerIds(input.officerIds, 'officerIds')
        if refusal then return refusal end

        leave, refusal = officerIds(input.removeOfficerIds, 'removeOfficerIds')
        if refusal then return refusal end

        lead, refusal = officerIds(
            input.leadOfficerId and { input.leadOfficerId } or nil, 'leadOfficerId')
        if refusal then return refusal end

        lead = lead[1]

        if #join == 0 and #leave == 0 and lead == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { officerIds = 'nothing_to_change' })
        end

        -- Who is on the call now. The database is what actually decides -- two
        -- dispatchers pressing Dispatch at the same moment is what
        -- `uq_fpd_call_units_live` is for -- so this is here to produce a
        -- readable refusal, not to be the check.
        local assigned = {}
        local active = repo.callUnits(session.agencyId, input.callId)

        for index = 1, #active do
            if active[index].active == 1 then assigned[active[index].officerId] = true end
        end

        local joinUnits, leaveUnits, leadUnit = {}, {}, nil

        for index = 1, #join do
            -- One primary-key lookup per unit named, against this agency's
            -- board. An id that is not a unit here comes back nil and is refused
            -- as unknown -- never as another agency's callsign, which would be a
            -- way to enumerate one.
            local unit = repo.getUnit(session.agencyId, join[index])

            if not unit then
                return route.refuse(FredPD.ErrorCode.INVALID, { officerIds = 'unknown' })
            end

            local blocked = UNASSIGNABLE[unit.status]
            if blocked then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { officerIds = blocked })
            end

            if assigned[unit.officerId] then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { officerIds = 'already_assigned' })
            end

            joinUnits[#joinUnits + 1] = unit
            assigned[unit.officerId] = true
        end

        for index = 1, #leave do
            local unit = repo.getUnit(session.agencyId, leave[index])

            if not unit then
                return route.refuse(FredPD.ErrorCode.INVALID, { removeOfficerIds = 'unknown' })
            end

            if not assigned[unit.officerId] then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { removeOfficerIds = 'not_assigned' })
            end

            leaveUnits[#leaveUnits + 1] = unit
            assigned[unit.officerId] = nil
        end

        if lead then
            leadUnit = repo.getUnit(session.agencyId, lead)

            -- The lead has to be on the call *after* this dispatch is applied. A
            -- schema cannot say that, and `uq_fpd_call_units_lead` only
            -- guarantees there is never more than one live lead -- not that the
            -- unit named is on the call at all.
            if not leadUnit or not assigned[leadUnit.officerId] then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { leadOfficerId = 'not_assigned' })
            end
        end

        local actor = actorOf(session)

        -- The first unit on the call stamps `dispatched_at` and moves the status
        -- to `dispatched`, inside `assignUnits`' own transaction and with
        -- `COALESCE`, so re-dispatching to a second unit cannot move a timestamp
        -- a response-time report is arithmetic on (0007).
        if #joinUnits > 0 then
            if not repo.assignUnits(session.agencyId, input.callId, joinUnits, {
                assignedBy = session.discordId,
                actor = actor,
            }) then
                -- The unique key refused it: somebody was put on this call
                -- between the read above and the insert.
                return route.refuse(FredPD.ErrorCode.CONFLICT, { officerIds = 'already_assigned' })
            end
        end

        if #leaveUnits > 0
            and not repo.releaseUnits(session.agencyId, input.callId, leaveUnits, actor)
        then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { removeOfficerIds = 'not_assigned' })
        end

        if leadUnit and not repo.setLead(session.agencyId, input.callId, leadUnit, actor) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { leadOfficerId = 'not_assigned' })
        end

        -- Read back, every one of them, and not pushed as they were read at the
        -- top of this handler.
        --
        -- `joinUnits` and `leaveUnits` hold the rows `repo.getUnit` answered
        -- *before* the assignment was written, so their five `onCall*` columns
        -- are the JOIN as it stood a moment ago: the units just sent to this
        -- call carry whatever they were on before it -- usually nothing -- and
        -- the ones just released still carry this call. Pushing those is the
        -- board briefly contradicting the write that caused the push, which on a
        -- P1 with four units is four rows saying "available" while the card
        -- beside them lists all four as dispatched. The console then heals it on
        -- the next poll, seconds later, which is what made this look like a
        -- rendering flicker rather than a stale read.
        --
        -- One primary-key lookup per unit named in the dispatch, which is what
        -- every other write in this file already pays for its own row. A unit
        -- whose row cannot be read back is skipped rather than pushed stale --
        -- `unitChanged` treats nil as "invalidate the cache and say nothing",
        -- and the next board poll is the honest answer.
        for index = 1, #joinUnits do
            board.unitChanged(session.agencyId,
                repo.getUnit(session.agencyId, joinUnits[index].officerId))
        end

        for index = 1, #leaveUnits do
            board.unitChanged(session.agencyId,
                repo.getUnit(session.agencyId, leaveUnits[index].officerId))
        end

        board.callChanged(session.agencyId, repo.getCall(session.agencyId, input.callId))

        return { id = input.callId, joined = #joinUnits, left = #leaveUnits }
    end,
})

route.define({
    name = 'call.self_assign',
    perm = 'cad.call.self_assign',
    schema = 'CallSelfAssign',
    -- Not pinned, and naming no officer: which unit is attached comes from the
    -- session, so an officer cannot put somebody else on a call they do not
    -- want. That is the whole difference between this and `call.dispatch`, and
    -- it is why Appendix B gives them separate keys and gives this one to
    -- `patrol` and not to `dispatch`.
    --
    -- No `onDuty` context condition, deliberately. The duty test that matters
    -- here is the `fpd_units` row, which `ownUnit` below refuses when it is
    -- `off_duty` -- that row is what the board shows and what a dispatcher acts
    -- on. `conditions.onDuty` asks p_policejob instead and fails closed when it
    -- cannot answer (ADR-005), so adding it would refuse a self-assignment from
    -- a unit the dispatcher can see on the board because a bridge was not
    -- started.
    writes = true,
    audit = 'cad.call.self_assigned',
    subjectType = 'call',
    handler = function(session, input)
        local unit, refusal = ownUnit(session, 'callId')
        if refusal then return refusal end

        local call
        call, refusal = openCall(session, input.callId)
        if refusal then return refusal end

        if repo.isAssigned(session.agencyId, input.callId, session.discordId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { callId = 'already_assigned' })
        end

        -- A `unit_joined` row either way; `selfAssigned` is what makes the line
        -- read `cad.log.self_assigned` instead (7.16.1), because a unit that took
        -- a call and a unit that was sent to one are different facts and the log
        -- is read back to tell them apart.
        local committed = repo.assignUnits(session.agencyId, input.callId, { unit }, {
            assignedBy = session.discordId,
            selfAssigned = true,
            actor = actorOf(session, unit),
        })

        if not committed then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { callId = 'already_assigned' })
        end

        board.unitChanged(session.agencyId, repo.getUnit(session.agencyId, session.officerId))
        board.callChanged(session.agencyId, repo.getCall(session.agencyId, input.callId))

        return { id = input.callId, callNumber = call.callNumber }
    end,
})

route.define({
    name = 'call.status',
    -- `cad.unit.status`, not a key of its own: reporting that you are en route
    -- is your own unit's status moving, and Appendix B says so in as many words.
    -- It is held apart from `cad.call.dispatch` because the officer decides when
    -- they have arrived and the dispatcher does not.
    perm = 'cad.unit.status',
    schema = 'CallStatus',
    writes = true,
    audit = 'cad.call.progress',
    subjectType = 'call',
    auditDetail = function(input) return { status = input.status } end,
    handler = function(session, input)
        local unit, refusal = ownUnit(session, 'status')
        if refusal then return refusal end

        local _, callRefusal = openCall(session, input.callId)
        if callRefusal then return callRefusal end

        -- Progress is reported by the unit that is on the call. A supervisor who
        -- needs to move somebody else's status uses `unit.manage`: a different
        -- key, held by different people, logged against both names.
        if not repo.isAssigned(session.agencyId, input.callId, session.discordId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { callId = 'not_assigned' })
        end

        -- One write, three rows deep: the unit's status and `status_since`, the
        -- call's status and its stamp, and the log line. The call's timestamps
        -- are `COALESCE`d in the repo -- *first* unit en route, not latest --
        -- because a column that moves is a response-time report that changes its
        -- answer between two readings of the same call (0007).
        if not repo.reportProgress(session.agencyId, input.callId, input.status, unit) then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        board.unitChanged(session.agencyId, repo.getUnit(session.agencyId, session.officerId))
        board.callChanged(session.agencyId, repo.getCall(session.agencyId, input.callId))

        TriggerEvent('fredpd:unitStatusChanged', {
            agencyId = session.agencyId,
            officerId = session.officerId,
            callsign = unit.callsign,
            status = input.status,
            callId = input.callId,
        })

        return { id = input.callId, status = input.status }
    end,
})

route.define({
    name = 'call.clear',
    perm = 'cad.call.clear',
    schema = 'CallClear',
    writes = true,
    audit = 'cad.call.cleared',
    subjectType = 'call',
    auditDetail = function(input) return { disposition = input.disposition } end,
    handler = function(session, input)
        local call, refusal = openCall(session, input.callId)
        if refusal then return refusal end

        -- Clearing your own call is not clearing somebody else's. `patrol` holds
        -- `cad.call.clear` so a unit can close what they attended; closing a call
        -- nobody on it asked to close is supervisory, and `cad.unit.manage` is
        -- the key those three groups already hold.
        if not repo.isAssigned(session.agencyId, input.callId, session.discordId)
            and not supervises(session)
        then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { callId = 'not_assigned' })
        end

        -- 7.16: an emergency call "cannot be cleared without supervisor
        -- acknowledgement". `ck_fpd_calls_panic_ack` enforces it in the database
        -- and the repo's WHERE closes the race; refusing here is what turns an
        -- `internal` error into something the card can read out
        -- (`cad.clear.needsAcknowledgement`). Cancelling is refused by the same
        -- CHECK for the same reason -- otherwise the way to clear an
        -- unacknowledged panic call would be to cancel it -- which is why this
        -- test is on the call and not on the disposition.
        if call.source == EMERGENCY.source and not call.acknowledgedAt then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { callId = 'needs_acknowledgement' })
        end

        -- `duplicate` and `cancelled` close the call as `cancelled`; everything
        -- else closes it as `cleared`, and 7.16.1 pairs the log line with the
        -- same two. `service.closureFor` owns that mapping, so the status, the
        -- line and the label can never disagree about which of the two happened.
        local status = service.closureFor(input.disposition)

        repo.clearCall(session.agencyId, input.callId, {
            status = status,
            disposition = input.disposition,
            note = text(input.note),
        }, liveUnits(session.agencyId, input.callId), actorOf(session))

        -- The transaction reports only that it committed, and its UPDATE matches
        -- no rows if somebody closed the call between the read above and the
        -- write. So the call is read back: this is a conflict rather than a
        -- quiet success, or the second officer would believe they closed it.
        local after = repo.getCall(session.agencyId, input.callId)

        if not after or not CLOSED[after.status] then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { callId = 'call_cleared' })
        end

        -- Every unit on the call came free, so the board the AVL sweep caches is
        -- now wrong.
        avl.invalidate(session.agencyId)
        board.callChanged(session.agencyId, after)

        return { id = input.callId, disposition = input.disposition, status = after.status }
    end,
})

route.define({
    name = 'call.acknowledge',
    -- Appendix B is explicit: the acknowledgement rides on `cad.unit.manage`
    -- rather than a key of its own, because the groups that hold it --
    -- supervisor, command, dispatch -- are exactly the ones who may give it.
    perm = SUPERVISE,
    schema = 'CallAcknowledge',
    writes = true,
    audit = 'cad.call.acknowledged',
    subjectType = 'call',
    handler = function(session, input)
        local call, refusal = openCall(session, input.callId)
        if refusal then return refusal end

        -- Only an emergency call has anything to acknowledge. Anything else is a
        -- supervisor pressing a button that writes two columns nothing reads, so
        -- it is refused rather than silently accepted.
        if call.source ~= EMERGENCY.source then
            return route.refuse(FredPD.ErrorCode.INVALID, { callId = 'not_supported' })
        end

        -- The one thing 7.16 is asking to be impossible: the person in distress
        -- signing off their own emergency. The schema keeps the flag off
        -- `CallClear` for this reason; this keeps it off the acknowledgement.
        -- `created_by` is the officer who pressed the button, written by the
        -- server from their session -- a fact, not a claim.
        if call.createdBy == session.discordId then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { callId = 'not_allowed' })
        end

        local unit = repo.getUnit(session.agencyId, session.officerId)

        -- Zero rows means it was already acknowledged: `acknowledged_at IS NULL`
        -- is in the repo's WHERE, so who acknowledged an officer's emergency is
        -- not a field a second press rewrites.
        if repo.acknowledgeCall(session.agencyId, input.callId, actorOf(session, unit)) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { callId = 'nothing_to_change' })
        end

        board.callChanged(session.agencyId, repo.getCall(session.agencyId, input.callId))

        return { id = input.callId }
    end,
})

route.define({
    name = 'call.note',
    perm = 'cad.call.note',
    schema = 'CallNote',
    writes = true,
    audit = 'cad.call.noted',
    subjectType = 'call',
    handler = function(session, input)
        local call, refusal = openCall(session, input.callId)
        if refusal then return refusal end

        -- A note is the one line a person writes, so it is content and is stored
        -- untranslated. The kind is not a field on the schema and is not taken
        -- from input here either: this route writes a `note`, and the server
        -- writes every other kind from what it has just done -- a line a client
        -- could label is a line a client can dress up as a status change that
        -- never happened (invariant 11).
        -- Trimmed before it is judged, like `call.create`'s location. `CallNote`
        -- bounds the body at one character and the validator counts the spaces,
        -- and `ck_fpd_call_log_content` only asks a note for a body that is not
        -- NULL -- so three spaces stored cleanly as a blank line in a log that
        -- is append-only and cannot have it taken back out.
        local body = text(input.body)

        if body == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { body = 'required' })
        end

        local unit = repo.getUnit(session.agencyId, session.officerId)
        local actor = actorOf(session, unit)
        local entry = logLine(FredPD.CallLogKind.NOTE, nil, body, actor)

        if repo.addLog(session.agencyId, input.callId, entry) == 0 then
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        -- Both events, like every other write that touches a call: the card
        -- refresh, and the line itself so an open narrative can append it
        -- without refetching. Both go only to the sessions that may read this
        -- call, because a push is a read nobody asked for (invariants 4 and 5).
        board.callChanged(session.agencyId, call)
        logPushed(session.agencyId, call, entry)

        return { id = input.callId }
    end,
})

route.define({
    name = 'call.link',
    perm = 'cad.call.link',
    schema = 'CallLink',
    writes = true,
    audit = 'cad.call.linked',
    subjectType = 'call',
    auditDetail = function(input)
        return { kind = input.kind, targetId = input.targetId, remove = input.remove == true }
    end,
    handler = function(session, input)
        local _, refusal = openCall(session, input.callId)
        if refusal then return refusal end

        -- `fpd_call_links` carries no foreign key to the record -- 0007 explains
        -- why a polymorphic link cannot have one -- so the two things the
        -- database cannot check are checked here: that the target is this
        -- agency's, and that this session may read it at all.
        local target = repo.linkTarget(session.agencyId, input.kind, input.targetId)

        if target then
            -- `linkTarget` selects the control columns and not the id, and
            -- `Repo.read` audits and shapes by `row.id`.
            target.id = input.targetId
        end

        -- The same access check the register itself runs, through the same
        -- function (invariant 4): a person an officer may not open must not
        -- become readable by being linked to a call, and a refusal must not
        -- distinguish "you may not see it" from "it is not there" -- which is
        -- why both answers are one code.
        if not target or not accessRepo.read(session, input.kind, target) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { targetId = 'unknown' })
        end

        -- Recorded as it was read out over the radio, so the row survives the
        -- record being expunged. An orphaned link grants nobody anything, and
        -- the label is what keeps it readable (0007).
        local link = {
            targetType = input.kind,
            targetId = input.targetId,
            role = input.role or 'involved',
            label = target.label,
        }

        local actor = actorOf(session)

        if input.remove then
            -- Checked first so that removing a link that is not there is a
            -- refusal rather than an `unlinked` line about nothing: the log is
            -- append-only, so a line written in error stays for good.
            local links = repo.callLinks(session.agencyId, input.callId)
            local found = false

            for index = 1, #links do
                if links[index].targetType == input.kind
                    and links[index].targetId == input.targetId
                then
                    found = true
                    break
                end
            end

            if not found then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND, { targetId = 'unknown' })
            end

            if not repo.removeLink(session.agencyId, input.callId, link, actor) then
                return route.refuse(FredPD.ErrorCode.INTERNAL)
            end
        elseif not repo.setLink(session.agencyId, input.callId, link, actor) then
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        board.callChanged(session.agencyId, repo.getCall(session.agencyId, input.callId))

        return { id = input.callId }
    end,
})

-- =============================================================================
-- The unit board (7.1, 7.16)
-- =============================================================================

route.define({
    name = 'unit.list',
    perm = READ,
    schema = 'UnitList',
    limit = { per = 60, window = 60 },
    handler = function(session, input)
        -- Positions are laid over the rows for the same reason the card's
        -- recommendation gets them: the board shows where a unit is, and the
        -- stored column is only as fresh as the last sweep.
        --
        -- `board.boardFor` is the access check on the call each row carries, and it is
        -- not optional decoration on a read gated by the page key: without it
        -- this route answers with the number, the priority and the stage of
        -- every call on the board, including the ones `call.list` refused this
        -- same session a second earlier (invariant 4; see the header).
        local units = boardWithPositions(session.agencyId, {
            status = input.status,
            beatId = input.beatId,
            limit = input.limit or 100,
        })

        return { units = board.boardFor(session, units) }
    end,
})

route.define({
    name = 'unit.status',
    perm = 'cad.unit.status',
    schema = 'UnitStatus',
    -- Not pinned and naming no officer: the row is the session's own. Appendix
    -- F's `ST` is typed in the car, and `patrol_basic` holds this key so the
    -- aspirant in the passenger seat can say where they are.
    writes = true,
    audit = 'cad.unit.status',
    subjectType = 'unit',
    auditDetail = function(input) return { status = input.status } end,
    handler = function(session, input)
        local unit, refusal = ownUnit(session, 'status')
        if refusal then return refusal end

        -- `off_duty` and `emergency` are not on `SELF_SET_UNIT_STATUSES`, so the
        -- validator has already refused them before this runs: signing off is the
        -- duty path, and the emergency belongs to `unit.emergency`, which raises
        -- a call as well as a status. Nothing here has to remember that, which is
        -- the point of putting the restriction in the schema.
        --
        -- Zero rows is the repo's `status <> ?`: the status is already what was
        -- asked for, and `status_since` must not be restamped for it, or the
        -- welfare timer resets every time a bored officer presses the same key.
        if repo.setUnitStatus(session.agencyId, session.officerId, input.status) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { status = 'nothing_to_change' })
        end

        -- If the unit is working a call, the change is a line on that call's
        -- narrative and the card is told. If it is not, there is nowhere to
        -- write it and nothing is written (see `logUnitStatus`).
        local callId = logUnitStatus(session.agencyId, unit, input.status, actorOf(session, unit))

        board.unitChanged(session.agencyId, repo.getUnit(session.agencyId, session.officerId))

        TriggerEvent('fredpd:unitStatusChanged', {
            agencyId = session.agencyId,
            officerId = session.officerId,
            callsign = unit.callsign,
            status = input.status,
            callId = callId,
        })

        return { id = session.officerId, status = input.status }
    end,
})

route.define({
    name = 'unit.manage',
    perm = SUPERVISE,
    schema = 'UnitManage',
    -- Deliberately not pinned: a field supervisor (Appendix A, *yttre befäl*)
    -- does this from the MDT, and pinning it to the console would refuse every
    -- call they make. The permission is what limits it -- invariant 2 doing its
    -- job rather than geography standing in for it.
    writes = true,
    audit = 'cad.unit.managed',
    subjectType = 'unit',
    auditDetail = function(input)
        return {
            officerId = input.officerId,
            status = input.status,
            callsign = input.callsign,
            beatId = input.beatId,
            reason = input.reason,
        }
    end,
    handler = function(session, input)
        -- The subject, never the actor (the schema preamble): the officer id
        -- names the unit being changed, and the session signs the log line and
        -- the audit row.
        local unit = repo.getUnit(session.agencyId, input.officerId)

        -- Another agency's unit is `not_found`, not `forbidden`: which callsigns
        -- the sheriff has on the board is not a city supervisor's business, and a
        -- refusal that told the two apart is how that gets enumerated.
        if not unit then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { officerId = 'unknown' })
        end

        local refusal = checkBeat(session, input.beatId)
        if refusal then return refusal end

        if input.status == nil and input.callsign == nil and input.beatId == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { status = 'nothing_to_change' })
        end

        -- The two changes that read as discipline afterwards need a reason, and
        -- the schema cannot say "required unless". Taking a unit off the road or
        -- signing somebody else off is what an audit entry has to explain months
        -- later; correcting a callsign at briefing needs no essay.
        if (input.status == FredPD.UnitStatus.OUT_OF_SERVICE
                or input.status == FredPD.UnitStatus.OFF_DUTY)
            and text(input.reason) == nil
        then
            return route.refuse(FredPD.ErrorCode.INVALID, { reason = 'required' })
        end

        local callsign = text(input.callsign)
        local changed = repo.updateUnit(session.agencyId, input.officerId, {
            callsign = callsign,
            beatId = input.beatId,
        })

        if input.status then
            -- Status goes through its own statement, because that is the one
            -- place `status_since` is stamped -- a second path that set the
            -- status without the stamp is how the board's time-in-status column
            -- quietly starts lying.
            changed = changed + repo.setUnitStatus(
                session.agencyId, input.officerId, input.status)
        end

        if changed == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { officerId = 'nothing_to_change' })
        end

        -- The line goes on whatever call the subject is working, signed by the
        -- supervisor and naming the unit; a unit that is on nothing has nowhere
        -- to record it (see `logUnitStatus`).
        if input.status then
            logUnitStatus(session.agencyId, {
                discordId = unit.discordId,
                callsign = callsign or unit.callsign,
            }, input.status, actorOf(session))
        end

        board.unitChanged(session.agencyId, repo.getUnit(session.agencyId, input.officerId))

        if input.status then
            TriggerEvent('fredpd:unitStatusChanged', {
                agencyId = session.agencyId,
                officerId = input.officerId,
                callsign = callsign or unit.callsign,
                status = input.status,
            })
        end

        return { id = input.officerId }
    end,
})

-- =============================================================================
-- The emergency button (7.16)
-- =============================================================================

route.define({
    name = 'unit.emergency',
    perm = 'cad.emergency',
    schema = 'Emergency',
    -- Deliberately *not* `writes = true`, and this is the only route in the
    -- suite that says so.
    --
    -- Spec 4.2's read-only tier exists so a Discord outage cannot leave officers
    -- authoring records against role data nobody can vouch for, and it degrades
    -- toward less access. This is the one write where less access points the
    -- wrong way: refusing it means an officer in distress cannot ask for help
    -- because a Node service is down. What the call asserts is not a judgement
    -- about a record -- it is "I am here and I need units" -- raised by a session
    -- whose officer row was read out of this database, at a position the server
    -- read off their own ped. The permission check still runs, the call is
    -- attributed, and a dispatcher can cancel one raised in error. Nothing else
    -- on this list is exempt, and a second exemption needs the argument made
    -- again rather than a reference to this one.
    --
    -- The limit is tighter than the default but not tight: a button that refuses
    -- the second press because the first seemed not to work is a button that
    -- failed on the only shift it was needed.
    limit = { per = 5, window = 60 },
    audit = 'cad.emergency.raised',
    subjectType = 'call',
    handler = function(session)
        local unit, refusal = ownUnit(session, 'status')
        if refusal then return refusal end

        -- The position, from the server's own copy of where this player is.
        -- `Emergency` has no field for one and must never grow one: a client that
        -- could send a position could put a fake officer down on the far side of
        -- the map and empty a district (invariant 1).
        local ped = GetPlayerPed(session.src)
        if ped == 0 then return route.refuse(FredPD.ErrorCode.CONTEXT) end

        local at = GetEntityCoords(ped)
        local actor = actorOf(session, unit)

        -- Tagged with its beat from that position, the same way a call raised by
        -- an export is (7.17). The polygon test is pure and lives in the service,
        -- so it runs before the row exists and busted can see it.
        local beat = service.beatFor(repo.listBeats(session.agencyId), at.x, at.y)

        local created = repo.createCall(session.agencyId, {
            type = EMERGENCY.type,
            priority = EMERGENCY.priority,
            source = EMERGENCY.source,
            x = at.x,
            y = at.y,
            z = at.z,
            beatId = beat and beat.id or nil,
        }, actor)

        if not created then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        -- The officer goes on their own call and their unit status becomes
        -- `emergency`. Three writes rather than one transaction, because that is
        -- the repo's shape -- and the order is chosen so that every way this can
        -- stop short leaves something a dispatcher can act on: the call exists
        -- first, then somebody is on it, then the board says why. A P1 with
        -- nobody attached is still a P1 on the queue; the reverse would be a unit
        -- flagged in distress with no call to send anyone to.
        repo.assignUnits(session.agencyId, created.id, { unit }, {
            assignedBy = session.discordId,
            selfAssigned = true,
            actor = actor,
        })

        repo.setLead(session.agencyId, created.id, unit, actor)

        if repo.setUnitStatus(
            session.agencyId, session.officerId, FredPD.UnitStatus.EMERGENCY) > 0
        then
            repo.addLog(session.agencyId, created.id, logLine(
                FredPD.CallLogKind.UNIT_STATUS,
                { callsign = unit.callsign, status = FredPD.UnitStatus.EMERGENCY },
                nil,
                actor
            ))
        end

        local call = repo.getCall(session.agencyId, created.id)

        board.unitChanged(session.agencyId, repo.getUnit(session.agencyId, session.officerId))

        -- The queue entry goes out like any other call: it is a P1 on the board
        -- and everyone who may read the queue has to see it, whatever their
        -- distance. What is narrow is the *tone* below, which is what 7.16
        -- restricts -- not the existence of the call.
        board.callChanged(session.agencyId, call)

        -- 7.16: "tone for all dispatchers and units in range", and for nobody
        -- else (invariant 5). Range is measured against each recipient's own ped
        -- on the server; a session whose ped has not spawned is out of range
        -- rather than in it, because an unknown position is not a nearby one.
        --
        -- Through `board.toDispatch` like every other push here, so the page key
        -- and the agency test are the ones `board.lua` applies and this filter
        -- is only the part that is peculiar to an emergency. The access check on
        -- the call it carries is not peculiar and is made all the same: the tone
        -- names the call.
        board.toDispatch(session.agencyId, 'fredpd:cad:emergency', {
            call = call,
            callsign = unit.callsign,
        }, function(other)
            if not board.mayRead(other, call) then return false end

            if perms.satisfies(other.permissions, SUPERVISE)
                or perms.satisfies(other.permissions, ASSIGNS)
            then
                return true
            end

            local otherPed = GetPlayerPed(other.src)
            if otherPed == 0 then return false end

            local there = GetEntityCoords(otherPed)
            local dx, dy = there.x - at.x, there.y - at.y

            return (dx * dx + dy * dy) <= (EMERGENCY_RANGE * EMERGENCY_RANGE)
        end)

        TriggerEvent('fredpd:emergency', {
            agencyId = session.agencyId,
            officerId = session.officerId,
            callsign = unit.callsign,
            callId = created.id,
        })

        return { id = created.id, call = call }
    end,
})

-- =============================================================================
-- Broadcasts (7.16 [S], 7.26)
-- =============================================================================

route.define({
    name = 'broadcast.create',
    perm = 'cad.broadcast',
    schema = 'BroadcastCreate',
    writes = true,
    audit = 'cad.broadcast.created',
    subjectType = 'broadcast',
    auditDetail = function(input)
        return { kind = input.kind, plate = input.plate, priority = input.priority }
    end,
    handler = function(session, input)
        -- Trimmed before it is judged, like `call.create`'s location. Both
        -- columns are NOT NULL and `ck_fpd_broadcasts_body` wants a body with
        -- something in it, so a title or a message of spaces passes the schema's
        -- `min = 1`, comes out of `text` as nil, and is refused by the database
        -- as `internal` -- with the BOLO the supervisor had just typed gone.
        local title, body = text(input.title), text(input.body)

        if title == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { title = 'required' })
        end

        if body == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { body = 'required' })
        end

        local broadcast = {
            kind = input.kind,
            priority = input.priority or 3,
            title = title,
            body = body,
            -- Upper-cased and trimmed, like every other plate column in the
            -- suite. It puts the plate on the message and does nothing else:
            -- making an ALPR banner fire on it is a hotlist entry under its own
            -- key, because a plate worth stopping a car over is a decision with
            -- its own permission (7.18).
            plate = plate(input.plate),
            -- Minutes on the database's clock, never a date from the call: an
            -- absolute time would be a client-supplied timestamp (invariant 1).
            -- Absent takes the configured default rather than "no expiry" -- a
            -- board nobody clears is what that default exists to prevent.
            minutes = input.expiresInMinutes or settings.broadcastMinutes,
        }

        local id = repo.createBroadcast(session.agencyId, broadcast, session.discordId)
        if not id then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        broadcast.id = id

        -- What was just written, without `createdAt` or `expiresAt`: the insert
        -- does not report them. The board has the id and refetches when it wants
        -- the expiry; this is enough to put the message on the air now.
        board.toDispatch(session.agencyId, 'fredpd:cad:broadcast', { broadcast = broadcast })

        return { id = id, broadcast = broadcast }
    end,
})

route.define({
    name = 'broadcast.cancel',
    perm = 'cad.broadcast',
    schema = 'BroadcastCancel',
    writes = true,
    audit = 'cad.broadcast.cancelled',
    subjectType = 'broadcast',
    handler = function(session, input)
        -- Nothing is deleted: `cancelled_at` and `cancelled_by` are stamped and
        -- the row stays, so "what was out on the air at the time" survives the
        -- shift it was asked about (0007). Zero rows is one that was already off
        -- the air, or one from another agency -- neither of which this session
        -- takes down, and neither of which it is told apart.
        -- `not`, not `== 0`: this repo function answers a BOOLEAN, and in Lua
        -- `false == 0` is false, so the refusal below was unreachable and a
        -- cancel of somebody else's broadcast answered success.
        if not repo.cancelBroadcast(session.agencyId, input.id, session.discordId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        board.toDispatch(session.agencyId, 'fredpd:cad:broadcast', { cancelledId = input.id })

        return { id = input.id }
    end,
})

route.define({
    name = 'broadcast.list',
    perm = READ,
    schema = 'BroadcastList',
    limit = { per = 60, window = 60 },
    handler = function(session, input)
        return {
            broadcasts = repo.listBroadcasts(session.agencyId, {
                includeExpired = input.includeExpired == true,
                kind = input.kind,
                callId = input.callId,
                limit = input.limit or 100,
            }),
        }
    end,
})

-- =============================================================================
-- Beats and the map (7.17)
-- =============================================================================

route.define({
    name = 'beat.list',
    perm = READ,
    schema = 'BeatList',
    limit = { per = 30, window = 60 },
    handler = function(session)
        -- Polygons come back; no position goes out. Asking for the beat map says
        -- nothing about where the asker is standing, which is why this is a read
        -- on the page key rather than a pinned route.
        --
        -- Disabled beats are left out: a beat taken out of use is not drawn and
        -- not offered, and `fpd_beats.enabled` is how that happens without
        -- deleting the row -- `fpd_calls.beat_id` is `ON DELETE SET NULL`, so a
        -- delete would quietly untag every call the beat had ever held.
        return { beats = repo.listBeats(session.agencyId) }
    end,
})

route.define({
    name = 'map.view',
    perm = READ,
    schema = 'MapView',
    limit = { per = 20, window = 60 },
    handler = function(session, input)
        -- The close half is a field rather than a second route, so there is one
        -- place the subscription is written.
        if input.subscribe == false then
            avl.unsubscribe(session.src)
            return { subscribed = false }
        end

        -- 3.6 pushes AVL only to sessions with the map open, and this is where
        -- "open" is recorded. Budget 12.1 is why it matters at two hundred
        -- players: with nobody subscribed, the sweep costs one table lookup a
        -- second for the whole server.
        avl.subscribe(session)

        -- Both arrays are filtered against the same reader, and they have to
        -- be: a call dropped from `calls` and left standing on a unit row in
        -- `units` is the same disclosure made twice as quietly (invariant 4;
        -- see the header).
        return {
            subscribed = true,
            units = board.boardFor(session, boardWithPositions(session.agencyId, { limit = 200 })),
            calls = board.readable(session, repo.listCalls(session.agencyId, { limit = 200 })),
        }
    end,
})

-- =============================================================================
-- ALPR (7.18)
-- =============================================================================

--- May this session be shown a silent hotlist entry?
---
--- A silent entry is a surveillance target (7.18, and section 9): the read is
--- logged and the hit is recorded against the entry, and the unit is told
--- nothing -- a banner would tell a corrupt officer they are being watched, and
--- the officer is sometimes the subject.
---
--- The rule is the narrowest one that still lets an entry be reviewed and taken
--- off: the session that created it. `alpr.hotlist.manage` is held by supervisor,
--- command and dispatch, so making the flag visible to the key would put covert
--- entries in front of most of the department, and no key in Appendix B means
--- "may review covert watches". Until one exists this is the safe direction, and
--- the milestone report asks for the decision rather than assuming it.
local function seesSilent(session, entry)
    return entry.createdBy ~= nil and entry.createdBy == session.discordId
end

route.define({
    name = 'alpr.read.list',
    perm = 'alpr.read.view',
    schema = 'AlprReadList',
    limit = { per = 30, window = 60 },
    audit = 'alpr.reads.viewed',
    auditDetail = function(input, result)
        return { plate = input.plate, officerId = input.officerId, count = #result.reads }
    end,
    handler = function(session, input)
        -- `hitsOnly` decides what a masked row can be, so it is read once here
        -- and used twice below.
        local hitsOnly = input.hitsOnly == true

        local rows = repo.listReads(session.agencyId, {
            plate = plate(input.plate),
            officerId = input.officerId,
            sinceHours = input.sinceHours or 24,
            hitsOnly = hitsOnly,
            limit = input.limit or 100,
        })

        local out = {}

        for index = 1, #rows do
            local row = rows[index]

            -- `listReads` LEFT JOINs the entry, so `silent` and its author
            -- arrive on the read itself and the decision is made per row. The
            -- read it replaced asked `listHotlist` for a thousand entries and
            -- built a set of ids from them, which masked nothing at all for a
            -- silent entry that happened to sort past row one thousand -- a
            -- covert watch whose disclosure depended on how busy the hotlist
            -- was. There is no page to outrun here and no second query.
            local covert = row.silent == 1
                and not seesSilent(session, { createdBy = row.hotlistCreatedBy })

            -- **The response is built, never redacted.** Clearing two fields off
            -- the repo row left `silent`, `hotlistReason` and `hotlistCreatedBy`
            -- standing on it: a patrol officer who may not know the plate is
            -- watched was told that it is, why, and the Discord id of who is
            -- watching it -- which on a `sources` or an internal-affairs watch
            -- is the officer being investigated reading their own surveillance.
            -- Naming the fields that go out is what stops the next column joined
            -- onto that SELECT arriving here on its own.
            local read = {
                id = row.id,
                plate = row.plate,
                readAt = row.readAt,
                readAtUnix = row.readAtUnix,
                x = row.x,
                y = row.y,
                z = row.z,
                officerId = row.officerId,
                discordId = row.discordId,
                callsign = row.callsign,
                camera = row.camera,
                -- The read itself is not the secret -- a camera saw a car -- but
                -- that the car is flagged is exactly what a covert watch exists
                -- not to disclose. So the hit comes off and the read stays:
                -- dropping the row would leave a hole in the movement history
                -- that a second reader could difference against.
                hit = covert and 0 or row.hit,
                hotlistId = (not covert) and row.hotlistId or nil,
                -- Why the banner fired, which is the reason's key and never a
                -- sentence (7.18: the NUI renders `alpr.reason.<value>`). Off a
                -- covert row with the hit it belongs to. Who wrote the entry is
                -- never on this route at all: `alpr.read.view` asks which cars
                -- drove past a camera, and who is watching a plate is the
                -- hotlist's own question under its own key.
                hotlistReason = (not covert) and row.hotlistReason or nil,
            }

            -- A masked row cannot stay in a list that asked for hits only. Every
            -- row in that answer is a hit by construction, so one reading `hit =
            -- 0` announces itself as the one the reader was not allowed to see.
            -- Absent is the same answer the unfiltered list gives, where the
            -- row is indistinguishable from a plate that matched nothing.
            if not (covert and hitsOnly) then out[#out + 1] = read end
        end

        return { reads = out }
    end,
})

route.define({
    name = 'alpr.hotlist.edit',
    perm = 'alpr.hotlist.manage',
    schema = 'AlprHotlistEdit',
    writes = true,
    -- Putting a plate on the hotlist puts a red banner in front of an officer
    -- about to stop a car, and a silent entry is a surveillance decision under
    -- section 9. Both are the kind of write 4.2 refuses on a stale permission
    -- snapshot, because who may make them is precisely what the snapshot says.
    sensitive = true,
    audit = 'alpr.hotlist.edited',
    subjectType = 'hotlist',
    auditDetail = function(input)
        return {
            plate = input.plate,
            reason = input.reason,
            remove = input.remove == true,
            silent = input.silent == true,
            caseNumber = input.caseNumber,
        }
    end,
    handler = function(session, input)
        local wanted = plate(input.plate)

        if not wanted then
            return route.refuse(FredPD.ErrorCode.INVALID, { plate = 'required' })
        end

        if input.remove then
            -- A removal naming a reason takes that entry; one that does not takes
            -- every live entry for the plate, because `uq_fpd_hotlist_live` is
            -- per reason and a plate can be listed twice.
            --
            -- It never takes a silent entry this session may not see, and never
            -- counts one: a count that included it would disclose the covert
            -- watch to the supervisor tidying the board, and taking it off would
            -- end a surveillance nobody meant to end.
            local entries = repo.listHotlist(session.agencyId,
                { plate = wanted, reason = input.reason, limit = 100 })
            local removed = 0

            for index = 1, #entries do
                local entry = entries[index]

                if entry.silent ~= 1 or seesSilent(session, entry) then
                    removed = removed + repo.cancelHotlist(
                        session.agencyId, wanted, entry.reason, session.discordId)
                end
            end

            if removed == 0 then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND, { plate = 'unknown' })
            end

            return { plate = wanted, removed = removed }
        end

        -- Required by the handler and not by the schema, because a removal has
        -- nothing to justify and the validator cannot express "required unless".
        -- A banner with no reason behind it is a reason to stop a car that nobody
        -- can account for afterwards.
        if input.reason == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { reason = 'required' })
        end

        local written = repo.addHotlist(session.agencyId, {
            plate = wanted,
            reason = input.reason,
            detail = text(input.note),
            caseNumber = text(input.caseNumber),
            silent = input.silent == true,
            minutes = input.expiresInMinutes,
        }, session.discordId)

        if written == 0 then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        return { plate = wanted, reason = input.reason }
    end,
})

route.define({
    name = 'alpr.hotlist.list',
    -- Read with `alpr.hotlist.manage` rather than `alpr.read.view`: the reads
    -- file says which cars drove past a camera, and this says which cars an
    -- officer will be stopped from driving away in (7.18).
    perm = 'alpr.hotlist.manage',
    schema = 'AlprHotlistList',
    limit = { per = 30, window = 60 },
    handler = function(session, input)
        local rows = repo.listHotlist(session.agencyId, {
            plate = plate(input.plate),
            reason = input.reason,
            includeExpired = input.includeExpired == true,
            limit = input.limit or 100,
        })

        local out = {}

        for index = 1, #rows do
            -- There is deliberately no `silent` filter on the schema to ask for
            -- these by, and they are not part of this read: the whole point is
            -- that the subject learns nothing, and the subject is sometimes an
            -- officer with a login.
            if rows[index].silent ~= 1 or seesSilent(session, rows[index]) then
                out[#out + 1] = rows[index]
            end
        end

        return { entries = out }
    end,
})

-- =============================================================================
-- `CreateCall(data)` -- the integration export (spec 14, 11.2)
-- =============================================================================

--- How often one resource may raise a call.
---
--- Per calling resource, because there is no player behind this to limit. An
--- alarm script with a bug in its loop would otherwise fill the queue with a
--- thousand P1s and bury the real one, and a dispatcher has no way to tell which
--- is which. Twenty a minute is a busy night of store alarms and nothing like a
--- loop.
local EXPORT_LIMIT <const> = { per = 20, window = 60 }

--- Bounds on the free text an outside resource may write into a call.
---
--- The column widths from 0007 and not one character more. This input never
--- meets `FredPD.Core.validate` -- that runs inside the route wrapper and this is
--- not a route -- so everything below does by hand what the validator would have
--- done. The widths have to be exact: a string longer than the column is a failed
--- INSERT under strict mode, which the alarm script's author reads as "FredPD is
--- broken" rather than as their own bug.
local EXPORT_MAX <const> = {
    locationText = 191,
    callerName = 191,
    callerPhone = 32,
    details = 1000,
}

--- A trimmed string cut to a column width, or nil.
local function boundedText(value, max)
    local trimmed = text(value)
    if trimmed == nil then return nil end

    if #trimmed > max then return trimmed:sub(1, max) end

    return trimmed
end

--- A finite number, or nil.
---
--- NaN and infinity are numbers in Lua, are not coordinates, and would be stored
--- as a marker nobody can drive to -- and NaN compares false against itself, so
--- every distance test downstream would quietly exclude the call.
local function finite(value)
    if type(value) ~= 'number' then return nil end
    if value ~= value then return nil end
    if value == math.huge or value == -math.huge then return nil end

    return value + 0.0
end

--- Raises a call from another resource (spec 14: "alerts from robberies, shots
--- fired, alarms"; the export list in 11.2).
---
--- **Everything reaching this function is hostile input.** There is no session,
--- no officer and no permission behind it -- an alarm script is not an officer --
--- and it is called by resources this project does not control and cannot
--- review. So nothing is trusted: not the call number (allocated from
--- `fpd_counters` under a row lock like every other number in the suite, 13.1),
--- not the time, not the author, and not the agency unless it names one that
--- exists. A field that is wrong is corrected or dropped.
---
--- It never raises into its caller and never returns anything shaped like a call
--- when it refused: a store robbery script that dies half way through leaves a
--- till open and a player stuck in an animation, and that would be FredPD's
--- fault.
---
--- @param data table
---   type          string|nil  a `FredPD.CallType`; anything else becomes `other`
---   priority      number|nil  1-4, clamped; default 3
---   locationText  string|nil  where, in words
---   x, y, z       number|nil  where, as coordinates -- all three or none
---   callerName    string|nil
---   callerPhone   string|nil
---   details       string|nil  the opening line of the narrative
---   agencyId      string|nil  defaults to the configured agency
--- @return table|nil { id, callNumber }, or nil when the call was refused
--- @return string|nil why: 'invalid', 'rate_limited', 'unknown_agency', 'failed'
local function createCall(data)
    -- Which resource is asking. It feeds the limiter and
    -- `fpd_calls.source_resource`, which is the audit trail 0007 asks for.
    --
    -- `unknown` is a real answer -- a call raised from a server console, say --
    -- and is limited as one bucket like any other name.
    local resource = GetInvokingResource() or 'unknown'

    -- The limiter keyed on the resource name instead of a server id.
    -- `RateLimit.take` never interprets its first argument, so a string is a
    -- bucket like any other, and no numeric server id can collide with a name.
    if not ratelimit.take(resource, 'cad.export.createCall', EXPORT_LIMIT) then
        return nil, 'rate_limited'
    end

    if type(data) ~= 'table' then return nil, 'invalid' end

    local agencyId = type(data.agencyId) == 'string' and data.agencyId
        or FredPD.Config.server.agency.id

    -- An agency that does not exist is refused rather than defaulted to: a call
    -- filed silently against the wrong department is a call the right one never
    -- sees, and `fk_fpd_calls_agency` would refuse it anyway, one confusing SQL
    -- error later.
    if not agencies.get(agencyId) then return nil, 'unknown_agency' end

    -- An unrecognised type becomes `other` rather than refusing the call.
    -- `fpd_calls.type` deliberately carries no CHECK because the code tables grow
    -- (0007); a robbery script naming a type this server has not configured still
    -- has a robbery to report, and a queue entry labelled "other" beats none.
    local callType = CALL_TYPES[data.type] and data.type or FredPD.CallType.OTHER

    local priority = 3
    if type(data.priority) == 'number' and data.priority == math.floor(data.priority) then
        priority = math.max(1, math.min(4, data.priority))
    end

    local x, y, z = finite(data.x), finite(data.y), finite(data.z)

    -- All three or none (`ck_fpd_calls_position`). Two thirds of a position puts
    -- a marker under the map, and the closest-unit recommendation would then
    -- offer whoever happens to be nearest the origin.
    if x == nil or y == nil or z == nil then
        x, y, z = nil, nil, nil
    end

    local locationText = boundedText(data.locationText, EXPORT_MAX.locationText)

    -- Somewhere to go, in words or in coordinates (`ck_fpd_calls_where`). A call
    -- with neither is a call nobody can be sent to.
    if x == nil and locationText == nil then return nil, 'invalid' end

    local beat = x and service.beatFor(repo.listBeats(agencyId), x, y) or nil

    -- An empty actor rather than nil: the call has no author, `created_by` stays
    -- NULL, and the repo's read-back scopes by the resource and the location
    -- instead. 7.16.1 gives this call its own opening line naming the resource,
    -- which the repo builds from `source` and `sourceResource`.
    local created = repo.createCall(agencyId, {
        type = callType,
        priority = priority,
        locationText = locationText,
        x = x, y = y, z = z,
        beatId = beat and beat.id or nil,
        callerName = boundedText(data.callerName, EXPORT_MAX.callerName),
        callerPhone = boundedText(data.callerPhone, EXPORT_MAX.callerPhone),
        source = 'export',
        sourceResource = resource,
        details = boundedText(data.details, EXPORT_MAX.details),
    }, {})

    if not created then return nil, 'failed' end

    -- No `discordId`: there is no actor, and inventing one would put a name on
    -- something nobody did. `source_resource` on the row is who to ask instead.
    audit.write({
        action = 'cad.call.created',
        agencyId = agencyId,
        subjectType = 'call',
        subjectId = tostring(created.id),
        detail = { source = 'export', resource = resource, type = callType, priority = priority },
    })

    board.callChanged(agencyId, repo.getCall(agencyId, created.id))

    TriggerEvent('fredpd:callCreated', {
        id = created.id,
        agencyId = agencyId,
        callNumber = created.callNumber,
        type = callType,
        priority = priority,
    })

    return { id = created.id, callNumber = created.callNumber }, nil
end

exports('CreateCall', createCall)
