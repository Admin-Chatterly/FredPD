--- Automatic vehicle location: the live map feed (spec 7.17, 3.6, 12.1).
---
--- One job, and one rule that decides the whole shape of it.
---
--- **The rule: no client ever says where a unit is.** The server holds every
--- player's ped and reads `GetEntityCoords` off it, exactly as
--- `forensics/grid.lua` does for the trace grid. There is no route in this
--- milestone that accepts a position, and there must never be one: the officer
--- being asked why they were not at the call they were dispatched to is the
--- same person who would be sending the coordinates that answer it. A false
--- alibi has to be impossible to write, not merely against the rules
--- (invariant 1, and 0007's header says the same thing from the table's side).
---
--- **The job:** while a session has the map open, push it the positions that
--- have moved, at the 1-2 second cadence 3.6 sets.
---
--- ## What this file learned from the trace grid
---
--- `forensics/grid.lua` solved this problem once already and paid for three
--- lessons that are repeated here rather than rediscovered:
---
---   1. **An idle server must cost nothing.** The loop's first statement is an
---      early-out on the subscriber table, so a server with no map open pays one
---      `next` call per interval -- not one ped read per player (budget 12.1).
---   2. **A subscriber is somebody being told something,** not somebody who once
---      asked. A session that closes the map is dropped on the spot, and a
---      session whose permissions changed under it is dropped on the next sweep.
---      The grid's `subscriptions` table filled up with every player who had ever
---      taken a step, and the idle cost it claimed was being paid by everyone.
---   3. **A push that happens is itself information.** An empty delta is never
---      sent: a message arriving at a fixed cadence tells a client that the
---      sweep ran and that somebody, somewhere, is being watched. Only changed
---      units travel, and a unit a session may not see never travels at all.
---
--- ## Why positions are written to the database on a slower beat than they are
--- ## pushed
---
--- `fpd_units` holds the *last known* position (0007), which is what the board
--- shows a dispatcher who has not opened the map and what a call card's
--- recommendation falls back to. Writing it at the push cadence would be one
--- UPDATE per on-duty unit every two seconds for as long as anybody has the map
--- open -- thousands of writes an hour to buy sub-two-second accuracy in a
--- column whose own comment calls it "last known". So the push is live and the
--- write rides every `avlPersistEverySweeps`-th sweep, in one statement.
---
--- The gap that leaves is deliberate and bounded: a unit that has not moved
--- writes nothing, and `position_at` says when the row was read, so a reader can
--- tell a stale position from an unknown one. 0007 is explicit that those are
--- not the same thing.
---
--- ## Why the board is cached here
---
--- The sweep needs one fact the ped cannot give it: which officers are signed on
--- as units, and under what callsign. That is a database read, and doing it
--- every two seconds would be the cost this file exists to avoid. So the board
--- is cached per agency with a short lifetime and `Avl.invalidate` is called by
--- every route that changes it -- 12.2's "in-memory caches ... unit board
--- (invalidated on write)". The cache is only ever filled while somebody is
--- asking for positions, so an idle server never reads the board at all.
---
--- ## What leaves this file, and why only one thing here ever named a call
---
--- The cached board rows carry the five `onCall*` columns `Repo.listUnits`
--- joins off `fpd_calls`, so everything built from them is audited for that.
--- Three things are built from them and exactly one of them was wrong:
---
---   * **`Avl.livePositions` / `Avl.positions`** build a *new* table per unit
---     holding `x`, `y`, `z`, `heading` and `at`. No field is copied across from
---     the row, so no call field can ride along, and callers that want the board
---     itself (`routes.lua`'s `boardWithPositions`) read the rows through the
---     repo and mask them through `board.lua` rather than taking them from here.
---   * **The `fredpd:cad:avl` delta** carries `officerId`, a position and
---     `gone`, and goes only to subscribers re-checked every sweep for
---     `page.dispatch` and the agency. A position is the *unit's* own fact, not
---     the call's -- the same reason `board.boardFor` keeps the row and takes
---     only the call off it -- so there is nothing here to mask.
---   * **The welfare prompt** named the call outright and sent it unchecked.
---     That was the leak; it goes through `board.welfarePush` now, and the
---     comment on `Avl.welfarePass` has the detail.

FredPD = FredPD or {}
FredPD.Cad = FredPD.Cad or {}

local service = FredPD.Modules.cad
local repo = FredPD.Repo.cad
local push = FredPD.Core.push
local perms = FredPD.Core.perms
local sessions = FredPD.Core.session

--- The one owner of "what may a payload carrying a call say, and to whom"
--- (`server/modules/cad/board.lua`, loaded immediately before this file).
---
--- The welfare prompt below used to answer that question itself, by not asking
--- it: it shipped `callId` and `callNumber` for every unit that had been sitting
--- too long to every holder of `cad.unit.manage` in the agency, so a dispatcher
--- who had been correctly refused call 1042 on the queue was handed 1042's id
--- and number a moment later by a message that does not look like a call. The
--- masking rule now lives in exactly one file and this one calls it.
local board = FredPD.Cad.board

local Avl = {}

--- The permission that opens the dispatch map (Appendix B: the dispatch reads
--- have no key of their own). Re-checked on every sweep, not only at subscribe:
--- `session.refreshAll` can take a page away mid-shift, and a feed that keeps
--- running afterwards is a permission change that did not take effect.
local MAP_PERMISSION <const> = 'page.dispatch'

--- The sweep's own settings, on top of the module's.
---
--- `Cad.settings` merges `config/server.lua`'s `cad` table over `Cad.defaults`
--- and keeps any key it does not recognise, so these five live here -- beside
--- the loop that reads them -- and an operator overrides them in the same place
--- as everything else. The service's own keys (`welfareSeconds`,
--- `positionMaxAgeSeconds`, ...) come through the same table.
local DEFAULTS <const> = {
    --- Seconds between pushes. 3.6: "every 1-2 seconds".
    avlIntervalSeconds = 2,
    --- Persist to `fpd_units` every Nth sweep. 5 x 2 s = every ten seconds.
    avlPersistEverySweeps = 5,
    --- Metres a unit must have moved before the map is told. Below this the
    --- marker would not visibly move, so the message would be pure cost.
    avlMoveThreshold = 2.0,
    --- Degrees the heading must have turned, for the same reason.
    avlHeadingThreshold = 10.0,
    --- How long a cached board stands without an explicit invalidation. A floor
    --- under the cache and not the mechanism: every write invalidates it.
    avlBoardTtlSeconds = 10,
    --- Seconds between welfare-check passes (7.16). Far slower than the map,
    --- because the threshold it tests is twenty minutes.
    avlWelfareIntervalSeconds = 30,
}

