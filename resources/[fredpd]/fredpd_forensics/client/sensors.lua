--- Generation sensors (spec 8.3.1, 8.2, 12.1).
---
--- A sensor notices a moment in the world and tells the server that it
--- happened. That is the whole job. It does not decide that evidence exists, it
--- does not decide what kind, it never says whose it is, and it places nothing:
--- the owner is the source player's hidden identifier, looked up on the server
--- and never sent in either direction (8.3.4, 8.11). Everything that leaves
--- here goes through `report.observe`, which is the only outbound path in this
--- resource.
---
--- ## The performance shape (12.1: 0.00 ms with the MDT closed)
---
--- Nothing in this file polls. Three of the four sensors are pure event
--- handlers and cost exactly nothing while the moment they watch for is not
--- happening:
---
---   * **Shots** come from `gameEventTriggered`/`CEventGunShot`, which the game
---     raises for the ped that fired.
---   * **Vehicle doors** come from ox_lib's entity cache, which ox_lib already
---     maintains for every resource on the server; `lib.onCache` adds a table
---     entry, not a loop.
---   * **Doors** come from the doorlock bridge, on the event that resource
---     already sends.
---
--- The fourth, reloading, has no event. The game exposes it only as a state to
--- be asked about, so there is a loop -- and it exists only in the seconds
--- after a shot, checks its exit condition before it does anything else, and
--- waits a quarter of a second between checks. A player standing still, a
--- player driving, a player with the MDT open and a player holding a gun they
--- have not fired all run no threads at all.
---
--- ## Damage, and why there is no blood sensor
---
--- 8.3.3 is not a preference: victim blood, and the bullet beside it, are
--- created **only** from the server-side `weaponDamageEvent` pair, never from a
--- client claim. The server already has both ends of that exchange -- the
--- attacker it resolved from the sender and the victim it resolved from a
--- network id -- and it measures the damage against the threshold itself, in
--- `forensics/routes.lua`. A client sensor reporting "I was hurt, bleed for me"
--- would add nothing the server cannot see and would hand every client a way to
--- put anybody's blood anywhere, which is §11.3's first banned pattern wearing
--- a sensor's clothes. So the damage sensor is this comment. The route's table
--- of reportable kinds has no entry a damage claim could use, and it must not
--- grow one.

local report = FredPDForensics.Client.report

-- -----------------------------------------------------------------------------
-- Firing: casings and GSR (8.2)
-- -----------------------------------------------------------------------------

--- When this player last fired, in game time. Read by the reload watcher.
local lastShotAt = 0

--- Whether the reload watcher thread is alive.
local watchingReload = false

--- How long after a shot a reload is still worth watching for, in milliseconds.
---
--- Long enough for the dry-fire, the reach for the magazine and the animation;
--- short enough that a firefight costs a few seconds of quarter-second polling
--- and standing around costs nothing.
local RELOAD_WATCH_MS <const> = 15000

--- How often the watcher looks, while it exists.
---
--- A reload animation is over a second even for a pistol, so this cannot miss
--- one, and 250 ms of a single native for a few seconds is inside the budget in
--- a way that a per-frame check is not.
local RELOAD_POLL_MS <const> = 250

local function watchForReload()
    if watchingReload then return end

    watchingReload = true

    CreateThread(function()
        local wasReloading = false

        while true do
            -- The early-out is the first thing the loop does, on purpose: the
            -- ordinary outcome of this thread is that it stops existing.
            if GetGameTimer() - lastShotAt > RELOAD_WATCH_MS then
                watchingReload = false
                return
            end

            local reloading = IsPedReloading(cache.ped)

            -- The edge, not the state. A reload is one magazine however many
            -- polls the animation spans.
            if reloading and not wasReloading then
                report.observe('reload')
            end

            wasReloading = reloading

            Wait(RELOAD_POLL_MS)
        end
    end)
end

--- A shot fired by this player.
---
--- `CEventGunShot` is raised with the ped the shot belongs to, and it is raised
--- for other people's shots as well -- which is the point of the comparison.
--- The second check is belt and braces on the first: the event is a game event
--- and not a contract, and being armed is the one thing that is true of every
--- shot a player fires and false of most of the ones they merely stand next to.
--- The server holds the last line anyway -- it reads the weapon from its own
--- inventory state and creates nothing for a player who was not carrying one
--- (8.3.2) -- but a sensor that reported an NPC's shooting as its own would be
--- asking the server to refuse it thirty times a minute.
---
--- What is reported is "a shot happened to me" and nothing else: not the
--- weapon, not where, not how many rounds are left. The server samples casings
--- from its own count of them (8.2), and gunshot residue on the shooter is its
--- decision from the same observation.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventGunShot' then return end
    if args[1] ~= cache.ped then return end
    if not IsPedArmed(cache.ped, 6) then return end

    lastShotAt = GetGameTimer()

    watchForReload()
    report.observe('shot')
end)

-- -----------------------------------------------------------------------------
-- Vehicles: prints per door (8.2)
-- -----------------------------------------------------------------------------

--- What was reported on the way in, so the way out can name the same door.
---
--- Held rather than recomputed because by the time the cache says the vehicle
--- is gone, the seat is gone with it -- and a print left climbing out belongs
--- on the door that was opened, not on door zero.
local seated = nil

