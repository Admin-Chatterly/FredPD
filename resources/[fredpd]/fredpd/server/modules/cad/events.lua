--- Sign-on: how an officer becomes a unit on the board (spec 7.1, 7.16; 0007).
---
--- Every other file in this module answers a question about a unit that already
--- exists. This one is the only thing in the suite that makes one exist, and
--- until it did, `call.self_assign`, `call.status`, `unit.status` and
--- `unit.emergency` all answered `CONFLICT` + `no_unit` for every officer on the
--- server: `ownUnit` in `routes.lua` reads `fpd_units` by the session's officer
--- id, and nothing wrote a row there.
---
--- ## Sign-on is not a route, and must not become one
---
--- There is no `unit.signOn` schema and nothing here is reachable from a client.
--- A unit row asserts "this officer is working", and that is a fact the server
--- can see for itself: duty comes from p_policejob through the bridge (3.11,
--- ADR-008), the officer, the agency and the callsign come from the session
--- (4.6), and the position is read off the ped by the AVL sweep. A route would
--- add nothing except a way for a client to put a callsign on the board that
--- nobody is behind -- and `fpd_units` is what a dispatcher reads before sending
--- somebody to a robbery. So this file registers no `RegisterNetEvent`
--- (invariant 3) and takes no input at all.
---
--- ## Why duty is polled rather than hooked
---
--- Neither bridge raises an event when duty changes: `policejob.isOnDuty` is a
--- question and `framework.getCharacter` reads a metadata flag. The event that
--- would replace this poll is `esx:setJob`, and naming it here would put
--- es_extended in a module file, which is the one thing the bridge layer exists
--- to prevent (spec 3.8). So this asks, on a slow timer, and the ask is shaped
--- so that an idle server pays for nothing:
---
---   * the loop's first statement is an early-out on "is anybody connected",
---     the same shape `avl.lua` and `forensics/grid.lua` use (12.1);
---   * a pass compares each session's duty against what it was last seen as and
---     writes **only on a change**, so the steady state is one cheap bridge call
---     per connected officer every `dutyPollSeconds` and no SQL at all.
---
--- The poll interval is also the worst-case delay between an officer going on
--- duty and appearing on the board. Fifteen seconds is well inside the time it
--- takes to walk out of the station, and a faster poll buys nothing a dispatcher
--- would notice.
---
--- ## The four moments a unit appears or disappears
---
---   1. **Going on duty.** An off -> on transition signs the unit on.
---   2. **A session that opens while the officer is *already* on duty.** This is
---      the common case, not the edge one: a client restart, a resource restart,
---      and the whole server coming back up all land here. It is the same code
---      path, because the pass compares against "what we last saw" and an
---      officer we have never seen is an officer whose first observation is a
---      transition. Handling only the transition would leave a reconnecting
---      officer invisible to dispatch until they toggled duty off and on again,
---      which is the bug this note exists to prevent.
---   3. **Going off duty**, which signs the unit off at once.
---   4. **Dropping from the server** without going off duty first -- a crash, an
---      alt-F4, a timeout. This one does *not* sign off at once; see below.
---
--- ## A crash is not a sign-off, and a grace period is what tells them apart
---
--- 0007 is explicit that a unit is per officer and not per session "precisely so
--- that an officer whose game crashed mid-call comes back as the same unit, on
--- the same call, with the same time in status". Signing off on `playerDropped`
--- would make that sentence false: the officer reconnects to a row that reports
--- them as having gone available at the moment their game crashed, and the
--- welfare timer for a unit lying in a ditch restarts.
---
--- So a drop starts a clock instead. Come back inside `signOffGraceSeconds` and
--- nothing happened: the row still says `on_scene`, `status_since` never moved,
--- and the call still has them on it. Stay away past it and the unit is signed
--- off exactly as if they had gone off duty, because by then they are not coming
--- back to this shift.
---
--- ## A unit that goes off duty on a call is taken off the call
---
--- The decision, and the reasoning, because it is a decision and not an
--- oversight. Three options, and only one of them leaves the board and the call
--- card agreeing:
---
---   * Leave the assignment open. The unit drops off the board (`listUnits`
---     excludes `off_duty`) while `fpd_call_units.active` still says they are
---     working the call, so the queue shows a call with a unit on it that
---     nobody can see, and `uq_fpd_call_units_live` refuses to let anybody else
---     take that slot. That is the worst of the three and it is what doing
---     nothing gives you.
---   * Clear the call. Not ours to decide: a unit going home does not mean the
---     robbery is over, and it would close a call with a disposition nobody
---     chose.
---   * **Take the unit off the call and leave the call open.** `releaseUnits`
---     stamps `left_at`, drops the lead flag and writes a `unit_left` line
---     signed by the officer, so the narrative records that they left rather
---     than that they were never there -- and the call goes back to the queue
---     with no units, where a dispatcher sees it and sends somebody else.
---
--- ## The boot sweep (0007 requires it)
---
--- `fpd_units` survives a restart and a restart destroys every session, so after
--- one, every row on the board is a ghost that nothing can contradict. The sweep
--- sets them all `off_duty`, which is deliberately a status nobody asked for:
--- a board that has forgotten a real unit is corrected within one poll, and a
--- board still showing a unit who left two hours ago sends somebody to a call
--- nobody is going to.