local config = service.settings(FredPD.Config.server.cad)

for key, value in pairs(DEFAULTS) do
    if type(config[key]) ~= 'number' then config[key] = value end
end

-- Clamped to 3.6's window rather than trusted: a server that sets this to ten
-- seconds has a map that lies about where units are, and one that sets it to
-- 100 ms has a network budget it has not read (12.1).
config.avlIntervalSeconds = math.max(1, math.min(2, config.avlIntervalSeconds))

--- src -> { agencyId, sent = { [officerId] = { x, y, z, heading } } }
---
--- `sent` is what this session has been told, so a delta is a comparison and
--- never a re-send. It is also how a unit that leaves the board is retracted:
--- a key in `sent` with no position this sweep becomes one `gone` entry.
local subscribers = {}

--- agencyId -> { at = os.time(), rows = { … } }
local boards = {}

--- agencyId -> { [officerId] = { x, y, z, heading, at } }
---
--- The last position read off each ped. Read by the call card's unit
--- recommendation (7.16) as well as by the sweep, which is why it outlives one
--- pass: a dispatcher opening a card must not have to wait for the map to be
--- open somewhere for the recommendation to have anything to sort by.
local positions = {}

--- How many sweeps have run, so the database write can ride every Nth one.
local sweepCount = 0

-- -----------------------------------------------------------------------------
-- The board
-- -----------------------------------------------------------------------------

--- The units of one agency, from cache when it is fresh.
---
--- Rows carry `officerId`, `discordId`, `callsign`, `status`, `statusSinceUnix`,
--- the stored position and -- the part that matters -- the five `onCall*`
--- columns `Repo.listUnits` joins off `fpd_calls`. So a row out of here is a
--- call payload wearing a unit's clothes, and nothing this function returns may
--- leave the server without going through `board.lua` first.
---
--- Nothing here decides who may see a row; it is a cache in front of one query.
--- Named `cachedBoard` and not `board`, which it was, because `board` now names
--- the module that owns the access rule: two different things called the same
--- word in one file is how the welfare prompt came to ship call numbers while
--- the file beside it was masking them.
local function cachedBoard(agencyId)
    local cached = boards[agencyId]

    if cached and (os.time() - cached.at) < config.avlBoardTtlSeconds then
        return cached.rows
    end

    -- No status filter, so `listUnits` excludes `off_duty` for us: the board is
    -- who is working, and a signed-off row keeps its place only so the officer
    -- comes back to the same unit after a reconnect (0007).
    local rows = repo.listUnits(agencyId, { limit = 500 }) or {}
    boards[agencyId] = { at = os.time(), rows = rows }

    return rows
