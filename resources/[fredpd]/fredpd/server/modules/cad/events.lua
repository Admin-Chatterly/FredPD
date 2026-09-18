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
-- Only the boot sweep still needs this: every other invalidation in this file
-- happens inside `board.unitChanged`, which owns "a unit row changed" and "the
-- cached board is now wrong" as one event.
local avl = FredPD.Cad.avl
local board = FredPD.Cad.board
local sessions = FredPD.Core.session
local perms = FredPD.Core.perms
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

-- There is no push helper in this file any more, and its absence is the fix.
--
-- This file used to carry its own `unitChanged` and `callChanged`, which
-- repeated the two tests `routes.lua` applied -- the page permission and the
-- agency read off the *recipient's* session -- on the argument that the
-- originals were locals in a file that was not ours to change. That argument
-- was answered by `board.lua`, and it had already cost something: the copy of
-- `unitChanged` asserted that "a unit row carries no classification", and a
-- unit row does. `Repo.getUnit` LEFT JOINs `fpd_calls` and aliases five columns
-- off it -- `onCallId`, `onCallLead`, `onCallNumber`, `onCallPriority`,
-- `onCallStatus` -- so pushing the raw row on the page key alone handed every
-- holder of `page.dispatch` the number, the urgency and the stage of a call the
-- queue had correctly refused them (invariants 4 and 5). Worse, because the NUI
-- *replaces* a unit row rather than merging it, sign-on and sign-off healed the
-- hole the access check had just made in a dispatcher's board -- seconds later,
-- on the next duty pass, with nothing on screen to say it had happened.
--
-- So the two calls below are `board.unitChanged` and `board.callChanged`, which
-- are the same functions `routes.lua` and `avl.lua` push through. A fourth
-- sender of a board row starts by reaching past them to `FredPD.Core.push`,
-- which is why this file no longer captures it.

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
---
--- Takes the answer `eligible` already gave rather than the session, because
--- the two halves are asked at different moments: `eligible` is pure and runs
--- while `Events.pass` is walking the session table, and the bridge call runs
--- afterwards, once that walk has finished. See the note on the walk itself.
local function onDuty(src, isEligible)
    if not isEligible then return false end
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

    board.unitChanged(entry.agencyId, repo.getUnit(entry.agencyId, entry.officerId))

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
        board.callChanged(entry.agencyId, repo.getCall(entry.agencyId, assignment.callId))
    end

    repo.setUnitStatus(entry.agencyId, entry.officerId, FredPD.UnitStatus.OFF_DUTY)

    -- The row is kept rather than deleted (0007): it is what an officer comes
    -- back to. `listUnits` leaves `off_duty` off the board without being asked.
    board.unitChanged(entry.agencyId, repo.getUnit(entry.agencyId, entry.officerId))
end

-- -----------------------------------------------------------------------------
-- Re-validating an observation, and starting a grace clock
-- -----------------------------------------------------------------------------

--- Is the officer this observation was taken from still connected on that slot,
--- *right now*?
---
--- The one question a snapshot cannot answer about itself, and the guard every
--- write in `Events.pass` sits behind. It compares the officer id as well as the
--- slot because a server id is reusable: an officer who dropped and whose number
--- was handed to somebody else is not "still connected", and writing this pass's
--- conclusions against the newcomer's session would put one officer's callsign
--- on another officer's row.
local function stillOpen(observation)
    local session = sessions.all()[observation.src]

    return session ~= nil and session.officerId == observation.officerId
end

--- Is any open session this officer's, right now?
---
--- A walk rather than an index, because there is nothing to index off: `bySrc`
--- is this file's memory of the last pass and the drop handler clears it. It is
--- only asked for an expired grace clock -- usually none per pass, occasionally
--- one -- over a table the size of the server's slot count, so the walk costs
--- less than the map that would replace it. Nothing in it suspends, which is the
--- condition that makes walking the live session table legal at all (see
--- `Events.pass`).
local function connected(officerId)
    for _, session in pairs(sessions.all()) do
        if session.officerId == officerId then return true end
    end

    return false
end

--- Starts the grace clock for a unit whose officer has gone away.
---
--- `officerId` is not decoration here: it is the column `signOff` keys its only
--- UPDATE on. Every other entry that reaches `signOff` comes from `known`, which
--- carries it; the entries built here are built by hand, and without it the
--- UPDATE matched zero rows and a dropped officer stayed on the board forever,
--- available, at the position they left at.
---
--- Two callers. `playerDropped` is the obvious one. `Events.pass` is the other,
--- and it exists for one narrow case: an officer who drops *during* their own
--- sign-on. At the moment their drop handler ran, `known` did not yet say they
--- were on duty -- the INSERT this pass was parked on had not come back -- so
--- the handler correctly declined to start a clock for a unit it had no record
--- of, and the pass has to start it once it learns there is now a row.
local function startGrace(officerId, entry)
    dropped[officerId] = {
        officerId = officerId,
        at = os.time(),
        agencyId = entry.agencyId,
        discordId = entry.discordId,
        callsign = entry.callsign,
    }