FredPD = FredPD or {}
FredPD.Cad = FredPD.Cad or {}

local service = FredPD.Modules.cad
local repo = FredPD.Repo.cad
local avl = FredPD.Cad.avl
local accessRules = FredPD.Modules.access
local sessions = FredPD.Core.session
local perms = FredPD.Core.perms
local push = FredPD.Core.push
local policejob = FredPD.Bridge.policejob

local Events = {}

-- -----------------------------------------------------------------------------
-- Who is a unit
-- -----------------------------------------------------------------------------

--- The key that means "this person's unit reports a status" (Appendix B).
---
--- Held from `patrol_basic` upward, so every officer who works the street has
--- it. It is the test rather than duty alone because a unit row whose owner
--- cannot move it is worse than no row: the board would show an available unit
--- that can never say it is busy, and the recommendation would offer it first.
--- It also keeps the groups that do not inherit patrol at all -- `admin`,
--- `evidence_tech`, `property_officer`, `lab_analyst`, the intelligence groups
--- -- off the board, which is right: a forensic analyst on duty in the lab is
--- not a car a dispatcher can send to a robbery.
local UNIT_PERMISSION <const> = 'cad.unit.status'

--- The dispatcher's own key, and the one thing that disqualifies a unit.
---
--- The seed says it in as many words: "a dispatcher is not a unit, has no
--- `fpd_units` row and has nowhere to be dispatched to", and `routes.lua` builds
--- `no_unit` on the same understanding. `dispatch` inherits `cad.unit.status`
--- through `patrol_basic`, so the inherited key is not enough to tell the two
--- apart; `cad.console.open` is granted to `dispatch` and to nothing else, which
--- makes it the one fact in Appendix B that distinguishes a console operator
--- from a car.
---
--- Somebody holding both -- a dispatcher who also patrols -- is treated as a
--- dispatcher and does not go on the board. That is the safe direction: a unit
--- who is missing from the board asks dispatch to add them, and a console
--- operator sitting on the board gets sent to a shooting.
local CONSOLE_PERMISSION <const> = 'cad.console.open'

--- Who is told that the board changed (Appendix B: the dispatch reads have no
--- key of their own). The same permission `routes.lua` pushes `fredpd:cad:unit`
--- on, because this is the same message.
local BOARD_PERMISSION <const> = 'page.dispatch'

-- -----------------------------------------------------------------------------
-- Settings
-- -----------------------------------------------------------------------------