end

--- Forgets the cached board for an agency.
---
--- Called by every route that signs a unit on or off, moves its status or
--- renames it. Cheap and unconditional: a board read costs one query and a
--- board that is wrong for ten seconds is a dispatcher looking at a unit who is
--- no longer there.
function Avl.invalidate(agencyId)
    if agencyId == nil then
        boards = {}
        return
    end

    boards[agencyId] = nil
end

-- -----------------------------------------------------------------------------
-- Reading positions off peds
-- -----------------------------------------------------------------------------

--- Every connected session, keyed by the Discord id the unit row carries.
---
--- `fpd_units.discord_id` is the identity the server resolved from the session
--- when the unit signed on, so this is the join between "who is on the board"
--- and "whose ped is loaded". Built once per sweep rather than once per unit.
local function sessionsByDiscord()
    local byDiscord = {}

    for src, session in pairs(sessions.all()) do
        if session.discordId then
            byDiscord[session.discordId] = src
        end
    end

    return byDiscord
end

--- Reads the current position of every on-duty unit of one agency.
---
--- The answer is keyed by `fpd_units.officer_id`, which is the only identifier a
--- unit has (0007: the table has no `id` column).
---
--- A unit whose officer is not connected, or whose ped has not spawned, is
--- absent rather than zeroed: `ck_fpd_units_position` requires all three
--- coordinates or none, and a marker at the origin is worse than no marker --
--- the closest-unit recommendation would offer it first.
---
--- @param agencyId string
--- @return table officerId -> { x, y, z, heading, at }
function Avl.livePositions(agencyId)
    local rows = cachedBoard(agencyId)
    if #rows == 0 then
        positions[agencyId] = {}
        return positions[agencyId]
    end

    local byDiscord = sessionsByDiscord()
    local current = {}

    for index = 1, #rows do
        local unit = rows[index]
        local src = unit.discordId and byDiscord[unit.discordId] or nil

        if src then
            local ped = GetPlayerPed(src)

            if ped ~= 0 then
                local at = GetEntityCoords(ped)

                current[unit.officerId] = {
                    x = at.x,
                    y = at.y,
                    z = at.z,
                    heading = GetEntityHeading(ped),
                    at = os.time(),
                }
            end
        end
    end

    positions[agencyId] = current

    return current
end

--- The last positions read for an agency, without reading any ped.
---
--- For callers that want whatever is already known and must not pay for a
--- sweep -- a list route drawing a board, say. Empty until something has swept.
function Avl.positions(agencyId)
    return positions[agencyId] or {}
end

-- -----------------------------------------------------------------------------
-- Subscriptions
-- -----------------------------------------------------------------------------

--- The map is open: start sending this session positions (3.6).
---
--- Takes the session rather than a server id, so the agency comes from the
--- server's own copy of who this is and never from the call (invariant 1).
function Avl.subscribe(session)
    if not session or not session.src then return end

    subscribers[session.src] = { agencyId = session.agencyId, sent = {} }
end

--- The map is closed. Nothing more is sent, and the next open starts from a
--- full snapshot rather than from a delta against what the client has forgotten.
function Avl.unsubscribe(src)
    subscribers[src] = nil
end

--- How many sessions are being pushed to. Read by tests and by the health
--- screen; it is the number the idle cost in 12.1 turns on.
function Avl.subscriberCount()
    local count = 0
    for _ in pairs(subscribers) do count = count + 1 end

    return count
end

--- Has this unit moved enough to be worth a message?
---
--- Called with the last position this session was told and the one just read.
local function moved(previous, now)
    if not previous then return true end

    local dx = now.x - previous.x
    local dy = now.y - previous.y
    local dz = now.z - previous.z

    if (dx * dx + dy * dy + dz * dz) >= (config.avlMoveThreshold * config.avlMoveThreshold) then
        return true
    end

    local turn = math.abs((now.heading or 0.0) - (previous.heading or 0.0))
    if turn > 180.0 then turn = 360.0 - turn end

    return turn >= config.avlHeadingThreshold
end