--- The door for a seat.
---
--- Seats count from the driver at -1; doors count from the driver's at 0. Rear
--- benches past the second row have no door of their own worth recording, so
--- they fold into the nearest one rather than inventing an index the server
--- would have to range-check.
local function doorForSeat(seat)
    if seat == nil or seat < -1 then return 0 end

    local door = seat + 1

    return door > 3 and 3 or door
end

--- Which seat this ped is in, asked of the vehicle rather than of the cache.
---
--- ox_lib updates `cache.vehicle` and `cache.seat` in the same pass, and which
--- of the two handlers runs first is not something to depend on. Eight native
--- calls, once, when a player gets into a car.
local function seatOf(vehicle, ped)
    for seat = -1, 6 do
        if GetPedInVehicleSeat(vehicle, seat) == ped then return seat end
    end

    return nil
end

--- Getting in and getting out, each reported once, with the door.
---
--- The network id is the whole context: the server resolves it to an entity,
--- checks the entity exists and that the player is genuinely within reach of it
--- (8.3.2), and takes the position from the vehicle rather than from anything
--- this client could say. A vehicle that is not networked is not reported at
--- all -- there would be no id to resolve, and a print on a car only this
--- client can see is not evidence.
lib.onCache('vehicle', function(vehicle, previous)
    if vehicle then
        if not NetworkGetEntityIsNetworked(vehicle) then
            seated = nil
            return
        end

        local doorIndex = doorForSeat(seatOf(vehicle, cache.ped))

        seated = { netId = NetworkGetNetworkIdFromEntity(vehicle), doorIndex = doorIndex }

        report.observe('vehicle_door', seated)

        return
    end

    -- Out. `previous` is only used to tell leaving a vehicle apart from never
    -- having been in one; the id and the door come from what was recorded on
    -- the way in, because the entity may already be out of scope.
    if previous and seated then
        report.observe('vehicle_door', seated)
    end

    seated = nil
end)

-- -----------------------------------------------------------------------------
-- Surfaces touched by something other than a sensor in this file
-- -----------------------------------------------------------------------------

--- Reports that this player touched a surface: a door, a register, a safe, an
--- ATM (8.2).
---
--- Exported because the things that are touched are spread across the scripts
--- that own them -- the doorlock bridge beside this file, and the scene and
--- property interactions that come with the rest of M3. They all report the
--- same moment, and they all have to report it the same way, so it is one
--- function rather than four copies of a payload.
---
--- Exporting it widens nothing. The call is the observation every other sensor
--- makes, spends the same budget, and reaches the same route, which checks the
--- player's position, resolves the entity itself and decides -- from glove
--- state it reads server-side -- whether what was left is a fingerprint or a
--- glove mark. A resource that calls this in a loop gets rate-limited, exactly
--- as this one would be.
---
--- @param netId number|nil the networked entity that was touched, if it is one
local function surfaceTouched(netId)
    report.observe('surface', { netId = type(netId) == 'number' and netId or nil })
end

exports('surfaceTouched', surfaceTouched)

-- -----------------------------------------------------------------------------
-- Handled items and tools (8.2)
-- -----------------------------------------------------------------------------

--- Reports that this player consumed or handled something: a bottle, a
--- cigarette, a mask (8.2, "Saliva / touch DNA").
---
--- There is no context at all. The route's `item_use` rule reads nothing from
--- the call but the fact of it: the position is the server's own copy of where
--- the player is standing, the owner is their hidden identifier, and what the
--- item *was* is not sent, because the trace is touch DNA either way and gloves
--- do not help against saliva.
local function itemUsed()
    report.observe('item_use')
end

--- Reports that this player worked a lock or forced a vehicle (8.2, "Tool marks
--- and broken glass").
---
--- The tool itself is not named here and must not be. The route reads the held
--- tool and its serial from ox_inventory's server state, exactly as it reads a
--- weapon, and creates nothing for a player who is not carrying one -- so a
--- client claiming a crowbar it does not have gets a mark with nobody's serial
--- on it, which is to say no mark.
---
--- @param netId number|nil the networked vehicle or entity worked on, if it is
---   one; the server resolves it, range-checks it and takes the position from
---   it, and falls back to the player's own position when there is none.
local function toolUsed(netId)
    report.observe('tool', { netId = type(netId) == 'number' and netId or nil })
end

--- Both of these are exports and nothing else.
---
--- Nothing in `fredpd_forensics` fires them, because neither moment belongs to
--- this resource: using an item is ox_inventory's event and picking a lock is
--- the break-in script's. They are reached the way a door is -- from a bridge
--- file beside `client/bridges/doorlock.lua`, which is the only kind of file in
--- here allowed to name another resource. **No such bridge ships yet**, so on a
--- server that adds none, `dna_touch` and `tool_mark` are never created and the
--- forensic light and the powder's tool-mark entry have nothing to reveal.
exports('itemUsed', itemUsed)
exports('toolUsed', toolUsed)

FredPDForensics.Client.sensors = {
    surfaceTouched = surfaceTouched,
    itemUsed = itemUsed,
    toolUsed = toolUsed,
}
