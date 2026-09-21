--- Destroying evidence (spec 8.10, 8.1.5, 8.2, 12.1).
---
--- Four mechanics, one shape: a timed action in the world, and then a single
--- question for the server. The wiping kit for surfaces and weapons, cleaning
--- chemicals for blood, water at a sink or a shower for gunshot residue, and
--- hands for the casings and magazines on the ground.
---
--- ## This is not a police feature
---
--- 8.10 is explicit, and it names the reference script's bug by name:
--- destruction is "available to every player through ox_target, subject only to
--- item and context rules. Police-only restrictions must never block criminal
--- gameplay." A criminal walking back to pick up their own casings, wiping down
--- the car they stole and washing the residue off their hands before they are
--- stopped *is the feature*. So there is no permission in this file, no duty
--- check, no session, and nothing here asks whether the player is an officer.
--- The route behind it must not either -- see the note above `call`.
---
--- ## Cleaning is not erasing (8.10, 8.1.5)
---
--- Blood that has been cleaned is still blood. The server does not delete the
--- row: it marks the trace cleaned, which makes it invisible to the eye and
--- findable again with luminol, and `FredPD.Modules.evidence.qualityAfter`
--- takes the yield down to a quarter of what it was when somebody finally swabs
--- it. "Nothing is perfectly clean" (8.1.5) is a rule about the model, and the
--- client is not where it is enforced -- it is enforced by the client having no
--- way to ask for a deletion. There is one action here, `clean`, and what it
--- means is the server's to decide.
---
--- ## What comes back is nothing (8.11)
---
--- The route answers an empty table whether it destroyed six traces, one or
--- none. That is deliberate and it is the reason this file shows the same
--- message every time: a count would be an oracle. A player could wipe a door
--- handle they never touched and be told how many people had, or scrub a
--- pavement to find out whether anybody bled on it -- learning, from an action
--- anyone may take, about evidence they were never streamed. So nothing is
--- reported back but a refusal, and a refusal only ever concerns the player's
--- own inventory.
---
--- ## Cost (12.1: 0.00 ms while the MDT is closed)
---
--- No loop, no thread, no tick. Everything below is an ox_target option
--- registered once at load -- on vehicles, on objects, on the sink and shower
--- models, and on the traces `render.lua` already streams -- plus the progress
--- bar that exists only while somebody is scrubbing something.

FredPDForensics = FredPDForensics or {}
FredPDForensics.Client = FredPDForensics.Client or {}

local Destroy = {}

--- `client/render.lua` loads before this file (see `fxmanifest.lua`). It owns
--- the streamed traces and the target zones hanging off them; picking a casing
--- up and cleaning a pool of blood are prompts on those zones.
local render = FredPDForensics.Client.render

if not render then
    error('[fredpd_forensics] client/render.lua must load before client/destroy.lua')
end

--- `client/collect.lua` loads before this file too (see `fxmanifest.lua`). It
--- owns the resource's one "a timed action is running" flag, and this file
--- takes that same flag rather than keeping one of its own -- see `perform`.
local collect = FredPDForensics.Client.collect

if not collect then
    error('[fredpd_forensics] client/collect.lua must load before client/destroy.lua')
end

-- -----------------------------------------------------------------------------
-- Settings
-- -----------------------------------------------------------------------------

--- How far a destruction prompt may be used from, in metres.
---
--- Inside every range the server re-measures against its own copy of where the
--- player is standing (8.3.2), so reaching a prompt means being in reach. A
--- prompt that reached further would only produce refusals.
local DISTANCE <const> = 2.0

--- How long each action takes, in milliseconds.
---
--- Destroying evidence "costs time and items" (8.10, 8.1.5), and the time is
--- the half that matters in a chase: wiping a car down properly is long enough
--- that doing it with a unit two streets away is a bad idea. Picking a casing
--- off the pavement is quick, because bending down is all it is.
local DURATION <const> = {
    wipe = 12000,
    weapon = 8000,
    clean = 15000,
    wash = 9000,
    pickup = 3000,
}

