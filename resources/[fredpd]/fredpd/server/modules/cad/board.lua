--- The unit board, and the one rule that decides what a board row may say
--- (spec 7.16, 7.17; invariants 4 and 5).
---
--- ## Why this file exists at all
---
--- `Repo.listUnits` and `Repo.getUnit` LEFT JOIN `fpd_calls` and alias five
--- columns off it -- `onCallId`, `onCallLead`, `onCallNumber`, `onCallPriority`,
--- `onCallStatus` -- so **a board row is a call payload wearing a unit's
--- clothes**. Filtered on the page permission and the agency and nothing else,
--- it hands a reader who was correctly refused call 1042 on the queue that same
--- call's number, its urgency and its stage, one array further down the same
--- response. The rule that stops it is small: run the row's call through the
--- same access check a read makes, and take the five columns off the rows that
--- fail.
---
--- The rule was not wrong when it shipped. It was a *local* in `routes.lua`,
--- and the module ships board rows from three places:
---
---   1. `routes.lua` -- `unit.list`, `map.view`, and every push that carries a
---      unit row. Masked, correctly.
---   2. `events.lua` -- sign-on and sign-off push a unit row too, and had their
---      own `unitChanged` that did not mask. Because the NUI *replaces* a unit
---      row rather than merging it, that push actively un-masked what
---      `routes.lua` had just masked: a dispatcher's own board would heal the
---      hole the access check had made in it, seconds later, on the next duty
---      pass.
---   3. `avl.lua` -- the welfare prompt (7.16) carries `callId` and
---      `callNumber` for every unit that has been sitting too long, to every
---      holder of `cad.unit.manage`, unchecked.
---
--- A rule enforced at one of three call sites is not enforced. So it lives
--- here, once, and the three files call it. Nothing else belongs in this file:
--- it decides who may see a call and what comes off a payload that carries one,
--- and it has no opinion about what any route does.
---
--- ## The key a payload rides on is not always the key its contents need
---
--- The move above fixed where the rule lived and not what it asked. `mayRead` is
--- clearance and agency; every route and every push in the module that can hand
--- back a call is *also* gated on `page.dispatch`, and for two of the three call
--- sites that gate is applied outside this file and out of sight -- by the route
--- wrapper, or by `toDispatch`. The welfare prompt is the third, it rides on
--- `cad.unit.manage` instead, and so the call fields on its rows were the one
--- thing in the suite a session without the dispatch key could read. Nobody
--- decided that; the fields were simply in a table whose permission was chosen
--- for the prompt.
---
--- So the masking functions here ask `mayReceiveCall` -- both keys -- rather than
--- each of them taking their caller's gate on trust. Redundant on the board,
--- load-bearing on the welfare row, and one question either way. If you add a
--- payload to this file, the thing to check is not which key you send it on: it
--- is which keys every field on it is protected by everywhere else.
---
--- ## Why the masking is a copy and never a redaction in place
---
--- `unitChanged` sends both shapes of the same row in one pass -- the full row
--- to the readers who may see the call, the masked row to the ones who may not.
--- Clearing the fields on the row itself would mask it for the cleared readers
--- too, and the second push would carry the row the first one had already
--- emptied. Every mask below therefore builds a new table.
---
--- ## Why `avl.invalidate` is called from here
---
--- `Board.unitChanged` invalidates the cached board before it pushes, which
--- makes this file depend on `avl.lua` -- a file the manifest loads *after* it,
--- so the lookup is inside the function body and never a local captured at
--- load. That is deliberate and it is the second half of the same argument:
--- both call sites already did this, and the cost of one of them forgetting is
--- a dispatcher looking at a stale board for up to `avlBoardTtlSeconds` with
--- nothing on screen to say so. "A unit row changed" and "the cached board is
--- now wrong" are the same event, so they get one owner rather than a
--- convention. The one caller that invalidates *without* a changed unit row --
--- `call.clear`, where every unit on a call came free at once -- still calls
--- `avl.invalidate` directly, because there is no row for it to pass.
---
--- ## What this file does not fix
---
--- `Board.mayRead` is `Access.canRead` (the pure service) and not
--- `accessRepo.read` (the register's path), for the reason `routes.lua`'s
--- header sets out at length: `call` is not in the `RECORD_TYPES` allowlist, so
--- compartments, explicit grants and the `access.read` audit row do not happen
--- for a call. That is tolerable only while nothing in M4 writes a call above
--- the column default of `internal`. Moving the rule here does not change it --
--- it makes it one function to change on the day it stops being tolerable,
--- instead of three.

FredPD = FredPD or {}
FredPD.Cad = FredPD.Cad or {}

local accessRules = FredPD.Modules.access
local repo = FredPD.Repo.cad
local push = FredPD.Core.push

--- Bound here because this file answers a *permission* question and not only a
--- clearance one; `Board.mayReceiveCall` below is the whole of the reason and
--- says what went wrong without it. `core/perms.lua` is loaded a long way before
--- this file (fxmanifest), so this is a local at load like the other three,
--- rather than a lookup inside a function body the way `avl` has to be.
local perms = FredPD.Core.perms

local Board = {}

-- -----------------------------------------------------------------------------
-- The permissions a board payload travels on
-- -----------------------------------------------------------------------------

--- The dispatch reads (Appendix B): the queue, a card, the board, the map and
--- the broadcast board are gated on the page key and on nothing else. Exported,
--- so the three files that push board payloads name the same key rather than
--- three copies of the same string that can drift apart one rename at a time.
local READ <const> = 'page.dispatch'

--- Who may be asked to check on a unit (7.16: "a welfare-check prompt to
--- dispatch"). `cad.unit.manage` is the key dispatch, supervisor and command
--- hold; deliberately not the page key, which every officer holds.
---
--- It says who may be *asked*, and that is all it says. It is not a second way
--- of being allowed to read a call, and for a while the welfare prompt used it
--- as one: holding this key is why the prompt reaches you, and `READ` above is
--- still what decides whether the call on it may be named. The two are not
--- ordered -- neither implies the other, and the seed granting both to the three
--- groups that hold this one is a fact about the seed and not about the model
--- (`Board.mayReceiveCall`).
local WELFARE <const> = 'cad.unit.manage'

--- The prefix every column `Repo.listUnits` joins off `fpd_calls` is aliased
--- with.
---
--- A prefix rather than a list of five names, because the list is the thing
--- that goes stale: the next column somebody joins onto the board will be
--- called `onCallSomething` by the convention the other five already follow,
--- and it will be masked the day it is added rather than the day somebody
--- notices it was not.
local ON_CALL <const> = 'onCall'

--- The fields on a welfare prompt row that name the call a unit is sitting on.
---
--- Named rather than prefixed, because this row is built by hand in `avl.lua`
--- for the NUI's prompt and not aliased by a SELECT, so the convention above
--- has nothing to hook onto. A field added to that row that names a call has to
--- be added here too -- which is why the welfare row is deliberately the only
--- payload in the module with a hand-written list instead of a prefix.
local WELFARE_CALL_FIELDS <const> = { 'callId', 'callNumber' }

Board.READ = READ
Board.WELFARE = WELFARE
Board.ON_CALL = ON_CALL

-- -----------------------------------------------------------------------------
-- Who may read a call
-- -----------------------------------------------------------------------------

--- May this session read this call? (invariant 4; see the header for the limits
--- of this check.)
---
--- A nil call is not readable. That is the answer for a row another agency
--- owns, one that has been deleted under the reader, and one the repo could not
--- read back at all: an unknown row is not a readable one, and everything below
--- masks on the strength of this returning false.
function Board.mayRead(session, call)
    return call ~= nil and accessRules.canRead(accessRules.reader(session), call)
end

--- May a payload this session is about to be handed *name* this call?
---
--- Two keys, and the second one is the one that was missing. `mayRead` above is
--- clearance and agency and nothing else, which is the right question for a
--- route that has already been gated on its own key -- `call.note` and
--- `call.clear` are action keys and have nothing to do with the dispatch page,
--- and `openCall` in `routes.lua` is right to ask only about clearance there.
--- It is the wrong question for a helper that is deciding by itself what a
--- payload may carry, because the helper is where the caller's gate stops being
--- visible.
---
--- Every path in the suite that hands back a call is gated on the dispatch read
--- key: `call.get`, `call.list`, `unit.list` and `map.view` are all `READ`, and
--- `toDispatch` puts the same key on every push that leaves this file. The
--- welfare prompt was the one exception, and it was not a deliberate one. It
--- travels on `WELFARE` because `cad.unit.manage` is who the *prompt* is for
--- (7.16, "a welfare-check prompt to dispatch"), and the two call fields riding
--- along on the row inherited that gate by sitting in the same table -- masked
--- on clearance, gated on a key that says nothing about reading calls.
---
--- What that cost: an operator maps a Discord role to a group holding
--- `cad.unit.manage` and `clearance.internal` and not `page.dispatch` -- which
--- the group editor allows, and which is the natural shape for a role that
--- manages units from the MDT rather than from the console. That session is
--- refused `call.get`, `call.list`, `unit.list` and `map.view` with `forbidden`
--- and cannot reach a call by any route in the suite; and then the welfare pass
--- handed it a call id and a call number for every unit sitting too long, every
--- thirty seconds, from the one payload that never asked for the key the
--- refusals were made on.
---
--- So the rule is one function rather than a line repeated in each masking loop.
--- On the board it is redundant today -- `boardFor`'s two callers are both
--- `READ` routes -- and on the welfare row it is load-bearing, and that is
--- exactly the argument for not leaving each caller to work out which of the two
--- it is dealing with.
function Board.mayReceiveCall(session, call)
    return perms.satisfies(session.permissions, READ) and Board.mayRead(session, call)
end

--- Drops the calls a session may not see from a list.
---
--- Absent rather than stubbed: on a queue a placeholder would carry the count,
--- the priority ordering and the position, which is most of what a call
--- discloses in the first place.
---
--- One `reader` for the whole list rather than one per row -- the queue is two
--- hundred rows and is polled every few seconds by every open console (12.1).
---
--- The dispatch read key is asked for once, for the same reason and in the same
--- place: it is one answer for the whole list, and this function hands back
--- whole call rows, so a session without it has nothing to be given here at all.
--- `call.list` and `map.view` are both `READ` routes and cannot take that
--- branch; it is written so that the rule belongs to this file rather than to
--- whoever calls it, which is the difference the welfare prompt cost us.
function Board.readable(session, calls)
    if not perms.satisfies(session.permissions, READ) then return {} end

    local reader = accessRules.reader(session)
    local out = {}

    for index = 1, #calls do
        if accessRules.canRead(reader, calls[index]) then
            out[#out + 1] = calls[index]
        end
    end

    return out
end

-- -----------------------------------------------------------------------------
-- Taking a call off a payload
-- -----------------------------------------------------------------------------

--- A board row with the call it is on taken off it.
---
--- A copy and never the row itself; see the header for why that matters to
--- `unitChanged` in particular.
function Board.withoutCall(unit)
    local out = {}

    for key, value in pairs(unit) do
        if key:sub(1, #ON_CALL) ~= ON_CALL then out[key] = value end
    end

    return out
end

--- A copy of `row` without the named fields.
---
--- For the payloads whose call-naming fields are not aliased with the board's
--- prefix -- the welfare prompt, today, and nothing else.
local function without(row, fields)
    local out = {}

    for key, value in pairs(row) do out[key] = value end
    for index = 1, #fields do out[fields[index]] = nil end

    return out
end

--- Does `row` name a call in any of `fields`?
---
--- The board never has to ask this: its five call columns are aliased off one
--- LEFT JOIN, and the id among them is the joined table's primary key, so with
--- no call all five come back SQL NULL and are absent from the row together, and
--- with a call the id is there. Reading `onCallId` really does answer "is there
--- a call on this row", and reading one field per row is what keeps `boardFor`
--- inside 12.1 on a two-hundred-row board.
---
--- The welfare row has no such guarantee and must not be given the benefit of
--- the doubt. It is assembled by hand in `avl.lua`, field by field, and this file
--- is the helper that file trusts to have checked -- which is the whole shape of
--- the defect above, one level down. A row that arrived carrying `callNumber`
--- and no `callId` would answer "no call here" on the id alone and be sent
--- whole, to every holder of the welfare key, with the number still on it. So
--- the question is asked of every field the masking would take off, and a row
--- that names a call by any of them goes through the access check -- where a nil
--- id reads as a call that cannot be read and is masked, because an unknown row
--- is not a readable one.
local function namesCall(row, fields)
    for index = 1, #fields do
        if row[fields[index]] ~= nil then return true end
    end

    return false
end

--- The calls a list of rows is standing on, by id, each read once.
---
--- One primary-key lookup per *distinct* call, not per row, and none at all for
--- a list where nobody is on anything -- which on a quiet shift is all of it. A
--- call that cannot be read back is remembered as `false`, which masks its rows
--- for everybody, because an unknown row is not a readable one. (`false` and
--- not nil: nil is "not looked up yet" and would be looked up again for every
--- further row on the same call.)
---
--- `Repo.listUnits` could answer this in the JOIN it already makes by aliasing
--- `c.classification`, which would remove these lookups outright; the milestone
--- report asks for that, and nothing here may wait for it.
---
--- @param agencyId string
--- @param rows table
--- @param field string|nil which column holds the call id; default `onCallId`
--- @return table id -> call row, or `false` where it could not be read
function Board.callsBehind(agencyId, rows, field)
    field = field or 'onCallId'

    local calls = {}

    for index = 1, #rows do
        local id = rows[index][field]

        if id ~= nil and calls[id] == nil then
            calls[id] = repo.getCall(agencyId, id) or false
        end
    end

    return calls
end

--- The call `callsBehind` remembered for `id`, in the shape `mayRead` wants.
---
--- Two absences and a boolean meet here and they must not be confused. A row
--- that names no call (`id` nil) and a call the repo could not read back
--- (remembered as `false`, so the miss is not looked up again for every further
--- row standing on it) are both "no readable call" -- but `false ~= nil` is true
--- in Lua, so handing `calls[id]` straight to `mayRead` passes its `call ~= nil`
--- guard and puts a boolean where `canRead` expects a row to index. The `or nil`
--- that fixes it was written out at each masking loop; it is one function here
--- so that the loop somebody adds next cannot be the one that leaves it off.
local function callAt(calls, id)
    if id == nil then return nil end

    return calls[id] or nil
end

--- The unit board as one session may see it (invariant 4).
---
--- The row stays -- a callsign, a status, a position and a time in status are
--- the board, and none of them belongs to the call. What comes off is the call.
--- A masked row is indistinguishable from a unit working nothing, which is the
--- same answer the queue gave that reader a second earlier.
---
--- The test is `mayReceiveCall` and not `mayRead`, which for this function's two
--- callers can only ever agree: `unit.list` and `map.view` are both `READ`
--- routes, so the key is already held by the time a session gets here. It is
--- written that way so that the two masking loops in this file ask one question
--- rather than two that look alike, and so that the next caller -- which may not
--- be a `READ` route, because the welfare push was not -- cannot borrow this
--- loop and lose the key on the way in.
---
--- @param calls table|nil a `callsBehind` result to reuse, when the caller is
---   masking the same list for more than one reader
function Board.boardFor(session, units, calls)
    calls = calls or Board.callsBehind(session.agencyId, units)

    local out = {}

    for index = 1, #units do
        local unit = units[index]
        local id = unit.onCallId

        if id == nil or Board.mayReceiveCall(session, callAt(calls, id)) then
            out[index] = unit
        else
            out[index] = Board.withoutCall(unit)
        end
    end

    return out
end

-- -----------------------------------------------------------------------------
-- Pushing
-- -----------------------------------------------------------------------------

--- Sends a dispatch payload to the sessions of one agency that may read it.
---
--- Never `-1` (invariant 5). `push.toPermission` walks the open sessions and
--- applies the two tests a read applies: the page permission, and the agency --
--- which is read off the *recipient's* session, never off the payload. A
--- payload carrying a call takes a third test, and `callChanged` and
--- `unitChanged` below are the two that add it.
---
--- @return number recipients
function Board.toDispatch(agencyId, event, payload, extra)
    return push.toPermission(READ, event, FredPD.markArrays(payload), function(session)
        if session.agencyId ~= agencyId then return false end

        return extra == nil or extra(session)
    end)
end

--- Tells every session that may see it that a call changed.
---
--- One event for the queue and the card both: a client holding the card open
--- refetches it and one holding the queue re-sorts, and two messages could
--- disagree about which happened.
---
--- The recipient list is filtered through the same access check the read makes,
--- which is what invariant 5 asks for: a push is a read nobody asked for.
---
--- @return number recipients
function Board.callChanged(agencyId, call)
    if not call then return 0 end

    return Board.toDispatch(agencyId, 'fredpd:cad:call', { call = call }, function(session)
        return Board.mayRead(session, call)
    end)
end

--- Tells the boards that a unit row changed, and drops the cached board behind
--- the AVL sweep so the next pass reads the change rather than the last minute.
---
--- Two pushes rather than one when the unit is on a call, because the row
--- carries that call (see the header) and a push is a read nobody asked for
--- (invariants 4 and 5). The filters are complementary, so every recipient gets
--- exactly one of the two payloads and nobody who would have received a single
--- unfiltered push is dropped -- the board still says the unit exists, moved,
--- and is where it is; it stops saying what they are on.
---
--- `unit` may be nil -- a repo read that came back with nothing -- and the
--- invalidation still happens: whatever made the row unreadable is exactly the
--- kind of change the cached board must not keep serving.
---
--- @return number recipients
function Board.unitChanged(agencyId, unit)
    -- Looked up here and never captured at load: `avl.lua` is listed *after*
    -- this file in the manifest, so at load this field is nil. See the header
    -- for why the invalidation lives in this function rather than at the two
    -- call sites.
    FredPD.Cad.avl.invalidate(agencyId)

    if not unit then return 0 end

    if unit.onCallId == nil then
        return Board.toDispatch(agencyId, 'fredpd:cad:unit', { unit = unit })
    end

    local call = repo.getCall(agencyId, unit.onCallId)
    local masked = Board.withoutCall(unit)

    local sent = Board.toDispatch(agencyId, 'fredpd:cad:unit', { unit = unit }, function(session)
        return Board.mayRead(session, call)
    end)

    return sent + Board.toDispatch(agencyId, 'fredpd:cad:unit', { unit = masked },
        function(session)
            return not Board.mayRead(session, call)
        end)
end

-- -----------------------------------------------------------------------------
-- The welfare prompt (7.16)
-- -----------------------------------------------------------------------------

--- One welfare prompt list as one session may see it.
---
--- The unit stays and the call comes off, exactly as on the board: that a unit
--- has been on scene for twenty-five minutes is the unit's own status, and a
--- supervisor who may not read the call still has to be the one to ask whether
--- they are all right. What they do not get is the number of the call they are
--- sitting on.
---
--- The row surviving the mask is the property to keep, and it is worth arguing
--- once more now that a second key decides the other half: the officer, the
--- callsign, the status and the minutes reach **every** holder of `WELFARE` in
--- the agency, whatever they hold besides. Dropping the row for a reader who may
--- not read the call behind it would turn a classification into a reason nobody
--- checks on an officer, and an alert whose entire content is "somebody should
--- say something to them" is the last payload that should be failing closed by
--- going silent. It fails closed by saying less.
---
--- The call half is gated on both keys (`mayReceiveCall`), because it is the
--- half that was reaching sessions the rest of the suite refuses.
---
--- @param calls table|nil a `callsBehind` result keyed on `callId`, to reuse
function Board.welfareFor(session, due, calls)
    calls = calls or Board.callsBehind(session.agencyId, due, 'callId')

    local out = {}

    for index = 1, #due do
        local row = due[index]

        -- Asked of every field the mask would take off, and not of `callId`
        -- alone; `namesCall` has the reason, and it is the same reason this
        -- function exists at all -- the row is built by another file and this is
        -- where its assumptions are meant to be checked, not inherited.
        if not namesCall(row, WELFARE_CALL_FIELDS) then
            out[index] = row
        elseif Board.mayReceiveCall(session, callAt(calls, row.callId)) then
            out[index] = row
        else
            out[index] = without(row, WELFARE_CALL_FIELDS)
        end
    end

    return out
end

--- Sends the welfare prompt, masked per recipient.
---
--- **This one cannot be split into two complementary pushes** the way
--- `unitChanged` is. That trick works because a unit push carries exactly one
--- call, so the recipients divide cleanly in two. A welfare list carries rows
--- for *many different* calls, and a supervisor cleared for one of them and not
--- another belongs to neither half -- with two pushes there is no half that is
--- right for them, and with one push somebody reads a call number they were
--- refused. So the payload is built per session, which is what
--- `Push.perSession` exists for.
---
--- The fast path matters more than it looks: on a quiet shift the units that
--- trip the welfare threshold are the ones sitting `available` at the station,
--- on no call at all, so there is nothing to mask and the whole list is one
--- payload sent to everybody -- no copy per recipient and no call lookups.
---
--- `WELFARE` alone is the right gate on that fast path, and only there: a list
--- in which no row names a call carries nothing the dispatch read key protects.
--- The moment one row does, the payload becomes a call payload for that
--- recipient and `welfareFor` adds the second key. Which is why the fast path is
--- now decided by "does any row name a call" and not by "did any lookup
--- happen": those differ for exactly one row shape -- a number with no id -- and
--- that is the shape that would have gone out whole.
---
--- @return number recipients
function Board.welfarePush(agencyId, due)
    if due == nil or #due == 0 then return 0 end

    local function sameAgency(session)
        return session.agencyId == agencyId
    end

    local carriesCall = false

    for index = 1, #due do
        if namesCall(due[index], WELFARE_CALL_FIELDS) then
            carriesCall = true
            break
        end
    end

    if not carriesCall then
        return push.toPermission(WELFARE, 'fredpd:cad:welfare',
            FredPD.markArrays({ units = due }), sameAgency)
    end

    local calls = Board.callsBehind(agencyId, due, 'callId')

    return push.perSession(WELFARE, 'fredpd:cad:welfare', function(session)
        return FredPD.markArrays({ units = Board.welfareFor(session, due, calls) })
    end, sameAgency)
end

FredPD.Cad.board = Board
