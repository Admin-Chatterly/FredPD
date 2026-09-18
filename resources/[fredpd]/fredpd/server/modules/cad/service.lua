--- Dispatch (CAD) logic (spec 7.16, 7.17, Appendix D and E).
---
--- Everything in this file is arithmetic over plain tables: no natives, no SQL,
--- no clock of its own. That is the rule 3.4 sets for every `service.lua`, and
--- here it buys something specific -- seven decisions that are argued about in
--- bug reports and cannot be eyeballed on a running server:
---
---   * what "stacked by priority and age" means when a P3 has waited an hour
---     and a P1 arrives (7.16);
---   * which units the console recommends, and which it refuses to recommend
---     even though they are nearer (7.16);
---   * when a unit has been on scene long enough to be worth asking about
---     (7.16, the welfare check);
---   * what a unit's status becomes when a call stops being theirs, and how the
---     call closing, the dispatcher taking them off an open one, and the call
---     they are sent to instead differ (`statusAfterCall`);
---   * whether a point on the edge of a beat is in that beat (7.17) -- a
---     boundary that belongs to neither beat is a call that lands nowhere;
---   * the bounding box a beat is rejected by before the ray cast runs, which
---     0007 requires to be computed here and never accepted from input;
---   * what a call number looks like and which counter row it comes from
---     (Appendix D), which is the first thing that happens at midnight.
---
--- Positions arrive here as numbers somebody else read off a ped. Nothing in
--- this file asks a client where anything is, and nothing in the module does:
--- 0007's header says why, and it is the one fact on the map an officer has a
--- motive to lie about.
---
--- The vocabularies come from `shared/generated/schema.lua` and are never
--- restated. A status list hand-copied into Lua is a list that disagrees with
--- the database's CHECK on the day somebody adds a value, and `pnpm enum:check`
--- cannot see a copy that lives in a Lua table.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

--- The generated enums this file reads. Asserted rather than defaulted: a nil
--- here means the file was loaded before `shared/generated/schema.lua`, and
--- every status comparison below would then be a comparison against nil, which
--- is silently false rather than loudly wrong.
local UnitStatus <const> = assert(FredPD.UnitStatus,
    'cad/service.lua must load after shared/generated/schema.lua')
local CallStatus <const> = assert(FredPD.CallStatus,
    'cad/service.lua must load after shared/generated/schema.lua')
local CallDisposition <const> = assert(FredPD.CallDisposition,
    'cad/service.lua must load after shared/generated/schema.lua')
local CallLogKind <const> = assert(FredPD.CallLogKind,
    'cad/service.lua must load after shared/generated/schema.lua')

local Cad = {}

-- -----------------------------------------------------------------------------
-- Configuration
-- -----------------------------------------------------------------------------