--- Working with both hands in front of you, and kneeling over something.
---
--- Two dictionaries rather than five: the animation is scenery, and a wrong
--- guess at a dictionary that is not in the base game is a silent failure on
--- every client. These two are the ones `collect.lua` already uses.
local ANIM_STANDING <const> = {
    dict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
    clip = 'machinic_loop_mechandplayer',
}

local ANIM_KNEELING <const> = { dict = 'amb@medic@standing@kneel@base', clip = 'base' }

--- Which animation each action plays.
local ANIM <const> = {
    wipe = ANIM_STANDING,
    weapon = ANIM_STANDING,
    clean = ANIM_KNEELING,
    wash = ANIM_STANDING,
    pickup = ANIM_KNEELING,
}

--- The trace types each trace-anchored action applies to.
---
--- Only ever consulted against render data, which carries a type and nothing
--- else (8.1.6). A latent trace -- a print, a glove mark, a pool of blood
--- somebody has already cleaned -- is not streamed to a player without forensic
--- tools at all, so it never reaches these tables and cannot be picked up off a
--- prompt that was never drawn. Wiping is deliberately not in here for that
--- reason: prints are invisible, so wiping is an act on a *surface*, blind, and
--- hangs off the vehicle and object targets below.
---
--- `bullet` is deliberately absent from `PICKABLE`. 8.10 names casings and
--- magazines, and 8.2 says a bullet is *dug out*, which is a recovery action
--- with a tool and not something a hand does on the way past. Adding it here
--- would be widening the spec by one table entry; if a server wants it, the
--- server route is where that decision belongs.
local PICKABLE <const> = { casing = true, magazine = true }
local CLEANABLE <const> = { blood = true }

