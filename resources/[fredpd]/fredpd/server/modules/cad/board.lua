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

--- Drops the calls a session may not see from a list.
---
--- Absent rather than stubbed: on a queue a placeholder would carry the count,
--- the priority ordering and the position, which is most of what a call
--- discloses in the first place.
---
--- One `reader` for the whole list rather than one per row -- the queue is two
--- hundred rows and is polled every few seconds by every open console (12.1).
function Board.readable(session, calls)
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

--- The unit board as one session may see it (invariant 4).
---
--- The row stays -- a callsign, a status, a position and a time in status are
--- the board, and none of them belongs to the call. What comes off is the call.
--- A masked row is indistinguishable from a unit working nothing, which is the
--- same answer the queue gave that reader a second earlier.
---
--- @param calls table|nil a `callsBehind` result to reuse, when the caller is
---   masking the same list for more than one reader
function Board.boardFor(session, units, calls)
    calls = calls or Board.callsBehind(session.agencyId, units)

    local out = {}

    for index = 1, #units do
        local unit = units[index]
        local id = unit.onCallId

        if id == nil or Board.mayRead(session, calls[id] or nil) then
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
--- @param calls table|nil a `callsBehind` result keyed on `callId`, to reuse
function Board.welfareFor(session, due, calls)
    calls = calls or Board.callsBehind(session.agencyId, due, 'callId')

    local out = {}

    for index = 1, #due do
        local row = due[index]
        local id = row.callId

        if id == nil or Board.mayRead(session, calls[id] or nil) then
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
--- @return number recipients
function Board.welfarePush(agencyId, due)
    if due == nil or #due == 0 then return 0 end

    local function sameAgency(session)
        return session.agencyId == agencyId
    end

    local calls = Board.callsBehind(agencyId, due, 'callId')

    if next(calls) == nil then
        return push.toPermission(WELFARE, 'fredpd:cad:welfare',
            FredPD.markArrays({ units = due }), sameAgency)
    end

    return push.perSession(WELFARE, 'fredpd:cad:welfare', function(session)
        return FredPD.markArrays({ units = Board.welfareFor(session, due, calls) })
    end, sameAgency)
end

FredPD.Cad.board = Board
