--- Dispatch, client side: the panic button and the live feed (spec 7.16, 7.17).
---
--- Two jobs, and a third that is deliberately somebody else's.
---
--- ## 1. The panic button (7.16)
---
--- A keybind that works with the MDT shut, because it is the button an officer
--- presses while being shot at. It **sends nothing**: `unit.emergency` declares
--- no fields and the server reads the position off the ped (`routes.lua`, and
--- 0007's header). A client that could send a position could put a fake officer
--- down on the far side of the map and empty a district, so the one thing this
--- file must never grow is an argument.
---
--- ## 2. Getting the server's pushes to the NUI
---
--- The seven `fredpd:cad:*` events are the realtime half of 3.6, and until
--- something forwarded them the console was a screen that only changed when it
--- polled. Every one of them is relayed unchanged, under its own name, so the
--- interface subscribes to `fredpd:cad:call` and not to a name invented here.
---
--- **`FredPD.markArrays` on this hop is load-bearing.** The payload crossed from
--- the server over msgpack, which carries no metatables, so whatever the server
--- marked was lost on the way here (`shared/arrays.lua`). `SendNUIMessage` is
--- the call that writes the JSON the browser parses, which makes this the only
--- place the guess can be corrected -- and it is the *nested* lists that bite: a
--- welfare pass with one unit in it is a list, an AVL delta is a list, and a
--- call's `units` is a list that is usually empty. An empty one arrives as `{}`,
--- `length` is `undefined`, and the `{#each}` over it throws. The forensics
--- client learned this the expensive way.
---
--- ## 3. The console itself is not opened here
---
--- `client/main.lua` already registers every terminal kind, `dispatch_console`
--- among them, against the one action a terminal has: open the MDT and tell it
--- which placement it was opened from (3.10). Registering the kind again here
--- would not add a console -- `Placements.registerAction` keys on the kind, so
--- the later file silently replaces the earlier, and which one that is depends
--- on the order in `fxmanifest.lua`. So this file adds the feed behind that
--- screen and leaves the door where it already is.
---
--- ## What this costs while nothing is happening (12.1: 0.00 ms, MDT closed)
---
--- Nothing, and the reason is structural rather than careful: **there is no
--- thread in this file.** Every line below runs inside an event handler -- a net
--- event the server sent, or a command the player pressed. A player standing
--- still, driving, or with the MDT open and idle runs nothing here at all. The
--- state is a call id, a timestamp and a list that is empty except during the
--- half-second an emergency of this client's own is in flight -- all of it
--- compared when something arrives, never on a timer.

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local core = FredPD.Client.core

local Cad = {}

-- -----------------------------------------------------------------------------
-- The pushes (3.6)
-- -----------------------------------------------------------------------------

--- Every event `server/modules/cad/` sends, and what the payload carries.
---
--- Relayed under the same name, with the payload's own fields spread beside a
--- `type` -- the shape `fredpd:permissions` already uses and the shape the NUI
--- bridge reads (`message.type`, then the fields).
---
---   `fredpd:cad:call`       { call }                  a call was raised or changed
---   `fredpd:cad:log`        { callId, entry }         one narrative line
---   `fredpd:cad:unit`       { unit }                  a unit row changed
---   `fredpd:cad:broadcast`  { broadcast } | { cancelledId }
---   `fredpd:cad:emergency`  { call, callsign }        7.16's tone, handled below
---   `fredpd:cad:avl`        { units }                 a position delta
---   `fredpd:cad:welfare`    { units }                 7.16's welfare prompt
local PUSHES <const> = {
    'fredpd:cad:call',
    'fredpd:cad:log',
    'fredpd:cad:unit',
    'fredpd:cad:broadcast',
    'fredpd:cad:emergency',
    'fredpd:cad:avl',
    'fredpd:cad:welfare',
}

--- Hands one push to the interface.
---
--- A copy rather than the payload itself: the incoming table is the event's, and
--- writing `type` into it would be this file editing the argument it was given.
local function toInterface(event, payload)
    local message = { type = event }

    for key, value in pairs(payload or {}) do
        message[key] = value
    end

    -- See the header. Without this the empty list in the payload reaches the
    -- browser as an object.
    SendNUIMessage(FredPD.markArrays(message))
end

-- -----------------------------------------------------------------------------
-- The panic button (7.16)
-- -----------------------------------------------------------------------------

--- The command behind the keybind. Also typeable, which is what makes the
--- button usable on a client whose player has not bound a key yet.
local COMMAND <const> = 'fredpd_panic'

--- How long after a successful press the button treats itself as already
--- pressed, in milliseconds.
---
--- `unit.emergency` is not idempotent: it raises a P1 every time it is called,
--- so a frightened officer pressing four times would put four P1s on the queue
--- and bury the one a dispatcher is reading. Inside this window the second press
--- says the call is already up instead of raising another one.
---
--- Two minutes, because that is about how long it takes for the first unit to
--- arrive. Past it, a second press raises a second call -- which is right: an
--- officer still pressing the button two minutes later is telling dispatch
--- something new.
local REPRESS_MS <const> = 120000

--- The emergency this officer raised: the call id, and when.
---
--- Cleared when that call is cleared or cancelled, which arrives on
--- `fredpd:cad:call` like any other change -- so an emergency that was dealt
--- with does not leave the button muted for the rest of the window.
local raised = { callId = nil, at = 0 }

--- True while a press is waiting for the server, so a second press during the
--- round trip does not become a second call.
local pressing = false

--- Emergency alerts that arrived while this client's own press was in flight.
---
--- Empty at every other moment. `emergencyAlert` explains what puts anything in
--- here and `release` below is what takes it out again.
local held = {}

--- Draws one emergency alert. Declared here and written with the other pushes
--- below, where it belongs, because `release` is called from `Cad.panic` -- a
--- local is in scope from its declaration and not from its assignment.
local showEmergency

--- Shows every held alert that is not this client's own emergency.
---
--- Called on both ends of the round trip in `Cad.panic`, the refusal path
--- included: an officer going down while a press of ours is in flight must not
--- be swallowed by the server turning that press down.
local function release()
    local queued = held
    held = {}

    for index = 1, #queued do
        local payload = queued[index]

        if not (raised.callId and payload.call.id == raised.callId) then
            showEmergency(payload)
        end
    end
end

--- Shows a route refusal in the words that say what to do about it.
---
--- `Client.showError` renders `error.<code>`, and for this route the code is
--- almost always `conflict` -- which reads "someone else changed this record"
--- at an officer who is being shot at. The field reason underneath it is the
--- useful half, and it is what tells them what to do about it.
---
--- The key is assembled at runtime, which `pnpm i18n:check` cannot see, so the
--- reachable set was read off the route and checked by hand. `unit.emergency`
--- refuses with a field in exactly three places: `ownUnit` answers `no_unit`
--- ("not signed on to a unit") or `off_duty` ("not on duty"), and the route
--- wrapper answers `type` on input that is not a table. All three have a
--- `fieldError.*` key in both locale files and sit in `REASONS` in
--- `web/src/modules/shared/failure.ts`. Everything else this route can return --
--- `context` when the ped has not spawned, `rate_limited`, `internal` -- carries
--- no fields and falls through to the line below.
---
--- One field, because this route never returns two. `FredPD.t` returns the key
--- itself for one that is somehow missing, which is ugly and readable rather
--- than blank.
local function showRefusal(response)
    for _, reason in pairs(response.fields or {}) do
        if type(reason) == 'string' then
            lib.notify({
                title = FredPD.t('cad.emergency.title'),
                description = FredPD.t('fieldError.' .. reason),
                type = 'error',
            })

            return
        end
    end

    core.showError(response)
end

--- Raises an emergency call at this officer's position (7.16).
---
--- What the officer gets: an ox_lib notification, and the banner the NUI draws
--- from the same push every other recipient gets. There is deliberately no tone
--- played from here -- the sound natives are not in this project's luacheck
--- allowlist, and the browser is where the interface's own audio lives -- so the
--- tone 7.16 asks for belongs to the console page reading `fredpd:cad:emergency`
--- below. The milestone report says so rather than leaving it implied.
function Cad.panic()
    if pressing then return end

    if raised.callId and (GetGameTimer() - raised.at) < REPRESS_MS then
        -- Already up. Told again rather than ignored: a button that does
        -- nothing visible is a button the officer presses harder.
        core.notify('cad.emergency.sent')
        return
    end

    pressing = true
    -- No argument, and there is no field to put one in. See the header.
    local response = core.call('unit.emergency')
    pressing = false

    if not response.ok then
        -- The press was refused, so no new call of ours exists. `release` still
        -- compares against `raised`, which either names nothing or names an
        -- earlier emergency of ours that is still ours to leave alone.
        release()
        showRefusal(response)
        return
    end

    raised.callId = response.data and response.data.id or nil
    raised.at = GetGameTimer()

    -- Our own alert reached this client before this call returned (see
    -- `emergencyAlert`), so it is in `held` rather than on screen. Now that the
    -- call id is known, it is the one thing in there that is dropped and
    -- anything else is shown -- a round trip late rather than not at all.
    release()

    core.notify('cad.emergency.sent')
end

RegisterCommand(COMMAND, function()
    Cad.panic()
end, false)

-- No default key, for the reason the forensic kit ships without one: a key
-- FredPD picked is a key some other resource on the server already owns. The
-- officer binds it once under Settings -> Key Bindings -> FiveM, where it
-- appears under the label below.
RegisterKeyMapping(COMMAND, FredPD.t('cad.emergency.button'), 'keyboard', '')

-- -----------------------------------------------------------------------------
-- Hearing somebody else's emergency (7.16)
-- -----------------------------------------------------------------------------

--- How long the alert stays on screen, in milliseconds. Long enough to read a
--- callsign and turn the car around.
local EMERGENCY_NOTIFY_MS <const> = 10000

--- Draws the alert. Assigned to the local declared beside `Cad.panic`.
---
--- The notification is for the officer with the MDT shut, which is most of them.
--- The console draws the same event properly.
function showEmergency(payload)
    local call = payload.call

    -- `fpd_units.callsign` is NOT NULL and the server read it off the row it
    -- put on the call, so this is always a callsign and never a placeholder.
    local callsign = payload.callsign

    lib.notify({
        title = FredPD.t('cad.emergency.title'),
        description = call.locationText
            and FredPD.t('cad.emergency.banner', { callsign = callsign, location = call.locationText })
            or FredPD.t('cad.emergency.bannerNoLocation', { callsign = callsign }),
        type = 'error',
        duration = EMERGENCY_NOTIFY_MS,
    })
end

--- An officer is in distress somewhere this session can hear it.
---
--- Who gets this is decided entirely on the server -- dispatchers and
--- supervisors wherever they are, and everyone else only if their own ped is
--- within range of the position it read (`routes.lua`). Nothing here filters
--- anything: a client deciding whether it is close enough to hear an officer
--- calling for help would be a client deciding whether it hears one.
---
--- ## Telling our own emergency from somebody else's
---
--- The presser is inside their own alert radius, so this arrives back at them
--- too, and `Cad.panic` has already told them. Comparing the call id is the
--- whole test **once the id is known** -- and on the press that raised it, it is
--- not: `unit.emergency` pushes `fredpd:cad:emergency` from inside its handler,
--- before the route answers, so this runs while `core.call` is still parked and
--- `raised.callId` still holds whatever it did before the press. A guard that
--- only compared the id would therefore never fire on the one alert it was
--- written for.
---
--- Held rather than dropped, because the press in flight is not necessarily the
--- emergency that just arrived: a second officer can go down during the round
--- trip and their alert is the one that must not be swallowed. `release` sorts
--- the two out the moment `Cad.panic` knows its own call id, which is a few
--- hundred milliseconds later at worst.
local function emergencyAlert(payload)
    local call = payload and payload.call
    if not call then return end

    if raised.callId and call.id == raised.callId then return end

    if pressing then
        held[#held + 1] = payload
        return
    end

    showEmergency(payload)
end

--- The statuses that end a call (Appendix E). A call in either has left the
--- queue, so an emergency in either is over as far as the button is concerned.
local CLOSED <const> = { cleared = true, cancelled = true }

--- Our own emergency was cleared or cancelled, so the button is armed again.
local function forgetClosedEmergency(payload)
    local call = payload and payload.call
    if not call or call.id ~= raised.callId then return end

    if CLOSED[call.status] then
        raised.callId = nil
        raised.at = 0
    end
end

-- -----------------------------------------------------------------------------
-- World map blips, alongside the NUI's own (7.17)
-- -----------------------------------------------------------------------------

--- A plain, flat dot (invariant 12's own agency-software rule applies to the
--- world map too) in the same blue the NUI already reads as "police unit".
local BLIP_SPRITE <const> = 1
local BLIP_COLOUR <const> = 3

--- officerId -> blip handle, for every unit this client currently has a
--- position for. Only ever populated while the map is open: it is built
--- entirely from `fredpd:cad:avl`, which the server pushes only to a session
--- that has called `map.view` (3.6), so a closed map means no deltas arrive
--- and this stays empty on its own.
local blips = {}

local function upsertBlip(unit)
    local handle = blips[unit.officerId]

    if handle and DoesBlipExist(handle) then
        SetBlipCoords(handle, unit.x, unit.y, unit.z)
        return
    end

    handle = AddBlipForCoord(unit.x, unit.y, unit.z)
    SetBlipSprite(handle, BLIP_SPRITE)
    SetBlipColour(handle, BLIP_COLOUR)
    SetBlipScale(handle, 0.8)
    SetBlipAsShortRange(handle, true)

    blips[unit.officerId] = handle
end

local function removeBlip(officerId)
    local handle = blips[officerId]
    if not handle then return end

    if DoesBlipExist(handle) then RemoveBlip(handle) end
    blips[officerId] = nil
end

--- Applied to the same delta the NUI map draws from, so the two never
--- disagree about where a unit is -- there is only the one feed.
local function syncBlips(payload)
    local units = payload and payload.units
    if not units then return end

    for index = 1, #units do
        local unit = units[index]

        if unit.gone then
            removeBlip(unit.officerId)
        else
            upsertBlip(unit)
        end
    end
end

--- Drops every blip this client is holding. Called alongside the NUI
--- unsubscribe below, for the same reason: a blip nobody asked about any more
--- is a blip that should not still be on the map.
local function clearBlips()
    for officerId in pairs(blips) do
        removeBlip(officerId)
    end
end

--- The pushes that mean something to this file as well as to the interface.
---
--- Everything else is relayed and nothing more: the client renders what the
--- server sent and decides nothing about it (invariant 4).
local WATCHED <const> = {
    ['fredpd:cad:emergency'] = emergencyAlert,
    ['fredpd:cad:call'] = forgetClosedEmergency,
    ['fredpd:cad:avl'] = syncBlips,
}

for _, event in ipairs(PUSHES) do
    RegisterNetEvent(event, function(payload)
        local watcher = WATCHED[event]
        if watcher then watcher(payload) end

        toInterface(event, payload)
    end)
end

--- Drop this session's map subscription.
---
--- Called by `client/main.lua` whenever the MDT closes. The map's own teardown
--- cannot do it: closing the MDT hides the NUI root rather than unmounting the
--- Svelte tree, so no component teardown ever runs, and the subscription
--- outlived every close -- leaving the server sweeping and pushing positions to
--- a player who is looking at the road (12.1).
---
--- Fire and forget. The answer is of no interest, an unsubscribed session
--- unsubscribing again is a no-op on the server, and a close must never wait on
--- a round trip.
function Cad.unsubscribeMap()
    clearBlips()

    CreateThread(function()
        FredPD.Client.core.call('map.view', { subscribe = false })
    end)
end

FredPD.Client.cad = Cad