--- Working defaults for the whole module.
---
--- A server overrides any of it in `config/server.lua` under `cad`; the defaults
--- are here rather than there because these are the values the spec asserts
--- against, and a test that read the server config would be testing the
--- installation instead of the code. `Cad.settings` merges the two.
Cad.defaults = {
    --- How long a unit may hold a status before dispatch is asked to check on
    --- them (7.16: "a unit on scene too long triggers a welfare-check prompt").
    ---
    --- Keyed by status, and deliberately only `on_scene` by default. That is
    --- the status 7.16 names, and it is the one where silence means something:
    --- a unit that has been `busy` for an hour is doing paperwork, a unit that
    --- has been on scene for an hour and said nothing may be face down in a
    --- ditch. A server that wants the same prompt for `en_route` adds the key.
    ---
    --- Twenty minutes because it has to sit above the length of an ordinary
    --- call -- a traffic stop with a citation written at the roadside runs ten
    --- to fifteen -- and below the length of a shift. A threshold that fires on
    --- routine work is a prompt dispatchers learn to dismiss without reading,
    --- which is worse than no prompt at all.
    welfareSeconds = {
        on_scene = 20 * 60,
    },

    --- How long after a prompt the same unit may be prompted again.
    ---
    --- Without it the board polls every few seconds and every poll past the
    --- threshold is another prompt for the same unit (12.1's read cadence), so
    --- the one unit that genuinely needs checking on is buried under its own
    --- alerts. The caller remembers when it last prompted; there is no column
    --- for it, and there should not be -- see `needsWelfareCheck`.
    welfareRepeatSeconds = 10 * 60,

    --- How many units the console offers as "closest available" (7.16).
    ---
    --- Three, because the recommendation is a suggestion a dispatcher reads in
    --- a second and not a sorted roster: a list of twelve is one the dispatcher
    --- scans past to the board they already know.
    recommendLimit = 3,

    --- How old an AVL position may be before "closest" is a guess, in seconds.
    ---
    --- A unit's position is written by the server's sweep at 3.6's one-to-two
    --- second cadence while they are connected, and left where it was when they
    --- disconnect ("last known" is the honest name for the column). Two minutes
    --- of silence at 50 km/h is a kilometre and a half of error, so a stale
    --- position still ranks -- the unit may well be the closest -- but it ranks
    --- behind every fresh one and is flagged, so the dispatcher sends the unit
    --- they can see rather than the number that sorted first.
    positionMaxAgeSeconds = 120,

    --- How long a broadcast stands when nobody says (7.16 [S]).
    ---
    --- `BroadcastCreate.expiresInMinutes` is optional and
    --- `fpd_broadcasts.expires_at` is nullable, so "absent" could mean "runs
    --- forever". It does not: a board nobody clears is what this default
    --- exists to prevent. Twelve hours is a shift and a half -- long enough
    --- that a BOLO put out at the start of nights is still up at the end of it.
    broadcastMinutes = 12 * 60,

    --- How long plate reads are kept, in days (7.18, 13.3).
    ---
    --- Thirty, which is 7.18's own default. The sweep that acts on it is the
    --- only scheduled deletion in the suite, and 11.4 is why: a permanent
    --- record of every car every patrol drove past is a movement database.
    alprRetentionDays = 30,
}

--- Merges a server's overrides onto the defaults.
---
--- Two levels, because `welfareSeconds` is a table of its own and a server that
--- wants a different on-scene threshold should not have to restate the rest.
--- The same shape as `Forensics.settings`, deliberately: two merge rules in one
--- codebase is one too many.
---
--- @param overrides table|nil
--- @return table a new table; the defaults are never mutated
function Cad.settings(overrides)
    local merged = {}

    for key, value in pairs(Cad.defaults) do
        if type(value) == 'table' then
            local copy = {}
            for innerKey, innerValue in pairs(value) do copy[innerKey] = innerValue end
            merged[key] = copy
        else
            merged[key] = value
        end
    end

    for key, value in pairs(overrides or {}) do
        if type(value) == 'table' and type(merged[key]) == 'table' then
            for innerKey, innerValue in pairs(value) do merged[key][innerKey] = innerValue end
        else
            merged[key] = value
        end
    end

    return merged
end

-- -----------------------------------------------------------------------------
-- Call numbers (Appendix D, spec 13.1)
-- -----------------------------------------------------------------------------

--- How wide the daily sequence is padded. `{YYMMDD}-{####}`.
---
--- Four digits caps an agency at 9999 calls in one day, an order of magnitude
--- above the busiest shift a server will have, and the cap is visible rather
--- than implied: the 10000th call of a day would print as `260918-10000` and
--- still be unique, because `uq_fpd_calls_number` is over the whole string.
Cad.CALL_SEQUENCE_WIDTH = 4

--- The scope key a call number is allocated under (Appendix D).
---
--- `fpd_counters.year` is a *scope*, not a year: `0` never restarts, `YYYY`
--- restarts annually, and a call is the one day-scoped sequence in the suite,
--- so its scope is the six-digit day key. 0007 widened the column to MEDIUMINT
--- for exactly this -- 260918 does not fit in a SMALLINT, and under strict mode
--- the first call of every day would have failed to allocate a number at all.
---
--- **UTC, because the timestamps are UTC** (13.1). `received_at` is stamped by
--- the database with `CURRENT_TIMESTAMP(3)`, and if this key were read off the
--- server's local clock the two would name different days for every call taken
--- between midnight and the offset -- a call stamped the 19th and numbered
--- `260918-…`, which is the one thing a call number is read back for. A
--- deployment whose database is not on UTC breaks that agreement and not this
--- function (16).
---
--- @param atUnix number|nil unix seconds; defaults to now
--- @return number YYMMDD
function Cad.dayKey(atUnix)
    return tonumber(os.date('!%y%m%d', atUnix or os.time()))
end

--- The fixed half of a call number, and the width of the sequence.
---
--- Shaped like `Evidence.numberPrefix` and for the same reason: the counter
--- supplies a sequence and nothing else (`core/counters.lua`), so the format
--- lives with the module that owns the record, in one place busted can read.
--- `('%06d-'):format(dayKey)` rather than the raw number, so the first nine
--- days of a year keep their leading zero -- 5 January 2026 is `260105-0001`
--- and not `26105-0001`, which would sort and read as a different day.
---
--- @param dayKey number as `Cad.dayKey` returns
--- @return string prefix
--- @return number width
function Cad.callNumberPrefix(dayKey)
    return ('%06d-'):format(dayKey), Cad.CALL_SEQUENCE_WIDTH
end

--- A whole call number, for the one caller that has the sequence in hand.
---
--- The database builds the real one inside the INSERT, from
--- `Counters.numberSql()` and the prefix above, so that nothing can slip
--- between reading the counter and using it. This exists so the spec can prove
--- the two agree byte for byte -- the same guarantee `evidenceNumber` gives.
---
--- @param dayKey number
--- @param sequence number
--- @return string
function Cad.callNumber(dayKey, sequence)
    local prefix, width = Cad.callNumberPrefix(dayKey)

    return prefix .. ('%0' .. width .. 'd'):format(sequence)
end

-- -----------------------------------------------------------------------------
-- The pending queue (7.16)
-- -----------------------------------------------------------------------------

--- Is this call still open?
---
--- The same test `fpd_calls.queue_priority` makes in SQL: the column is the
--- priority while the call is open and NULL once it is closed. Restated here
--- rather than read off the column, because a call that has just been built in
--- memory -- one an export raised a moment ago -- has no generated column yet.
---
--- @param call table
--- @return boolean
function Cad.isOpen(call)
    if type(call) ~= 'table' then return false end

    return call.status ~= CallStatus.CLEARED and call.status ~= CallStatus.CANCELLED
end

--- When a call came in, as something two rows can be compared on.
---
--- Every repo read of a call selects `UNIX_TIMESTAMP(received_at)` beside the
--- formatted column precisely so this is a number. The string is the fallback
--- for a row that came from somewhere else; `DATETIME(3)` renders as
--- `YYYY-MM-DD HH:MM:SS.mmm`, which sorts chronologically as text, so it is a
--- usable key -- but only against another string, which is why the comparator
--- below refuses to compare a number with one.
local function ageKey(call)
    local unix = tonumber(call.receivedAtUnix)
    if unix then return unix end

    return type(call.receivedAt) == 'string' and call.receivedAt or nil
end

--- Is `a` ahead of `b` in the pending queue? (7.16: "stacking by priority and
--- age".)
---
--- **Priority first, always, and age only within a priority.** A P1 raised this
--- second goes to the top of the queue over a P3 that has been waiting an hour,
--- and the P3 does not creep up the list as it ages. This is the rule somebody
--- will open a bug report about, so it is worth saying why it is the rule: a
--- priority is a statement about what is happening to a person -- P1 is
--- life-threatening or in progress (Appendix E) -- and time does not make a
--- noise complaint into a stabbing. A queue that aged calls into higher
--- priorities would, on a busy night, send the last free unit to the oldest
--- complaint while the stabbing waited, and it would do it silently, because
--- the promoted call would look like a genuine P1 on every screen afterwards.
---
--- What the age is for is the *second* key and the column beside it: within one
--- priority the oldest call goes first, and `cad.queue.waiting` puts the wait on
--- the row so a dispatcher can see the P3 that has been sitting there and make
--- the decision themselves. Deciding to send a car to an old low-priority call
--- is dispatch's judgement and it is visible; a comparator that made it
--- automatically would be the same judgement, hidden.
---
--- Ties break on `id`, which is the order the calls were written. Not
--- decoration: `table.sort` needs a strict weak order, and two calls raised in
--- the same millisecond at the same priority would otherwise compare equal in
--- both directions and the sort may raise "invalid order function for sorting".
---
--- @param a table
--- @param b table
--- @return boolean
function Cad.aheadInQueue(a, b)
    -- A row with no priority sinks to the bottom rather than passing for a P4:
    -- `fpd_calls.priority` is NOT NULL, so this is a malformed row and it should
    -- look malformed rather than routine.
    local left = tonumber(a.priority) or math.huge
    local right = tonumber(b.priority) or math.huge

    if left ~= right then return left < right end

    local leftAge, rightAge = ageKey(a), ageKey(b)

    if leftAge ~= nil and type(leftAge) == type(rightAge) and leftAge ~= rightAge then
        return leftAge < rightAge
    end

    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
end

--- The pending queue, stacked (7.16).
---
--- The database already returns the queue in this order -- `idx_fpd_calls_queue`
--- is read forward and there is no sort (0007's header) -- so this is for the
--- sets SQL did not order: a queue merged with a call an export has just
--- raised, and the spec that proves what "stacking" means.
---
--- Returns a new list. The caller's table is not reordered, because the caller
--- is usually a cache somebody else is holding a reference to.
---
--- @param calls table list of call rows
--- @return table a new list, ordered
function Cad.stackQueue(calls)
    local ordered = {}

    for index = 1, #calls do
        if Cad.isOpen(calls[index]) then
            ordered[#ordered + 1] = calls[index]
        end
    end

    table.sort(ordered, Cad.aheadInQueue)

    return ordered
end

-- -----------------------------------------------------------------------------
-- Recommending units (7.16)
-- -----------------------------------------------------------------------------

--- The statuses a unit is free to be sent from.
---
--- `available` is the obvious one; `at_station` is a unit sitting in the yard,
--- which is free in every sense that matters to a dispatcher. Everything else is
--- deliberately absent, and the absences are the content of this table:
---
---   * `en_route` and `on_scene` are a unit on a call -- see `divertible`;
---   * `busy` and `transporting` are a unit doing something they cannot drop
---     without a person being left where they are;
---   * `out_of_service` is a unit that has told the board not to send them;
---   * `emergency` is a unit in distress, and offering them as the closest
---     available car is how the emergency call gets nobody at all;
---   * `off_duty` is not a unit.
local FREE_STATUSES <const> = {
    [UnitStatus.AVAILABLE] = true,
    [UnitStatus.AT_STATION] = true,
}

--- The statuses a unit may be pulled off a call from.
---
--- Only the two that mean "working a call" -- and being pulled is still gated
--- on the new call outranking the one they are on (see `recommendUnits`).
local COMMITTED_STATUSES <const> = {
    [UnitStatus.EN_ROUTE] = true,
    [UnitStatus.ON_SCENE] = true,
}

--- Is this unit free to be sent right now?
---
--- Status *and* the absence of a live assignment, because the two can disagree:
--- `fpd_units.status` is the unit's own word and `fpd_call_units` is the live
--- row that says what they are on (0007 keeps no `current_call_id` copy for
--- exactly this reason). A unit that pressed "available" while still attached to
--- a call is not free -- somebody is standing at that call expecting them.
---
--- @param unit table a board row, as the repo returns it
--- @return boolean
function Cad.isFree(unit)
    if type(unit) ~= 'table' then return false end
    if not FREE_STATUSES[unit.status] then return false end

    return unit.onCallId == nil
end

--- The plan distance between a unit and a call, in metres.
---
--- Two dimensional on purpose. Z is a floor, not a journey: a unit on the
--- freeway overpass forty metres above a call is not forty metres of driving
--- from it, and including the height would rank them above a unit at street
--- level two hundred metres down the road who can actually get there. Beats are
--- 2D for the same reason (0007: "an officer in a basement is in the beat above
--- them").
---
--- Straight-line rather than road distance, which is what every CAD does with
--- no routing graph to hand -- and it is why this is a *recommendation* on a
--- screen a dispatcher reads rather than an assignment the console makes.
---
--- @param unit table with `x` and `y`
--- @param position table with `x` and `y`
--- @return number|nil metres; nil when either side has no position
local function distanceTo(unit, position)
    local ux, uy = tonumber(unit.x), tonumber(unit.y)
    local px, py = tonumber(position.x), tonumber(position.y)

    if not ux or not uy or not px or not py then return nil end

    local dx, dy = ux - px, uy - py

    return math.sqrt(dx * dx + dy * dy)
end

--- Is this unit's last known position old enough to be a guess?
---
--- `position_at` is when the sweep last read the ped. A disconnected unit keeps
--- the position it had, so "stale" and "gone" look identical from here -- which
--- is the honest answer, and why a stale unit is flagged rather than dropped.
---
--- @param unit table
--- @param now number unix seconds
--- @param config table as `Cad.settings` returns
--- @return boolean
local function positionStale(unit, now, config)
    local at = tonumber(unit.positionAtUnix)
    if not at then return true end

    local maxAge = tonumber(config.positionMaxAgeSeconds) or 0
    if maxAge <= 0 then return false end

    return (now - at) > maxAge
end

--- The closest units worth sending to a call (7.16: "recommend closest
--- available units by position").
---
--- **The nearest unit is not always the right recommendation, and this is the
--- list of reasons why.**
---
---   1. *A unit on a call is not available.* The obvious half -- a car already
---      on a P1 is not the closest available anything -- and the half that a
---      distance sort alone gets wrong, because the unit standing at the
---      shooting two streets away is by definition the nearest one to the next
---      call on that street.
---   2. *Except when the new call outranks the one they are on.* A unit taking
---      a report (P4) two hundred metres from a shots-fired call (P1) is the
---      right answer and dispatch knows it. So a committed unit is offered when
---      the new call is strictly more urgent than theirs, ranked below every
---      free unit however far away those are, and marked `divertFromCallId` so
---      the console can say what it is asking the dispatcher to interrupt.
---      Strictly more urgent, never equal: swapping a unit between two P2s
---      leaves the first call with nobody and gains nothing.
---   3. *A guessed position ranks behind a known one.* See `positionStale`.
---   4. *A unit with no position at all is not ranked.* It is left off this
---      list entirely rather than sorted to the end at distance zero, which is
---      where a nil would land it. It is still on the board and still
---      dispatchable by hand: "we do not know where they are" is a thing for a
---      person to decide about, not a thing to present as "closest".
---   5. *A unit appears once.* A board row is a unit joined to the call it is
---      live on, so a unit live on two calls is two rows -- and two of the
---      three slots in this list filled by one callsign is a dispatcher
---      sending a car that is already coming. `Repo.assignUnits` is what keeps
---      a unit live on one call at a time; this is the second lock on the same
---      door, because a database written before that rule was enforced still
---      hands this the rows it made.
---
--- Deterministic all the way down -- distance, then officer id -- so two
--- dispatchers looking at the same board see the same three names in the same
--- order, and so this spec can assert on the whole list.
---
--- @param units table list of board rows: officerId, callsign, status, x, y,
---   positionAtUnix, onCallId, onCallPriority
--- @param position table the call's position, { x = , y = }
--- @param options table|nil { now, limit, callPriority, config }
--- @return table list of { officerId, callsign, status, distance, stale,
---   divertFromCallId }
function Cad.recommendUnits(units, position, options)
    options = options or {}

    local config = options.config or Cad.defaults
    local now = options.now or os.time()
    local limit = tonumber(options.limit) or tonumber(config.recommendLimit) or 3
    local callPriority = tonumber(options.callPriority)

    if type(units) ~= 'table' or type(position) ~= 'table' then return {} end

    local candidates = {}

    for index = 1, #units do
        local unit = units[index]
        local distance = distanceTo(unit, position)

        if distance then
            local free = Cad.isFree(unit)
            local theirs = tonumber(unit.onCallPriority)
            -- Divertible: they are working a call, we know how urgent it is,
            -- we know how urgent ours is, and ours outranks theirs. Every one
            -- of those four has to be true; an unknown priority on either side
            -- is not an invitation to guess.
            local divertible = not free
                and COMMITTED_STATUSES[unit.status] == true
                and unit.onCallId ~= nil
                and callPriority ~= nil
                and theirs ~= nil
                and callPriority < theirs

            if free or divertible then
                candidates[#candidates + 1] = {
                    officerId = unit.officerId,
                    callsign = unit.callsign,
                    status = unit.status,
                    distance = distance,
                    stale = positionStale(unit, now, config),
                    divertFromCallId = divertible and unit.onCallId or nil,
                    -- Sort keys, dropped before the list is returned.
                    tier = free and 0 or 1,
                }
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        if a.stale ~= b.stale then return b.stale end
        if a.distance ~= b.distance then return a.distance < b.distance end

        return (tonumber(a.officerId) or 0) < (tonumber(b.officerId) or 0)
    end)

    local recommended = {}
    local seen = {}

    for index = 1, #candidates do
        if #recommended >= limit then break end

        local candidate = candidates[index]
        local officerId = candidate.officerId

        -- The best-ranked row for an officer wins, because the list is already
        -- sorted: a free row beats a divertible one, and a fresh position beats
        -- a stale one. A row with no officer id at all is not a unit anybody
        -- can be deduplicated against, so it is kept as it is.
        if officerId == nil or not seen[officerId] then
            if officerId ~= nil then seen[officerId] = true end

            candidate.tier = nil
            recommended[#recommended + 1] = candidate
        end
    end

    return recommended
end

-- -----------------------------------------------------------------------------
-- What a unit is doing when a call stops being theirs (7.16)
-- -----------------------------------------------------------------------------

--- Why a call stopped being this unit's call.
---
--- Three reasons, and the third is here because two was wrong. `ENDED` used to
--- cover both the call closing and a dispatcher taking a unit off a call that
--- stays open, on the reasoning that from the unit's side those are the same
--- move: a unit left reading `on_scene` at a scene it is not at any more is the
--- same lie either way. That is true of `on_scene` and `en_route`. It is not
--- true of `emergency` (see `CLEARED_BY_CALL`), and because one reason served
--- both situations, the removal path was carrying the closure's rule and
--- standing officers in distress down.
---
--- `ENDED` is the call itself closing under a disposition: `Repo.clearCall`,
--- and nothing else reaches it.
---
--- `RELEASED` is this unit coming off a call that is still open and still
--- somebody's problem. Two callers, both through `Repo.releaseUnits`: a
--- dispatcher pulling a unit off a call (`call.dispatch`'s `removeOfficerIds`)
--- and a unit that signs off the board while it is on one (`events.signOff`).
---
--- `DIVERTED` is the unit being put on *another* call, which is that move seen
--- from the new call -- `Repo.assignUnits` closes whatever else they were live
--- on, because a unit is on one call at a time.
Cad.CALL_ENDED = 'ended'
Cad.CALL_RELEASED = 'released'
Cad.CALL_DIVERTED = 'diverted'

--- The statuses a call put the unit into, which the call is therefore entitled
--- to take back -- and the one status the three reasons disagree about.
---
--- `en_route` and `on_scene` are on all three lists: they are what working
--- *this* call looks like, and they mean nothing once the call is not theirs.
--- Everything else is deliberately absent, and the absences are the content of
--- this table: a unit that went `transporting` or `busy` on the way out of a
--- call has moved on under its own steam, and a call closing behind them must
--- not overwrite what they chose -- 0007 keeps no per-unit arrival columns
--- precisely because the unit's own word is the record.
---
--- **`emergency` is on the `ended` list and on neither of the others**, and
--- that is worth taking one reason at a time, because it was one rule serving
--- all three and the situations are not the same event.
---
---   * *The call closed.* A unit in distress has no other way out of the
---     status: `SUPERVISOR_UNIT_STATUSES` leaves `emergency` off (a supervisor
---     cannot declare somebody else's panic, and cannot undeclare it either)
---     and `SELF_SET_UNIT_STATUSES` leaves it off too, so `enums.ts` says in as
---     many words that "clearing one is done by clearing the call". The panic
---     button raises a call of its own and puts the officer on it
---     (`unit.emergency`), and `ck_fpd_calls_panic_ack` will not let that call
---     close until a supervisor has acknowledged it -- so a closure is the one
---     event in the module that has actually established the emergency is over.
---     If it did not take the status back, the officer who pressed panic would
---     read as in distress on the board for the rest of the shift -- and
---     `Cad.isFree` excludes `emergency`, so they would never be recommended
---     for anything again.
---   * *A dispatcher took them off a call that stays open.* Nothing has been
---     established. The panic call is still open, still unacknowledged and
---     still in the queue; the officer is still wherever they went down. Taking
---     a unit off a call is a dispatcher rearranging who is going where, and an
---     officer with a live panic does not stop having one because their name
---     moved on a board. Clearing it here drops the single status that means
---     somebody needs help right now, and drops it where nobody can see it went:
---     the row reads `available`, the welfare timer restarts from zero, and the
---     dispatcher who would have radioed them has nothing left to look at.
---   * *They were diverted to another call.* The same argument with the same
---     answer. A dispatcher sending a unit to a second call has not established
---     that the first one is over, and a distress flag that another call's
---     dispatch could clear is a distress flag that goes out while the officer
---     is still in the ditch.
---
--- `released` and `diverted` therefore hold the same two statuses today. They
--- are still two entries and not an alias: they are two different things that
--- happen to a unit -- one leaves them on nothing, the other puts them on
--- something -- and the next status that needs a rule will need it for one and
--- not the other. Collapsing them now would make that change look like a typo.
local CLEARED_BY_CALL <const> = {
    ended = { UnitStatus.EN_ROUTE, UnitStatus.ON_SCENE, UnitStatus.EMERGENCY },
    released = { UnitStatus.EN_ROUTE, UnitStatus.ON_SCENE },
    diverted = { UnitStatus.EN_ROUTE, UnitStatus.ON_SCENE },
}

--- The list a reason names, and what an unnamed one falls back to.
---
--- `RELEASED`, the narrow list -- and the fallback changed direction when
--- `emergency` stopped being on every list. The old note argued for the wider
--- one: "a typo that freed a unit is visible on the board within one poll while
--- a typo that stranded one is not". That was true while the widest list held
--- nothing but statuses a unit can set on itself in one press. It is backwards
--- now, because the wider list is the one that clears `emergency` and the two
--- ways of being wrong about a distress flag are not equally visible. A flag
--- wrongly kept is the loudest row on the dispatch board and somebody is on the
--- radio to that unit within a minute; a flag wrongly taken down looks exactly
--- like a unit that is fine. So an unrecognised reason gets the rule that
--- cannot lose one, and the one rule that stands a panic down has to be asked
--- for by name.
---
--- @param reason string|nil
--- @return table the shared list; callers hand out copies
local function clearedBy(reason)
    return CLEARED_BY_CALL[reason] or CLEARED_BY_CALL[Cad.CALL_RELEASED]
end

--- What a unit's status becomes when a call stops being theirs.
---
--- The single owner of that decision. Three statements in `repo.lua` write it
--- -- `clearCall`, `releaseUnits` and the divert inside `assignUnits` -- and
--- before this existed each of them had its own idea: one returned units to
--- `available`, one touched the status not at all, and the third had no opinion
--- because it did not know it was taking a unit off anything.
---
--- Each of those three names its own reason, and naming the wrong one is the
--- defect this function exists to make findable: `releaseUnits` asked for
--- `CALL_ENDED` while the call it was releasing from stayed open.
---
--- @param status string the unit's status now
--- @param reason string|nil `Cad.CALL_ENDED`, `Cad.CALL_RELEASED` (the default)
---   or `Cad.CALL_DIVERTED`
--- @return string|nil `available`, or nil to leave the status where it is
function Cad.statusAfterCall(status, reason)
    local statuses = clearedBy(reason)

    for index = 1, #statuses do
        if statuses[index] == status then return UnitStatus.AVAILABLE end
    end

    return nil
end

--- The same rule as a list, for the one statement that has to name it.
---
--- A SQL `UPDATE … WHERE status IN (…)` cannot call `statusAfterCall` per row,
--- so the repo builds its placeholders from this list and binds these values.
--- The spec asserts the two agree, which is what stops the list and the
--- predicate drifting apart the next time a status is added.
---
--- An unrecognised reason is `RELEASED`; `clearedBy` argues which way that
--- fallback should point and why it used to point the other way.
---
--- Returns a new list; the table above is never handed out.
---
--- @param reason string|nil
--- @return table list of statuses
--- @return string what each one becomes
function Cad.statusesClearedByCall(reason)
    local statuses = clearedBy(reason)
    local list = {}

    for index = 1, #statuses do list[index] = statuses[index] end

    return list, UnitStatus.AVAILABLE
end

-- -----------------------------------------------------------------------------
-- The status timer (7.16)
-- -----------------------------------------------------------------------------

--- How long this unit has held its status, in seconds.
---
--- `status_since` is stamped on a status change and on nothing else -- 0007 is
--- explicit that it is not `ON UPDATE CURRENT_TIMESTAMP(3)`, because the AVL
--- sweep writes the row every second or two and an automatic stamp would reset
--- this timer on every sweep. It would then never fire, and it would never fire
--- for the unit that has stopped moving, which is the only unit it is for.
---
--- @param unit table with `statusSinceUnix`
--- @param now number unix seconds
--- @return number|nil seconds; nil when the row carries no comparable stamp
function Cad.statusAge(unit, now)
    if type(unit) ~= 'table' or type(now) ~= 'number' then return nil end

    local since = tonumber(unit.statusSinceUnix)
    if not since then return nil end

    -- A clock that went backwards reads as "just changed" rather than as a
    -- negative age, which would otherwise read as very recent and be right by
    -- accident, or as very old after an unsigned conversion and be wrong.
    return math.max(now - since, 0)
end

--- The welfare threshold for a status, in seconds, or nil for "never".
---
--- @param status string
--- @param config table|nil as `Cad.settings` returns
--- @return number|nil
function Cad.welfareThreshold(status, config)
    config = config or Cad.defaults

    local seconds = tonumber((config.welfareSeconds or {})[status])
    if not seconds or seconds <= 0 then return nil end

    return seconds
end

--- Should dispatch be asked to check on this unit? (7.16: "a unit on scene too
--- long triggers a welfare-check prompt to dispatch".)
---
--- A pure predicate over one row and one clock, which is what makes it
--- testable and what keeps the board's poll cheap: the query that draws the
--- board is already ordered by `(status, status_since)` through
--- `idx_fpd_units_board`, so the sweep that calls this walks rows it has
--- already read rather than running a query of its own (12.1).
---
--- `promptedAtUnix` is the caller's memory of when it last raised this prompt,
--- and it is deliberately not a column. A prompt is a thing that happened to a
--- dispatcher on a screen, not a fact about the unit; storing it would mean a
--- write to `fpd_units` on the alerting path and a restart would then remember
--- a prompt nobody in the room ever saw. In memory it is the other way round --
--- a restart re-prompts -- which is the right direction to be wrong in for an
--- alert whose whole content is "somebody should say something to this unit".
---
--- @param unit table board row: status, statusSinceUnix, promptedAtUnix
--- @param now number unix seconds
--- @param config table|nil
--- @return boolean
function Cad.needsWelfareCheck(unit, now, config)
    config = config or Cad.defaults

    if type(unit) ~= 'table' then return false end

    local threshold = Cad.welfareThreshold(unit.status, config)
    if not threshold then return false end

    local age = Cad.statusAge(unit, now)
    if not age or age < threshold then return false end

    local prompted = tonumber(unit.promptedAtUnix)

    if prompted then
        local repeatAfter = tonumber(config.welfareRepeatSeconds) or 0

        -- A repeat interval of zero means "prompt once". The unit is still on
        -- the board with its time in status showing; silence after the first
        -- prompt is a decision a server can configure, not one to infer.
        if repeatAfter <= 0 then return false end
        if (now - prompted) < repeatAfter then return false end
    end

    return true
end

--- How long the prompt says the unit has been in status, in whole minutes.
---
--- The `{minutes}` argument of `cad.welfare.body` and `cad.log.welfare_check`.
--- Floored, because "on scene for 21 minutes" reading 22 is a number somebody
--- checks against the timestamp on the call card and finds wrong.
---
--- @param unit table
--- @param now number unix seconds
--- @return number
function Cad.welfareMinutes(unit, now)
    return math.floor((Cad.statusAge(unit, now) or 0) / 60)
end

-- -----------------------------------------------------------------------------
-- Beats: bounding boxes and the ray cast (7.17)
-- -----------------------------------------------------------------------------

--- How far off an edge a point may be and still count as on it.
---
--- The tolerance is on the cross product, which is twice the area of the
--- triangle the point makes with the edge -- so for a 500 m edge this is a
--- lateral tolerance of about 4e-12 metres. That is exact equality in every
--- sense a world coordinate has, and it is meant to be: widening it would turn
--- the boundary into a band, and a band is a strip of map that two beats both
--- claim. Claiming is fine (precedence resolves it, see `beatFor`); a band
--- wide enough to notice would just move the argument somewhere less visible.
local EPSILON <const> = 1e-9

--- Reads one vertex of a polygon.
---
--- `fpd_beats.polygon` is `[[x, y], …]` and nothing else -- the repo decodes
--- the JSON before the polygon reaches this file, because `json.decode` is a
--- runtime global that busted does not have, and a decoder in here would make
--- the whole module untestable to save one line in the repo.
local function vertex(point)
    if type(point) ~= 'table' then return nil, nil end

    local x, y = tonumber(point[1]), tonumber(point[2])
    if not x or not y then return nil, nil end

    return x, y
end

--- The bounding box of a polygon.
---
--- 0007 requires this to be computed here: it is the one derived value in that
--- migration the database cannot compute (deriving it needs `JSON_TABLE`, which
--- is not allowed in a generated column), and no route may accept one from
--- input. The CHECK catches an *inverted* box, but a box that is merely too
--- small is valid SQL and silently stops tagging calls in part of a district --
--- which looks like a quiet beat rather than a bug, and would be found by
--- somebody reading a response-time report six months later.
---
--- @param polygon table `[[x, y], …]`
--- @return table|nil { minX, minY, maxX, maxY }; nil for anything that is not a
---   polygon with at least three usable vertices
function Cad.boundingBox(polygon)
    if type(polygon) ~= 'table' or #polygon < 3 then return nil end

    local minX, minY, maxX, maxY

    for index = 1, #polygon do
        local x, y = vertex(polygon[index])
        if not x then return nil end

        if not minX or x < minX then minX = x end
        if not maxX or x > maxX then maxX = x end
        if not minY or y < minY then minY = y end
        if not maxY or y > maxY then maxY = y end
    end

    return { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

--- Is this point inside the box? The cheap rejection before the ray cast.
---
--- Four double comparisons against thirty districts is what keeps beat tagging
--- inside the 50 ms route budget (12.1), and it is why the box is stored on the
--- row at all. Inclusive on every edge, so it can never reject a point the ray
--- cast would have accepted -- a box that excluded its own boundary would make
--- the boundary handling below unreachable.
---
--- @param box table with minX, minY, maxX, maxY (the beat row will do)
--- @param x number
--- @param y number
--- @return boolean
function Cad.boxContains(box, x, y)
    if type(box) ~= 'table' then return false end

    local minX, maxX = tonumber(box.minX), tonumber(box.maxX)
    local minY, maxY = tonumber(box.minY), tonumber(box.maxY)

    if not minX or not maxX or not minY or not maxY then return false end

    return x >= minX - EPSILON and x <= maxX + EPSILON
        and y >= minY - EPSILON and y <= maxY + EPSILON
end

--- Is the point on the segment `a`-`b`?
---
--- Collinear (the cross product is zero) and between the ends. Both halves are
--- needed: collinearity alone puts every point on the infinite line through the
--- edge inside the polygon, which for a rectangle is two infinite strips.
local function onSegment(ax, ay, bx, by, px, py)
    local cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    if math.abs(cross) > EPSILON then return false end

    return px >= math.min(ax, bx) - EPSILON and px <= math.max(ax, bx) + EPSILON
        and py >= math.min(ay, by) - EPSILON and py <= math.max(ay, by) + EPSILON
end

--- Is the point inside the polygon? (7.17: a call is tagged with its beat.)
---
--- An ordinary ray cast: count the edges a ray going in +x from the point
--- crosses, and an odd count is inside. The polygon is implicitly closed, so
--- the last vertex joins the first and this walks every edge including that one.
---
--- **A point on an edge or on a vertex is inside.** That is the whole of the
--- decision worth writing down here, and it is checked before the crossing
--- count rather than falling out of it, because a ray cast alone answers the
--- boundary case by accident: the standard `(yi > y) ~= (yj > y)` test is
--- half-open in `y`, so a point on a horizontal edge is outside, a point on a
--- vertical edge is inside, and a point exactly on a vertex is whichever the
--- floating-point arithmetic happens to make it. Three different answers for
--- three ways of standing on the same line.
---
--- Inside rather than outside, because 0007 draws districts as adjacent
--- polygons that share their borders, and the failure modes are not symmetric:
--- "in both" is resolved by precedence and a documented tie-break (`beatFor`),
--- while "in neither" is a call with no beat at all, sitting in the middle of a
--- district on the map, absent from every per-beat report and impossible to
--- explain to the person reading one.
---
--- The half-open crossing rule is kept for the interior, and it is what makes
--- the count right at a vertex the ray passes exactly through: without it that
--- vertex is counted once for each of its two edges and the answer flips.
---
--- @param polygon table `[[x, y], …]`, implicitly closed
--- @param x number
--- @param y number
--- @return boolean
function Cad.polygonContains(polygon, x, y)
    if type(polygon) ~= 'table' then return false end

    local count = #polygon
    if count < 3 then return false end
    if type(x) ~= 'number' or type(y) ~= 'number' then return false end

    local inside = false
    local previous = count

    for index = 1, count do
        local ax, ay = vertex(polygon[index])
        local bx, by = vertex(polygon[previous])

        -- A polygon with a malformed vertex is not a polygon. Refusing beats
        -- guessing: a beat that answers "no" everywhere is a beat somebody
        -- notices, and a beat that answers "yes" in half a district is not.
        if not ax or not bx then return false end

        if onSegment(ax, ay, bx, by, x, y) then return true end

        if (ay > y) ~= (by > y) then
            local crossing = ax + (y - ay) / (by - ay) * (bx - ax)

            if x < crossing then inside = not inside end
        end

        previous = index
    end

    return inside
end

--- Is this beat in use? `fpd_beats.enabled` arrives as 1/0 from MariaDB.
local function beatEnabled(beat)
    return beat.enabled == nil or beat.enabled == 1 or beat.enabled == true
end

--- The beat a position falls in (7.17).
---
--- Districts and beats are one table: a district is a large polygon with a low
--- precedence and a beat is a small one inside it with a higher precedence, so
--- the answer is the highest-precedence polygon that contains the point and one
--- routine answers both questions.
---
--- Every beat is bounding-box rejected before its ray cast runs, which is what
--- the four columns on `fpd_beats` are for and what keeps this inside the route
--- budget when an agency has drawn thirty districts (12.1).
---
--- The tie-break -- equal precedence, lowest id -- is what makes a shared
--- border land somewhere rather than nowhere. Two adjacent districts both
--- contain a point on the line between them (see `polygonContains`), and
--- without a stated rule the winner would be whichever the repo's ORDER BY
--- happened to return first, which is a call that changes beat between two
--- readings of the same map. Lowest id means oldest, which is stable for the
--- life of the row.
---
--- @param beats table list of beat rows, each with `polygon` already decoded
--- @param x number
--- @param y number
--- @return table|nil the beat row
function Cad.beatFor(beats, x, y)
    if type(beats) ~= 'table' then return nil end

    local best, bestPrecedence, bestId

    for index = 1, #beats do
        local beat = beats[index]

        if type(beat) == 'table' and beatEnabled(beat) and Cad.boxContains(beat, x, y) then
            local precedence = tonumber(beat.precedence) or 0
            local id = tonumber(beat.id) or 0
            local better = best == nil
                or precedence > bestPrecedence
                or (precedence == bestPrecedence and id < bestId)

            -- The ray cast runs only for a beat that could still win, so a map
            -- of nested districts costs one cast for the district and one for
            -- the beat inside it rather than one per polygon.
            if better and Cad.polygonContains(beat.polygon, x, y) then
                best, bestPrecedence, bestId = beat, precedence, id
            end
        end
    end

    return best
end

-- -----------------------------------------------------------------------------
-- Closing a call, and the narrative log (7.16, 7.16.1)
-- -----------------------------------------------------------------------------

--- The dispositions that close a call as `cancelled` rather than `cleared`.
---
--- 7.16.1 is the evidence: the log line for a `duplicate` or a `cancelled`
--- disposition is `cad.log.cancelled` and not `cad.log.cleared`. The status
--- follows the same reading of Appendix E's "Cleared (disposition); Cancelled" --
--- a call that was a duplicate of another, or that the caller stood down, did
--- not happen, and counting it as a cleared call inflates every response-time
--- and workload report by the calls nobody went to.
---
--- `ck_fpd_calls_disposition` only requires a disposition on a `cleared` call,
--- so writing one on a `cancelled` call is legal and is what keeps the reason
--- readable afterwards.
local CANCELLING <const> = {
    [CallDisposition.DUPLICATE] = true,
    [CallDisposition.CANCELLED] = true,
}

--- How a call closes under this disposition.
---
--- @param disposition string
--- @return string status `cleared` or `cancelled`
--- @return string messageKey the log line (7.16.1)
function Cad.closureFor(disposition)
    if CANCELLING[disposition] then
        return CallStatus.CANCELLED, 'cad.log.cancelled'
    end

    return CallStatus.CLEARED, 'cad.log.cleared'
end

--- The locale key for a generated log line (7.16.1).
---
--- A `note` is what a person typed and goes in `fpd_call_log.body`; every other
--- line is user-facing text the system wrote and goes in `message_key` plus
--- `message_args`, so the NUI renders it in the *reader's* language.
--- `ck_fpd_call_log_content` makes the wrong one impossible to store, and this
--- table is the only place the mapping lives -- the i18n checker cannot see a
--- key assembled at runtime, so a second copy would be a second copy nothing
--- compares.
---
--- Three entry types have two keys, and the `options` flag picks between them:
--- a call raised by the `CreateCall` export names the resource, a unit that
--- attached itself reads differently from one a dispatcher sent, and a
--- cancelling disposition closes the call rather than clearing it.
---
--- @param entryType string a `FredPD.CallLogKind` member
--- @param options table|nil { external, selfAssigned, disposition }
--- @return string|nil messageKey; nil for a note, which carries text instead
function Cad.logMessageKey(entryType, options)
    options = options or {}

    if entryType == CallLogKind.NOTE then return nil end

    if entryType == CallLogKind.CREATED then
        return options.external and 'cad.log.created_external' or 'cad.log.created'
    end

    if entryType == CallLogKind.UNIT_JOINED then
        return options.selfAssigned and 'cad.log.self_assigned' or 'cad.log.unit_joined'
    end

    if entryType == CallLogKind.CLEARED then
        local _, messageKey = Cad.closureFor(options.disposition)

        return messageKey
    end

    return 'cad.log.' .. entryType
end

FredPD.Modules.cad = Cad