--- One session's delta, or nil when there is nothing to say.
---
--- `gone` is how a unit leaves the map: signed off, or no longer connected. It
--- is sent once, because the key is dropped from `sent` with it.
local function deltaFor(subscription, current)
    local changed = {}
    local sent = subscription.sent

    for officerId, position in pairs(current) do
        if moved(sent[officerId], position) then
            changed[#changed + 1] = {
                officerId = officerId,
                x = position.x,
                y = position.y,
                z = position.z,
                heading = position.heading,
                at = position.at,
            }

            sent[officerId] = position
        end
    end

    for officerId in pairs(sent) do
        if current[officerId] == nil then
            changed[#changed + 1] = { officerId = officerId, gone = true }
            sent[officerId] = nil
        end
    end

    if #changed == 0 then return nil end

    return changed
end

--- One pass: read the peds, push the deltas, and every Nth pass write the rows.
---
--- Agencies with no subscriber are not swept at all. FredPD is multi-agency and
--- a sheriff's dispatcher opening their map must not make the city pay for it.
function Avl.sweep()
    sweepCount = sweepCount + 1

    local wanted = {}

    for src, subscription in pairs(subscribers) do
        local session = sessions.all()[src]

        -- Gone, or no longer allowed to look. Both are dropped here rather than
        -- filtered at the push, so `subscribers` stays "sessions being told
        -- something" and the early-out in the loop below stays honest.
        if not session
            or session.agencyId ~= subscription.agencyId
            or not perms.satisfies(session.permissions, MAP_PERMISSION)
        then
            subscribers[src] = nil
        else
            wanted[subscription.agencyId] = true
        end
    end

    local persist = (sweepCount % math.max(1, config.avlPersistEverySweeps)) == 0

    for agencyId in pairs(wanted) do
        local current = Avl.livePositions(agencyId)

        if persist then
            local rows = {}

            for officerId, position in pairs(current) do
                rows[#rows + 1] = {
                    officerId = officerId,
                    x = position.x,
                    y = position.y,
                    z = position.z,
                    heading = position.heading,
                }
            end

            if #rows > 0 then repo.savePositions(agencyId, rows) end
        end

        for src, subscription in pairs(subscribers) do
            if subscription.agencyId == agencyId then
                local changed = deltaFor(subscription, current)

                -- Nothing moved, so nothing is sent. A message on a timer is a
                -- message that says the timer exists.
                if changed then
                    push.toSession(src, 'fredpd:cad:avl', {
                        units = FredPD.markArrays(changed),
                    })
                end
            end
        end
    end
end

-- -----------------------------------------------------------------------------
-- The welfare check (7.16: "a unit on scene too long triggers a welfare-check
-- prompt to dispatch")
-- -----------------------------------------------------------------------------

--- Who may be asked to check on a unit: `board.WELFARE`, which is
--- `cad.unit.manage` (7.16 says "to dispatch", and that is the key dispatch,
--- supervisor and command hold -- Appendix B).
---
--- Borrowed from `board.lua` rather than written out again, and that is not
--- tidiness. `board.welfarePush` decides who the prompt is *sent* to; the pass
--- below decides which agencies are swept for one at all, by looking for a
--- session holding the same key. Two copies of the string would keep agreeing
--- right up until somebody renamed the permission in one place, and the failure
--- then is silent in both directions: either every agency is swept and the
--- prompt reaches nobody, or no agency is swept and an officer sits at a scene
--- with the one alert that exists to notice it never firing.
local WELFARE_PERMISSION <const> = board.WELFARE

--- agencyId -> officerId -> when this unit was last prompted about.
---
--- In memory and not a column, which `Cad.needsWelfareCheck` argues for at
--- length: a prompt is something that happened to a dispatcher on a screen, not
--- a fact about the unit. Storing it would put a write to `fpd_units` on the
--- alerting path, and a restart would remember a prompt nobody in the room saw.
--- In memory a restart re-prompts, which is the right direction to be wrong in
--- for an alert whose whole content is "somebody should say something to them".
local prompted = {}

--- One pass over the boards of the agencies that have somebody to tell.
---
--- Nothing here queries: `Cad.needsWelfareCheck` is a pure predicate over a row
--- the cached board already holds, which is what keeps this off the 50 ms budget
--- (12.1) and why it can run on its own slow timer without a poll behind it.
---
--- No log line is written. `cad.log.welfare_check` exists as a string, but
--- `ck_fpd_call_log_type` has no entry type that fits it -- the spec's own open
--- question (7.16.1, and the gap table in section 13) -- and inventing one would
--- be this file deciding a question the migration left open.
---
--- ## The row this builds still names a call, and that is deliberate
---
--- `due` carries `callId` and `callNumber` because the prompt's own screen wants
--- them when the reader is allowed them. What it must not do is *send* them
--- unchecked, which is what it did: one `push.toPermission` of the whole list to
--- every `cad.unit.manage` holder in the agency, so a dispatcher refused call
--- 1042 on the queue read 1042's number off the welfare prompt seconds later.
--- `board.welfarePush` now takes the list and does the masking per recipient.
---
--- The masking takes the call fields off and keeps the row. That is the whole
--- point of the check and it is worth saying out loud: a welfare prompt is about
--- the **officer**, not the call -- somebody has been on the same status for
--- twenty-five minutes and should be spoken to. Dropping the row because the
--- call behind it is classified would turn a classification into a reason nobody
--- checks on an officer, which is a far worse outcome than a supervisor learning
--- that a unit they cannot follow is busy. So the officer, the callsign, the
--- status and the minutes reach every holder of the key; only the call comes
--- off, and only for the readers who were refused it anyway.
function Avl.welfarePass()
    local watching = {}

    for _, session in pairs(sessions.all()) do
        if perms.satisfies(session.permissions, WELFARE_PERMISSION) then
            watching[session.agencyId] = true
        end
    end

    -- Nobody to tell. Not merely a cheap pass: prompting into an empty room and
    -- remembering that it happened would use up the repeat interval, so the
    -- dispatcher who signs on a minute later would hear nothing for ten.
    if next(watching) == nil then return end

    local now = os.time()

    for agencyId in pairs(watching) do
        local rows = cachedBoard(agencyId)
        local seen = prompted[agencyId] or {}
        local kept, due = {}, {}

        for index = 1, #rows do
            local unit = rows[index]

            -- A view rather than the row itself: `cachedBoard` hands out the
            -- cached table, and writing the prompt time onto it would make the
            -- cache carry state that belongs to this pass.
            local view = {
                status = unit.status,
                statusSinceUnix = unit.statusSinceUnix,
                promptedAtUnix = seen[unit.officerId],
            }

            if service.needsWelfareCheck(view, now, config) then
                -- A fresh table, not a slice of `unit`: the row above belongs to
                -- the cache, and `board.welfarePush` may hand what we build here
                -- to several recipients. The two call fields are named rather
                -- than aliased with the board's `onCall` prefix, which is why
                -- `board.lua` keeps a hand-written list for this one payload --
                -- a third call field added here has to be added there too.
                due[#due + 1] = {
                    officerId = unit.officerId,
                    callsign = unit.callsign,
                    callId = unit.onCallId,
                    callNumber = unit.onCallNumber,
                    status = unit.status,
                    minutes = service.welfareMinutes(view, now),
                }

                kept[unit.officerId] = now
            elseif seen[unit.officerId] then
                -- Still on the board, still inside the repeat interval: keep the
                -- memory so the next pass does not prompt again.
                kept[unit.officerId] = seen[unit.officerId]
            end
        end

        -- Units that left the board drop out with the table they were in, so
        -- this never grows with everyone who has ever been on scene.
        prompted[agencyId] = next(kept) and kept or nil

        -- One call, and every decision about who sees what is behind it: the
        -- permission, the agency, the per-recipient masking and `markArrays`.
        -- Note there is no complementary two-push here the way there is for a
        -- unit row -- this list names many different calls, so a supervisor
        -- cleared for one and refused another belongs to neither half of any
        -- split. `board.welfarePush` builds the payload per recipient for that
        -- reason, and skips the copies entirely on the common pass where nobody
        -- due a check is on a call at all.
        if #due > 0 then board.welfarePush(agencyId, due) end
    end
end

-- -----------------------------------------------------------------------------
-- Timers
-- -----------------------------------------------------------------------------

--- The push loop.
---
--- The early-out is the first statement, and it is the whole of the idle cost:
--- with no map open anywhere the pass is one `next` call. Nothing here reads a
--- ped, touches the database or allocates until a dispatcher opens the map.
CreateThread(function()
    local interval = math.max(math.floor(config.avlIntervalSeconds * 1000), 1000)

    while true do
        Wait(interval)

        if next(subscribers) ~= nil then Avl.sweep() end
    end
end)

--- The welfare timer (7.16).
---
--- Its own loop rather than a counter inside the one above, because the two are
--- unrelated: the map runs while somebody is looking at it and this runs while
--- somebody is on duty, and a unit sitting too long at a scene is exactly the
--- case where nobody has the map open.
CreateThread(function()
    local interval = math.max(math.floor(config.avlWelfareIntervalSeconds * 1000), 5000)

    while true do
        Wait(interval)

        Avl.welfarePass()
    end
end)

AddEventHandler('playerDropped', function()
    Avl.unsubscribe(source)
end)

FredPD.Cad.avl = Avl