--- The sink and shower models washing is offered at (8.2: "Washing at sinks and
--- showers").
---
--- A replicated convar, comma-separated, because which props a server's map has
--- is a property of that server's map. A model name is not a world position, so
--- this is not a placement (spec 3.10): the same sink model is a sink wherever
--- it stands, and a server that adds a bathroom does not have to configure it.
--- Unknown names are harmless -- ox_target simply never matches them.
local WASH_MODELS <const> = (function()
    local configured = GetConvar('fredpd:forensics:washModels', '')
    local models = {}

    if configured ~= '' then
        for name in configured:gmatch('[^,%s]+') do models[#models + 1] = name end

        if #models > 0 then return models end
    end

    return {
        'prop_sink_01', 'prop_sink_02', 'prop_sink_03',
        'prop_sink_04', 'prop_sink_05', 'prop_sink_06',
        'v_res_mbsink', 'v_res_fa_sink1', 'v_ilev_bs_sink',
        'prop_shower_rail', 'prop_shower_glass01', 'v_ilev_shwr2',
    }
end)()

--- How long a refused action's prompt stays hidden, in milliseconds.
---
--- Tidiness and not a control (invariant 4): a player with no wiping kit is
--- refused by the server whether or not the option is drawn, and the option
--- comes back by itself. It exists so that somebody who has run out of cleaning
--- chemicals is not offered the same refusal at every pool of blood they walk
--- past.
local SUPPRESS_MS <const> = 30000

-- -----------------------------------------------------------------------------
-- Talking to the core (ADR-011, invariant 3)
-- -----------------------------------------------------------------------------

--- Calls the core's destruction route.
---
--- `lib.callback` names its callbacks with global event names, so the route
--- `fredpd` registered answers a call made from here. This resource registers
--- nothing of its own: there is one gateway, and it is `route()` in the core.
---
--- **The route this reaches carries no permission and needs no session.** Every
--- other route in FredPD does, because every other route is an officer acting
--- on a record; this one is a player cleaning up after themselves, and 8.10
--- forbids gating it. If this file ever starts receiving `forbidden` or
--- `no_session`, the route has been given a permission it must not have and the
--- reference script's bug has been reproduced.
---
--- @return table { ok = boolean, data = any, err = string|nil }
local function call(payload)
    local response = lib.callback.await('fredpd:forensics.destroy', false, payload)

    if type(response) ~= 'table' then return { ok = false, err = 'internal' } end

    return response
end

local function notify(message, kind)
    lib.notify({
        title = FredPD.t('app.name'),
        description = message,
        type = kind or 'inform',
    })
end

-- -----------------------------------------------------------------------------
-- Prompt tidiness (not a control)
-- -----------------------------------------------------------------------------

--- action -> the game time its prompt comes back at.
local hiddenUntil = {}

local function suppressed(action)
    return GetGameTimer() < (hiddenUntil[action] or 0)
end

--- Hides one action's prompt for a while after a refusal.
---
--- Only the refusals that will still be refusals in a second: a missing item, a
--- spent rate limit. `not_found` is not one of them -- it is the ordinary answer
--- when somebody else got to the casing first, and the next casing is a
--- different question.
local function noteRefusal(action, response)
    local err = response.err

    if err == 'conflict' or err == 'rate_limited' or err == 'forbidden' or err == 'no_session' then
        hiddenUntil[action] = GetGameTimer() + SUPPRESS_MS
    end
end

-- -----------------------------------------------------------------------------
-- The timed action
-- -----------------------------------------------------------------------------

--- Runs the progress action and then asks the server.
---
--- The order is the one 11.3 asks for from the other end: nothing about the
--- world changes here, so there is no effect to undo when the server refuses
--- for want of an item. The server checks the item, removes it and *then*
--- destroys anything -- this file only spends the player's time.
---
--- Both halves run inside `collect.runExclusive`, which is this resource's one
--- timed-action flag and not a second copy of it. `lib.progressActive()` alone
--- used to stand here, and it was open during precisely the half that matters:
--- `collect.lua` holds its flag across the server round trip that follows its
--- progress circle, and during that round trip no circle is drawn, so a wipe
--- could be started on top of a collection that was still in flight. The flag
--- covers the call as well as the circle, in both files, in both directions.
--- `runExclusive` still consults `lib.progressActive()` as well, because that
--- is the only half that sees the other resources on the server -- eating
--- through ox_inventory still blocks a wipe, exactly as it did before.
---
--- The hold is bounded (`BUSY_MAX_MS` in `collect.lua`). A collection whose
--- callback never comes back would otherwise leave the flag set for the life of
--- the Lua state, and destruction -- the one thing 8.10 says must never be
--- blocked -- would be the thing it blocked.
---
--- What the flag is not is a permission. Destruction is open to every player
--- (8.10) and nothing here asks who anybody is; one action at a time is the
--- same rule an officer collecting gets, for the same reason.
---
--- @param action string a key of `DURATION`
--- @param label string already translated
--- @param payload table the route call: { action, traceKey?, netId? }
--- @return boolean whether the server accepted it
local function perform(action, label, payload)
    local accepted = false

    local started = collect.runExclusive(function()
        local completed = lib.progressCircle({
            duration = DURATION[action],
            label = label,
            position = 'bottom',
            useWhileDead = false,
            canCancel = true,
            disable = { move = true, car = true, combat = true },
            anim = ANIM[action],
        })

        if completed ~= true then
            notify(FredPD.t('forensics.destroy.cancelled'))
            return
        end

        local response = call(payload)

        if not response.ok then
            noteRefusal(action, response)
            notify(
                FredPD.t(response.err == 'conflict'
                    and 'forensics.destroy.noItem'
                    or 'forensics.destroy.failed'),
                'error'
            )
            return
        end

        -- The same message whatever happened, because the answer carries
        -- nothing (8.11). A player who wipes a door nobody touched is told
        -- exactly what a player who wiped away a murderer's prints is told.
        notify(FredPD.t('forensics.destroy.done'), 'success')

        accepted = true
    end)

    -- `runExclusive` has already said `forensics.busy` for us when it refused,
    -- so there is nothing to add here.
    if not started then return false end

    return accepted
end

-- -----------------------------------------------------------------------------
-- The wiping kit: surfaces (8.2, 8.10)
-- -----------------------------------------------------------------------------

--- The network id of an entity, when it has one.
---
--- Sent so the server can resolve the entity itself, check it exists and check
--- the player is genuinely within reach of it (8.3.2) -- and take the position
--- from the entity rather than from anything this client could say. A prop that
--- is part of the map is not networked and has no id; the server falls back to
--- the server-side position of the player, which is where the cloth was.
local function netIdOf(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    if not NetworkGetEntityIsNetworked(entity) then return nil end

    return NetworkGetNetworkIdFromEntity(entity)
end

local function wipeSurface(entity)
    perform('wipe', FredPD.t('forensics.destroy.wipe.progress'), {
        action = 'wipe',
        netId = netIdOf(entity),
    })
end

-- -----------------------------------------------------------------------------
-- The wiping kit: weapons (8.2, 8.10)
-- -----------------------------------------------------------------------------

--- Wipes down whatever the player is holding.
---
--- Which weapon that is, and what was on it, is read from server-side inventory
--- state exactly as the generation pipeline reads it (8.3.2). Nothing about the
--- weapon is sent from here -- not its name, not its serial, not whether it has
--- been fired. `IsPedArmed` only decides whether the prompt is worth drawing.
local function wipeWeapon()
    perform('weapon', FredPD.t('forensics.destroy.weapon.progress'), { action = 'weapon' })
end

local function armed()
    return IsPedArmed(cache.ped, 6)
end

-- -----------------------------------------------------------------------------
-- Cleaning chemicals: blood (8.10 -- and it leaves a trace)
-- -----------------------------------------------------------------------------

--- Cleans a pool of blood.
---
--- The trace does not go away. The server marks it cleaned, which takes it out
--- of sight and leaves it where it was: luminol finds it again, and the DNA
--- yield the lab gets out of it is a quarter of what it would have been
--- (`evidence.qualityAfter`, 8.10). What this client observes is that the blood
--- is no longer streamed to it -- the same thing it would observe if the pool
--- had been collected, or had decayed, or if the player had simply walked away.
--- Which of those happened is not something it is told (8.11).
local function cleanBlood(trace)
    if perform('clean', FredPD.t('forensics.destroy.clean.progress'), {
        action = 'clean',
        traceKey = trace.key,
    }) then
        -- The server has already marked it, so the next stream tick would drop
        -- it within the second. Dropping it now only makes the pavement agree
        -- with the bucket immediately.
        render.forget(trace.key)
    end
end

-- -----------------------------------------------------------------------------
-- Washing: gunshot residue (8.2, 8.10)
-- -----------------------------------------------------------------------------

--- Washes at a sink or a shower.
---
--- Residue lives on the player, not in the world, so there is no trace key to
--- send: the server knows whose hands these are from the source of the call and
--- from nothing else. The sink is named only as the entity the player is
--- standing at, so the server can check they are actually standing at one
--- (8.3.2) rather than washing in the middle of a field.
local function wash(entity)
    perform('wash', FredPD.t('forensics.destroy.wash.progress'), {
        action = 'wash',
        netId = netIdOf(entity),
    })
end

-- -----------------------------------------------------------------------------
-- Picking things up: casings and magazines (8.2, 8.10)
-- -----------------------------------------------------------------------------

--- Picks a casing, a magazine or a bullet up off the ground.
---
--- The key is the only thing about the trace that is sent, and it is the opaque
--- one it was streamed with. Whether it still names anything -- whether an
--- officer bagged it a second ago -- is the grid's answer and not this client's
--- claim.
---
--- Nothing is minted into an inventory here. A flow that handed out an item for
--- every casing picked up would be the duplication path 11.3 warns about, and
--- the mechanic 8.10 describes is making the evidence stop existing, not
--- acquiring it.
local function pickUp(trace)
    if perform('pickup', FredPD.t('forensics.destroy.pickup.progress'), {
        action = 'pickup',
        traceKey = trace.key,
    }) then
        render.forget(trace.key)
    end
end

-- -----------------------------------------------------------------------------
-- The prompts on a trace (8.10: through ox_target)
-- -----------------------------------------------------------------------------

render.registerInteraction(function(trace)
    if not PICKABLE[trace.type] then return nil end

    return {
        name = 'fredpd_destroy_pickup_' .. trace.key,
        icon = 'fa-solid fa-hand',
        label = FredPD.t('forensics.destroy.pickup.option', {
            -- The type is render data: what the thing is, never whose it is.
            type = FredPD.t('evidence.type.' .. trace.type),
        }),
        distance = DISTANCE,
        canInteract = function() return not suppressed('pickup') end,
        onSelect = function() pickUp(trace) end,
    }
end)

render.registerInteraction(function(trace)
    if not CLEANABLE[trace.type] then return nil end

    return {
        name = 'fredpd_destroy_clean_' .. trace.key,
        icon = 'fa-solid fa-bucket',
        label = FredPD.t('forensics.destroy.clean.option'),
        distance = DISTANCE,
        canInteract = function() return not suppressed('clean') end,
        onSelect = function() cleanBlood(trace) end,
    }
end)

-- -----------------------------------------------------------------------------
-- The prompts on the world
-- -----------------------------------------------------------------------------

--- Wiping down a surface and wiping down a weapon, offered on anything with a
--- surface: every vehicle and every object.
---
--- Registered globally rather than per model because prints are left on
--- "vehicle doors, vehicles, weapons, doors, props" (8.2) and a list of which
--- props count would be a list that is always missing one. The cost is an
--- ox_target option, which is evaluated when a player looks at something and
--- never otherwise.
--- Built fresh for each registry rather than shared between them: ox_target
--- takes ownership of an option table and writes its own bookkeeping into it,
--- so handing the same tables to the vehicle and the object registry would have
--- them fight over one set.
local function surfaceOptions()
    return {
        {
            name = 'fredpd_destroy_wipe',
            icon = 'fa-solid fa-hand-sparkles',
            label = FredPD.t('forensics.destroy.wipe.option'),
            distance = DISTANCE,
            canInteract = function() return not suppressed('wipe') end,
            onSelect = function(data) wipeSurface(data and data.entity) end,
        },
        {
            name = 'fredpd_destroy_weapon',
            icon = 'fa-solid fa-gun',
            label = FredPD.t('forensics.destroy.weapon.option'),
            distance = DISTANCE,
            -- Somewhere to lean, and something in your hands. The server
            -- decides what is actually in them.
            canInteract = function() return armed() and not suppressed('weapon') end,
            onSelect = function() wipeWeapon() end,
        },
    }
end

local SURFACE_NAMES <const> = { 'fredpd_destroy_wipe', 'fredpd_destroy_weapon' }
local WASH_NAME <const> = 'fredpd_destroy_wash'

exports.ox_target:addGlobalVehicle(surfaceOptions())
exports.ox_target:addGlobalObject(surfaceOptions())

exports.ox_target:addModel(WASH_MODELS, {
    {
        name = WASH_NAME,
        icon = 'fa-solid fa-droplet',
        label = FredPD.t('forensics.destroy.wash.option'),
        distance = DISTANCE,
        canInteract = function() return not suppressed('wash') end,
        onSelect = function(data) wash(data and data.entity) end,
    },
})

-- -----------------------------------------------------------------------------
-- Teardown
-- -----------------------------------------------------------------------------

--- Never leave options behind on a restart. ox_target keeps them keyed by name,
--- and a reload would otherwise leave a prompt that calls into a Lua state that
--- no longer exists.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    exports.ox_target:removeGlobalVehicle(SURFACE_NAMES)
    exports.ox_target:removeGlobalObject(SURFACE_NAMES)
    exports.ox_target:removeModel(WASH_MODELS, { WASH_NAME })
end)

-- -----------------------------------------------------------------------------
-- For an item to hang off
-- -----------------------------------------------------------------------------

--- Runs one destruction action, for an inventory item handler to call.
---
--- Exposed so that "use the wiping kit in your inventory" runs the same timed
--- action the ox_target prompt does, and ends in the same route -- which is
--- still the only thing that decides whether the item was there, whether
--- anything was in reach and what happens to it.
---
--- @param action string 'wipe', 'weapon' or 'wash'
function Destroy.use(action)
    if action == 'wipe' then
        wipeSurface(nil)
    elseif action == 'weapon' then
        wipeWeapon()
    elseif action == 'wash' then
        wash(nil)
    end
end

FredPDForensics.Client.destroy = Destroy