--- This file's own settings, on top of the module's.
---
--- `Cad.settings` merges `config/server.lua`'s `cad` table over `Cad.defaults`
--- and keeps any key it does not recognise, so these three live here -- beside
--- the loop that reads them -- exactly as `avl.lua`'s five do.
local DEFAULTS <const> = {
    --- Seconds between duty passes, and therefore the worst case between going
    --- on duty and appearing on the board.
    dutyPollSeconds = 15,

    --- How long a disconnected unit keeps its place before it is signed off.
    ---
    --- Long enough to cover a crash, a game restart and a reconnect -- which is
    --- what 0007's "comes back as the same unit, on the same call, with the
    --- same time in status" is asking for -- and short enough that a unit who
    --- went home is off the board before the next call is stacked behind them.
    signOffGraceSeconds = 5 * 60,

    --- Whether duty is required to be a unit (7.1: "duty integration ...
    --- configurable").
    ---
    --- True is the correct setting and the default. `false` is for a server
    --- that models no duty at all: `policejob.isOnDuty` fails closed by design
    --- (an unknown answer is "off duty"), so on such a server nobody would ever
    --- reach the board and the whole of M4 would look broken. With it off, an
    --- officer holding the keys above is a unit for as long as they are
    --- connected.
    dutyRequired = true,
}

local config = service.settings(FredPD.Config.server.cad)

for key, value in pairs(DEFAULTS) do
    if type(config[key]) ~= type(value) then config[key] = value end
end

-- A floor rather than trust: a one-second duty poll would be a bridge call per
-- connected officer per second to answer a question whose answer changes twice
-- a shift.
config.dutyPollSeconds = math.max(5, config.dutyPollSeconds)
config.signOffGraceSeconds = math.max(0, config.signOffGraceSeconds)

-- -----------------------------------------------------------------------------
-- What this file remembers
-- -----------------------------------------------------------------------------

--- officerId -> { src, agencyId, discordId, callsign, onDuty }
---
--- What the last pass saw, so a pass writes only on a change. It carries its own
--- copy of the session fields rather than the session, because `playerDropped`
--- runs after `core/session.lua` has already dropped the session -- that handler
--- is registered first, since its file loads first -- so by the time this file
--- hears about a disconnect there is nothing left to read.
local known = {}

--- src -> officerId, so the drop handler can find the entry above without a
--- session to ask.
local bySrc = {}

--- officerId -> { at, agencyId, discordId, callsign }
---
--- Units whose officer dropped and whose grace period is running.
local dropped = {}

--- Officers whose roster row has no callsign, so the console line is printed
--- once rather than every pass.
local warned = {}

--- Set by the boot sweep. Nothing signs anybody on before the ghosts are gone,
--- or the sweep would sign off a unit this file had just signed on.
local booted = false

-- -----------------------------------------------------------------------------
-- Telling the screens
-- -----------------------------------------------------------------------------

--- Tells the boards of one agency that a unit row changed.
---
--- Deliberately the same two tests `unitChanged` in `routes.lua` applies -- the
--- page permission and the agency read off the *recipient's* session -- and not
--- a call to it, because that helper is a local in a file that is not ours to
--- change. A unit row carries no classification, so there is no third test to
--- apply; the payload is a callsign, a status and a position, and everybody who
--- may open the board may see all three.
---
--- Never `-1` (invariant 5).
local function unitChanged(agencyId, unit)
    avl.invalidate(agencyId)

    if not unit then return end

    push.toPermission(BOARD_PERMISSION, 'fredpd:cad:unit', FredPD.markArrays({ unit = unit }),
        function(session)
            return session.agencyId == agencyId
        end)
end

--- Tells the sessions that may read a call that it changed.
---
--- The same filter `callChanged` in `routes.lua` applies, for the same reason as
--- above, and with the access check it carries: a call is a record with a
--- classification, and a push is a read nobody asked for (invariants 4 and 5).
local function callChanged(agencyId, call)
    if not call then return end

    push.toPermission(BOARD_PERMISSION, 'fredpd:cad:call', FredPD.markArrays({ call = call }),
        function(session)
            if session.agencyId ~= agencyId then return false end

            return accessRules.canRead(accessRules.reader(session), call)
        end)
end

-- -----------------------------------------------------------------------------
-- Signing on and off
-- -----------------------------------------------------------------------------

--- Is this session one that belongs on the board at all?
---
--- Re-read on every pass rather than once at sign-on, so a permission taken away
--- mid-shift takes effect -- `session.refreshAll` can do that at any moment, and
--- `avl.sweep` drops its subscribers on the same test for the same reason.
local function eligible(session)
    if not session.officerId or not session.agencyId then return false end
    if perms.satisfies(session.permissions, CONSOLE_PERMISSION) then return false end

    return perms.satisfies(session.permissions, UNIT_PERMISSION)
end

--- Is this officer working right now?
local function onDuty(src, session)
    if not eligible(session) then return false end
    if not config.dutyRequired then return true end

    return policejob.isOnDuty(src) == true
end

--- Puts a unit on the board.
---
--- `beat_id` and `division` are left alone: 7.1 lists them as part of unit
--- log-on and `fpd_officers` holds neither, so there is nothing here to write
--- them from. A supervisor sets both with `unit.manage`, which is also the only
--- thing that can, and the column is NULL until they do rather than filled with
--- a guess.
---
--- `vehicle_plate` and `vehicle_model` are left alone for a harder reason: the
--- plate is readable on the client and nowhere else, and no route may accept one
--- (invariant 1) -- an officer who could send a plate could put another unit's
--- car on their own row. Server-side the vehicle is a model *hash* with no name
--- to show a dispatcher. So 7.1's "vehicle (auto-detected when in an agency
--- vehicle)" is an honest gap in M4 rather than a wrong value on the board, and
--- the milestone report says so.
---
--- One consequence worth knowing: `Repo.signOn`'s duplicate-key branch writes
--- the session's callsign over the row's, so a callsign a supervisor corrected
--- with `unit.manage` goes back to the roster's when its officer reconnects.
--- That is the right way round -- `fpd_officers.callsign` is the roster and a
--- shift-local correction should not outlive the shift -- but it is a rule
--- somebody will meet without expecting it.
---
--- @param entry table { officerId, agencyId, discordId, callsign }
local function signOn(entry)
    -- `fpd_units.callsign` is NOT NULL with a non-blank CHECK and
    -- `fpd_officers.callsign` is nullable, so an officer nobody has given a
    -- callsign cannot be a unit. Refusing here turns that into one console line
    -- naming the officer; letting it reach the INSERT turns it into a constraint
    -- violation every fifteen seconds for as long as they are connected.
    if type(entry.callsign) ~= 'string' or entry.callsign:match('^%s*$') then
        if not warned[entry.officerId] then
            warned[entry.officerId] = true
            print(('[fredpd] cad: officer %d has no callsign, so they cannot go on the unit board. Set one on their roster row.')
                :format(entry.officerId))
        end

        return false
    end

    -- Not checked for rows affected. `Repo.signOn` is an upsert whose
    -- duplicate-key branch writes nothing at all for an officer reconnecting to
    -- a row that is already correct, and MariaDB reports that as zero -- which
    -- is success, not failure. What matters afterwards is that the row exists.
    repo.signOn(entry.agencyId, {
        officerId = entry.officerId,
        discordId = entry.discordId,
        callsign = entry.callsign,
    })

    unitChanged(entry.agencyId, repo.getUnit(entry.agencyId, entry.officerId))

    return true