end

-- -----------------------------------------------------------------------------
-- The duty pass
-- -----------------------------------------------------------------------------

--- One pass over the open sessions and the grace clocks.
---
--- Writes only where something changed. A server where nobody's duty moved
--- costs one bridge call per connected officer and no SQL.
---
--- ## Why this is a snapshot and then two loops, and not one loop
---
--- Not defensiveness. `signOn` and `signOff` both reach the database through
--- the repo, and every `MySQL.*.await` in there **suspends this thread** until
--- the round trip comes back. The two tables being walked are live for exactly
--- that window:
---
---   * `sessions.all()` is `core/session.lua`'s own table. It gains a key when
---     a player's session opens and loses one when they drop, and both happen
---     from other threads while this one is parked on a query.
---   * `dropped` is written by the `playerDropped` handler below, which is a
---     different thread again.
---
--- Lua 5.4 makes no promise about a `pairs` traversal of a table that gains a
--- key while it is running -- the manual's words are "undefined behaviour" --
--- and the usual consequence is not a crash but a key silently skipped or
--- visited twice: an officer who never reaches the board, or one signed off
--- twice. The window is not a few instructions here, it is a database round
--- trip per unit.
---
--- So the walk only reads. It copies out of each session the five fields the
--- writers need and asks the one question that cannot yield -- `eligible` is a
--- pure test over `session.permissions` -- and nothing suspends until the walk
--- has finished. `sessionsByDiscord` and `welfarePass` in `avl.lua` are built
--- the same way, for the same reason.
---
--- What the snapshot costs is that the pass acts on who was connected a moment
--- ago: an officer who drops mid-pass may still be signed on, and the next pass
--- and the drop handler put that right. That is the right direction to be wrong
--- in, and it is the only one of the three orderings that is defined at all.
---
--- ## A snapshot is a safe READ order. It is not a safe WRITE order.
---
--- Read the paragraph above and then read this one, because the snapshot closed
--- the traversal bug and, in the same edit, silently opened a second bug at the
--- other end of the same loop. The shape recurs and the symptom is a long way
--- from the cause, so it is worth setting out exactly.
---
--- `dropped[officerId] = nil` means "this officer is back inside their grace
--- period, so as far as the board is concerned the drop never happened". It used
--- to sit in the same iteration as the read of `sessions.all()` that justified
--- it, with nothing suspended in between, so it could only ever run on an
--- officer who was connected at that instant. Moved into the second loop it runs
--- on an observation that is by then up to one database round trip *per unit*
--- old -- and the officers whose `playerDropped` fires inside that window are
--- precisely the ones the grace clock exists for. Their clock was erased by an
--- observation saying they had been connected a moment ago, `known[officerId]`
--- had already been cleared by the drop handler, and no later pass had any
--- record of them: no session to observe, no memory to compare against, no clock
--- to expire. The unit stayed on the board -- available, holding its call slot,
--- at the position it left at -- until the server was restarted. That is the
--- ghost the drop handler was written to prevent, reintroduced deterministically
--- by the fix for an unrelated bug.
---
--- So the snapshot decides the ORDER of the work and nothing else. Every write
--- below is re-validated against the live tables at the moment it is made:
--- `stillOpen` re-reads `sessions.all()` after the bridge call and again after
--- the repo round trips, and `known` is read *after* the bridge call rather than
--- before it, because the drop handler clears it and a stale `before` would sign
--- a crashed officer off instantly instead of giving them their grace period.
--- An observation whose session has since gone is not acted on at all: the drop
--- handler has already recorded it correctly and undoing that is the whole bug.
--- The two exceptions are the officer who drops during their own sign-on, whose
--- clock nobody else could have started (`startGrace`), and the one who drops
--- during their own sign-off, whose clock has just been made pointless by the
--- sign-off that already happened.
function Events.pass()
    if not booted then return end

    local now = os.time()

    local observed, seen = {}, 0

    for src, session in pairs(sessions.all()) do
        if session.officerId then
            seen = seen + 1
            observed[seen] = {
                src = src,
                officerId = session.officerId,
                agencyId = session.agencyId,
                discordId = session.discordId,
                callsign = session.callsign,
                eligible = eligible(session),
            }
        end
    end

    for index = 1, seen do
        local observation = observed[index]
        local officerId = observation.officerId

        -- The first of the two re-validations. Cheap, and it skips the bridge
        -- call and the whole body for an officer who has already gone -- which
        -- on a server with `dutyRequired = false` would otherwise sign a
        -- disconnected player on, since `eligible` was true when it was asked
        -- and nothing else would contradict it.
        if stillOpen(observation) then
            -- The bridge call goes first because it can suspend, and `known` is
            -- read after it for that reason: the drop handler clears `known`,
            -- and a `before` read before the suspension would still say "on
            -- duty" for an officer whose grace clock had already started.
            local working = onDuty(observation.src, observation.eligible)
            local before = known[officerId]

            local entry = before or {}
            entry.officerId = officerId
            entry.src = observation.src
            entry.agencyId = observation.agencyId
            entry.discordId = observation.discordId
            entry.callsign = observation.callsign

            -- What this iteration actually did, because after the round trips
            -- below the only honest way to decide what to write is to know what
            -- has already been written to the database.
            local signedOn, signedOff = false, false

            if working and not (before and before.onDuty) then
                -- A transition, and an officer we have never seen is one too:
                -- that is the reconnect case, and it is why this compares
                -- against memory rather than watching for an edge.
                entry.onDuty = signOn(entry)
                signedOn = entry.onDuty
            elseif not working and before and before.onDuty then
                signOff(before)
                signedOff = true
                entry.onDuty = false
            elseif before == nil then
                entry.onDuty = false
            end

            -- The second re-validation, and the one the ghost came through.
            -- Everything under here is a write whose justification is "this
            -- officer is connected", so it is asked again here rather than
            -- trusted from the snapshot.
            if stillOpen(observation) then
                -- Back inside the grace period: the drop never happened as far
                -- as the board is concerned, and the row still carries their
                -- status, their time in status and their call.
                dropped[officerId] = nil

                -- A unit a supervisor signed off with `unit.manage` while its
                -- officer is still on duty in the job stays off: this pass sees
                -- no transition, so it writes nothing. Re-signing them on would
                -- undo a supervisory decision every fifteen seconds.
                known[officerId] = entry
                bySrc[observation.src] = officerId
            elseif signedOn then
                -- They dropped while this thread was parked on their own
                -- sign-on. Their drop handler found no on-duty entry and started
                -- no clock, so there is a row on the board that only this
                -- iteration knows about. Start it here or it is a ghost.
                startGrace(officerId, entry)
            elseif signedOff then
                -- The mirror image: they dropped while this thread was parked
                -- on their own sign-off, so their drop handler started a clock
                -- for a unit that is already off the board. Letting it expire
                -- would sign them off a second time and push the board again
                -- for nothing.
                dropped[officerId] = nil
            end
        end
    end

    -- The grace clocks, snapshotted for the same reason: `signOff` yields, and
    -- a player dropping during that query writes a new key into `dropped` --
    -- which is the table this would otherwise still be walking.
    local expired, count = {}, 0

    for _, entry in pairs(dropped) do
        if (now - entry.at) >= config.signOffGraceSeconds then
            count = count + 1
            expired[count] = entry
        end
    end

    for index = 1, count do
        local entry = expired[index]
        local officerId = entry.officerId

        -- The same re-validation as the loop above, against the table this
        -- snapshot was taken from. `signOff` suspends, so by the time this
        -- iteration runs the clock it meant to act on may be gone, or may have
        -- been replaced by a newer one -- a second drop writes a fresh table
        -- with a fresh `at` under the same key. The identity test is what tells
        -- "the clock I measured" apart from "a clock", and without it an officer
        -- whose grace period had just restarted would be signed off on the
        -- strength of the one before it.
        if dropped[officerId] == entry then
            dropped[officerId] = nil

            -- And the clock expiring is not the same fact as the officer being
            -- gone. They can have reconnected after the snapshot was taken and
            -- after the loop above had already walked past their slot, in which
            -- case nothing in this pass has cleared their clock and nothing
            -- will. Clearing it and leaving them alone puts them back where
            -- 0007 wants them: the next pass finds an officer on duty with no
            -- memory behind them and signs them back on, still on their call,
            -- rather than this one pulling a unit off a scene they are standing
            -- on.
            if not connected(officerId) then signOff(entry) end
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

    -- An officer this file has no on-duty record of has no row on the board to
    -- take off it, so there is nothing to time. `Events.pass` covers the one
    -- case where that reasoning is wrong -- a drop landing inside a sign-on
    -- this handler could not see -- and it covers it from the other side,
    -- because only that iteration knows the INSERT went through.
    if not entry or not entry.onDuty then return end

    startGrace(officerId, entry)
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