end

--- Takes a unit off the board, and off whatever call it was working.
---
--- @param entry table { officerId, agencyId, discordId, callsign }
local function signOff(entry)
    -- The call first. If this stopped half way the board would still show them,
    -- which is the state a dispatcher can act on; the other order leaves a call
    -- held by a unit nobody can see (see the header).
    local assignment = repo.activeAssignment(entry.agencyId, entry.discordId)

    if assignment then
        local actor = {
            officerId = entry.officerId,
            discordId = entry.discordId,
            callsign = entry.callsign,
        }

        -- Signed by the officer themselves, because this is their own unit
        -- leaving: the line reads as the unit coming off the call, which is
        -- what happened, and not as a supervisor having pulled them.
        repo.releaseUnits(entry.agencyId, assignment.callId, { actor }, actor)
        callChanged(entry.agencyId, repo.getCall(entry.agencyId, assignment.callId))
    end

    repo.setUnitStatus(entry.agencyId, entry.officerId, FredPD.UnitStatus.OFF_DUTY)

    -- The row is kept rather than deleted (0007): it is what an officer comes
    -- back to. `listUnits` leaves `off_duty` off the board without being asked.
    unitChanged(entry.agencyId, repo.getUnit(entry.agencyId, entry.officerId))
end

-- -----------------------------------------------------------------------------
-- The duty pass
-- -----------------------------------------------------------------------------

--- One pass over the open sessions and the grace clocks.
---
--- Writes only where something changed. A server where nobody's duty moved
--- costs one bridge call per connected officer and no SQL.
function Events.pass()
    if not booted then return end

    local now = os.time()

    for src, session in pairs(sessions.all()) do
        local officerId = session.officerId

        if officerId then
            -- Back inside the grace period: the drop never happened as far as
            -- the board is concerned, and the row still carries their status,
            -- their time in status and their call.
            dropped[officerId] = nil

            local before = known[officerId]
            local working = onDuty(src, session)

            local entry = before or {}
            entry.officerId = officerId
            entry.src = src
            entry.agencyId = session.agencyId
            entry.discordId = session.discordId
            entry.callsign = session.callsign

            if working and not (before and before.onDuty) then
                -- A transition, and an officer we have never seen is one too:
                -- that is the reconnect case, and it is why this compares
                -- against memory rather than watching for an edge.
                entry.onDuty = signOn(entry)
            elseif not working and before and before.onDuty then
                signOff(before)
                entry.onDuty = false
            elseif before == nil then
                entry.onDuty = false
            end

            -- A unit a supervisor signed off with `unit.manage` while its
            -- officer is still on duty in the job stays off: this pass sees no
            -- transition, so it writes nothing. Re-signing them on would undo a
            -- supervisory decision every fifteen seconds.
            known[officerId] = entry
            bySrc[src] = officerId
        end
    end

    for officerId, entry in pairs(dropped) do
        if (now - entry.at) >= config.signOffGraceSeconds then
            dropped[officerId] = nil
            signOff(entry)
        end
    end
end

-- -----------------------------------------------------------------------------
-- Disconnects
-- -----------------------------------------------------------------------------

--- A player left. Start the clock; do not sign them off yet (see the header).
---
--- `core/session.lua` has already dropped the session by the time this runs --
--- its handler is registered first because its file loads first -- so
--- everything this needs comes out of `known`.
AddEventHandler('playerDropped', function()
    local src = source
    local officerId = bySrc[src]

    bySrc[src] = nil
    if not officerId then return end

    local entry = known[officerId]
    known[officerId] = nil

    if not entry or not entry.onDuty then return end

    dropped[officerId] = {
        -- `officerId` is not decoration here: it is the column `signOff` keys
        -- its only UPDATE on. Every other entry that reaches `signOff` comes
        -- from `known`, which carries it; this one is built by hand, and
        -- without it the UPDATE matched zero rows and a dropped officer stayed
        -- on the board forever, available, at the position they left at.
        officerId = officerId,
        at = os.time(),
        agencyId = entry.agencyId,
        discordId = entry.discordId,
        callsign = entry.callsign,
    }
end)

-- -----------------------------------------------------------------------------
-- Boot and the timer
-- -----------------------------------------------------------------------------

--- The boot sweep (0007), on the tick after the resource starts.
---
--- A thread rather than the handler body, so this runs after every other
--- `onResourceStart` handler has finished -- `server/main.lua`'s among them. It
--- is the one that verifies `fpd_units` exists and names the missing migration
--- if it does not, and an oxmysql error from this sweep arriving first would
--- bury that message under a stack trace about a table the operator has never
--- heard of.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= FredPD.resource then return end

    CreateThread(function()
        Wait(0)

        local affected = repo.signOffAllUnits()

        -- Every agency: a restart is not per agency, and neither is the board
        -- cache behind the map.
        avl.invalidate()
        booted = true

        if affected and affected > 0 then
            print(('[fredpd] cad: %d unit row(s) left over from the last run signed off. Anyone still on duty is back within %d s.')
                :format(affected, config.dutyPollSeconds))
        end
    end)
end)

--- The duty timer.
---
--- The early-out is the first statement and it is the whole of the idle cost: on
--- a server with nobody connected this is one `next` call every fifteen seconds
--- and nothing else. `dropped` is checked too, because a grace period has to
--- expire on a server the last officer has just left.
CreateThread(function()
    local interval = math.max(math.floor(config.dutyPollSeconds * 1000), 5000)

    while true do
        Wait(interval)

        if booted and (next(sessions.all()) ~= nil or next(dropped) ~= nil) then
            Events.pass()
        end
    end
end)

FredPD.Cad.events = Events
