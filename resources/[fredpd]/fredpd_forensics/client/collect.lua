--- Collection and the forensic tools (spec 8.4, 8.10, 12.1).
---
--- Every action in this file is the same shape: a timed action in the world,
--- and then a question for the server. The answer is the server's alone --
--- which is the point of the shape:
---
---   * **Collection.** The officer chooses packaging and a marker number, kneels
---     for a few seconds, and `evidence.collect` in the core decides the rest.
---     The trace's type, its quality, its age and who left it are read from the
---     grid there and never travel in either direction (8.1, 8.11); the only
---     thing this file sends about the trace is the opaque key it was streamed.
---   * **The swab.** Gunshot residue is the one row of 8.2 with no position, so
---     it is not in the grid and has no trace key: it is a state on a person.
---     The prompt therefore hangs off a *player* rather than off a trace zone,
---     and names them to the server by their server id alone. Whether they have
---     any residue, how much, and how long ago they fired are read from the
---     residue table on the server and are never asked for or answered here --
---     a swab that reported why it found nothing would be a residue detector an
---     officer could walk around pointing at people (8.11).
---   * **The tools.** Powder, luminol and the forensic light ask
---     `forensics.process` to reveal what is within the server's radius of where
---     the server says the officer is standing. The client does not know what is
---     there, does not know what was found until the count comes back, and never
---     learns whose it is. What the tool revealed reaches this machine the same
---     way everything else does: as render data on the next streaming tick.
---
--- The permission is checked on the server, on every call, by the route wrapper
--- (invariant 4). The one client-side thing here that looks like a check --
--- `suppressed()` -- is tidiness and is documented as such: it stops a prompt
--- that has just been refused from following an officer around a scene, or down
--- a street full of people. Removing it would change nothing about what anybody
--- can do.

FredPDForensics = FredPDForensics or {}
FredPDForensics.Client = FredPDForensics.Client or {}

local Collect = {}

--- `client/render.lua` loads before this file (see `fxmanifest.lua`): it owns
--- the props and the target zones these prompts hang off, and the trace table
--- they are built from. Failing here is better than a resource that starts and
--- then silently offers nothing at a scene.
local render = FredPDForensics.Client.render

if not render then
    error('[fredpd_forensics] client/render.lua must load before client/collect.lua')
end

-- -----------------------------------------------------------------------------
-- Settings
-- -----------------------------------------------------------------------------

--- How far the target prompt may be used from. Inside the server's collection
--- range, which is re-measured against its own copy of the officer's position.
local ZONE_DISTANCE <const> = 2.0

--- How long collecting takes, in milliseconds, by evidence type (8.4: "a
--- progress action"). Lifting ridge detail from a surface is slower than
--- bagging a casing off the pavement.
local COLLECT_MS <const> = {
    print = 9000,
    glove_mark = 9000,
    tool_mark = 8000,
    blood = 8000,
    dna_touch = 7000,
    drug_residue = 7000,
    footwear = 8000,
    casing = 5000,
    bullet = 5000,
    magazine = 5000,
    default = 6000,
}

--- The packaging an officer usually reaches for, per type. A default in a
--- dialog: the officer picks, and the server validates the choice against the
--- item list in 8.5 -- the wrong container is a mistake an officer is allowed to
--- make, and one the lab will see in the quality.
---
--- `gsr` is the one entry no dialog ever shows, because residue is not in the
--- grid and the swab below has nothing to ask about: the swab sends it as the
--- value rather than as a suggestion. It stays in this table rather than
--- standing alone so that a server changing what a swab goes into changes it in
--- one place.
local SUGGESTED_PACKAGING <const> = {
    print = 'lift_card',
    glove_mark = 'lift_card',
    tool_mark = 'lift_card',
    blood = 'swab_box',
    dna_touch = 'swab_box',
    drug_residue = 'drug_bag',
    casing = 'envelope',
    bullet = 'envelope',
    magazine = 'evidence_bag',
    footwear = 'item_tag',
    digital = 'phone_bag',
    gsr = 'swab_box',
    default = 'evidence_bag',
}

--- The packaging list from spec 8.5. A copy of the enum the schema validates
--- against, because this resource has no access to the core's generated schema
--- -- and a copy that drifts costs an officer one refused dialog, not a hole:
--- the server is what decides whether a value is allowed.
local PACKAGING <const> = {
    'evidence_bag', 'envelope', 'swab_box', 'lift_card',
    'firearm_box', 'drug_bag', 'phone_bag', 'item_tag',
}

--- How long a gunshot residue swab takes, in milliseconds (8.2's "GSR kit").
---
--- Between bagging a casing and lifting a print: taking a sample off somebody
--- else's hands and cuffs is more than bending down and less than working a
--- surface, and it is long enough that doing it to a suspect nobody is holding
--- is a bad idea.
local SWAB_MS <const> = 6000

--- How long the tools take (8.4).
local TOOL_MS <const> = { powder = 7000, luminol = 9000, forensic_light = 7000 }

--- How long a refused prompt stays hidden, in milliseconds. See `suppressed()`.
local SUPPRESS_MS <const> = 30000

local COMMAND <const> = 'forensics'
local TOOL_MENU <const> = 'fredpd_forensic_tools'

--- Kneeling over something on the ground, and standing over a surface.
local COLLECT_ANIM <const> = { dict = 'amb@medic@standing@kneel@base', clip = 'base' }
local TOOL_ANIM <const> = {
    dict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
    clip = 'machinic_loop_mechandplayer',
}

-- -----------------------------------------------------------------------------
-- Talking to the core (ADR-011)
-- -----------------------------------------------------------------------------

--- Calls a core route.
---
--- `lib.callback` names its callbacks with global event names, so a route
--- registered by `fredpd` is reachable from here without this resource
--- registering anything of its own. That is the whole interface: there is no
--- second gateway, and nothing in this resource handles a client call
--- (invariant 3).
---
--- @return table { ok = boolean, data = any, err = string|nil }
local function call(name, data)
    local response = lib.callback.await('fredpd:' .. name, false, data or {})

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

local function showError(response)
    notify(FredPD.t('error.' .. (response.err or 'internal')), 'error')
end

-- -----------------------------------------------------------------------------
-- Prompt tidiness (not a control)
-- -----------------------------------------------------------------------------

--- prompt -> the game time its option comes back at.
---
--- Set when the server refuses for want of a permission or a session. Invariant
--- 4 is explicit that hiding something in the interface is never the control,
--- and this does not pretend to be one: the option comes back by itself,
--- anybody who calls the route anyway is refused by the route, and a player who
--- never sees the prompt is refused the same way. It exists so that a civilian
--- standing over a casing is not offered a police action every time they walk
--- past it, and is not offered to swab every passer-by.
---
--- Keyed by prompt, as `client/destroy.lua` keys its own, because the two
--- prompts are drawn on different things: a refused swab must not take the
--- collection option off the casings at a scene, and a refusal at a scene must
--- not follow the officer onto the next person they stand next to. The trace
--- prompts share the one `collect` key deliberately -- the marker is placed for
--- the collection that follows it, and there is no sense in offering to number
--- something this officer has just been refused permission to bag.
local hiddenUntil = {}

local function suppressed(prompt)
    return GetGameTimer() < (hiddenUntil[prompt] or 0)
end

--- Hides one prompt for a while after a refusal.
---
--- Only the refusals that will still be refusals in a second. `not_found` is
--- deliberately not one of them: at a scene it is the ordinary answer when
--- somebody else got to the casing first, and on a swab it is every way a swab
--- can come to nothing -- out of reach, nothing on their hands, residue already
--- decayed -- each of which the next person is a fresh question about.
local function noteRefusal(prompt, response)
    if response.err == 'forbidden' or response.err == 'no_session' then
        hiddenUntil[prompt] = GetGameTimer() + SUPPRESS_MS
    end
end

-- -----------------------------------------------------------------------------
-- Timed actions
-- -----------------------------------------------------------------------------

--- One timed action at a time *for the whole resource*, so a second prompt
--- cannot be started underneath the first one and land two calls on the server
--- from one player.
---
--- Held by `run()` for the progress circle *and* the call that follows it, not
--- by the progress circle alone: `lib.callback.await` yields, so an officer
--- released the moment the circle finished could start a second collection
--- while the first was still in flight -- which is the one thing this flag
--- exists to stop.
---
--- `client/destroy.lua` runs timed actions of its own and takes this same flag
--- through `Collect.runExclusive` at the bottom of this file, rather than
--- keeping a second one. A second flag would be open during exactly the window
--- above -- the server round trip after a circle has finished -- and a wipe
--- could start on top of an in-flight collection. `collect.lua` loads first
--- (see `fxmanifest.lua`), which is what lets the flag live here.
---
--- `lib.progressActive()` is *also* still consulted, in `idle()` below, and it
--- is not redundant: it is ox_lib-wide, so it sees the timed actions of every
--- other resource on the server, which this flag cannot. Dropping it would have
--- let a player eating through ox_inventory start a wipe on top of a live
--- progress bar. The flag is the half this resource knows about; the ox_lib
--- check is the half it does not.
local busy = false

--- Game time the flag must be released by, come what may. Zero while free.
---
--- `run()` holds the flag across `lib.callback.await`, and an await can fail to
--- return at all -- the core resource restarts mid-flight, the callback is
--- dropped -- in a way no `pcall` can see, because nothing was raised. Without
--- a deadline that leaves the flag set for the life of the Lua state, and since
--- `client/destroy.lua` shares it, it would permanently block destruction for
--- that player, which 8.10 says must never be blocked.
local busyUntil = 0

--- The longest a holder is believed, in milliseconds.
---
--- Comfortably over the longest timed action either file runs (cleaning blood,
--- 15 s) plus a server round trip, so an action that is merely slow is never
--- interrupted; short enough that a dropped callback costs a player half a
--- minute rather than a session. Past it the holder is treated as gone and the
--- next action takes the flag -- which is a bounded overlap, not a guarantee of
--- exclusivity, and is the trade made deliberately in destruction's favour.
local BUSY_MAX_MS <const> = 30000

--- Whether the flag is genuinely held, releasing an expired holder.
local function held()
    if not busy then return false end

    if GetGameTimer() >= busyUntil then
        busy = false
        busyUntil = 0

        return false
    end

    return true
end

--- Whether another action can be started, said out loud once.
---
--- Checked before the dialog rather than after it, so an officer who is already
--- kneeling over something is told now instead of after choosing packaging.
local function idle()
    if held() or lib.progressActive() then
        notify(FredPD.t('forensics.busy'), 'error')
        return false
    end

    return true
end

--- Runs one whole action -- the timed part in the world and the question for
--- the server -- with `busy` held for all of it.
---
--- Two different failures are covered here, and only together:
---
---   * **A raise.** `pcall` catches anything thrown inside `body` -- a route
---     answering something unexpected, ox_lib raising while the player
---     disconnects -- so the release below still runs. The error is re-raised
---     afterwards so it still reaches the console: swallowing it would trade
---     one silent failure for another.
---   * **A hang.** `pcall` cannot see one. `lib.callback.await` that never
---     returns raises nothing; the coroutine simply stops, and neither the
---     release nor the re-raise is ever reached. That is what `busyUntil` is
---     for: the flag carries a deadline from the moment it is taken, and
---     `held()` treats a holder past it as gone. Nothing rescues the hung
---     action itself -- it stays parked forever -- but it stops taking the rest
---     of the resource, and destruction in particular, down with it.
---
--- @param body function
--- @return boolean started false when another action already holds the flag
local function run(body)
    if not idle() then return false end

    busy = true
    busyUntil = GetGameTimer() + BUSY_MAX_MS

    local ok, err = pcall(body)

    busy = false
    busyUntil = 0

    if not ok then error(err, 0) end

    return true
end

--- The resource's one timed-action gate, for `client/destroy.lua`.
---
--- Same flag, same deadline, same `pcall`, the same `lib.progressActive()`
--- check against the rest of the server, and the same single `forensics.busy`
--- notification when it is already held -- so a wipe refuses underneath a
--- collection and a collection refuses underneath a wipe, in both cases for the
--- whole action including the server round trip. Destruction is not a police
--- feature (8.10) and this grants nothing: it is the same one-at-a-time rule,
--- not a check on who the player is. It is also the reason the hold is bounded:
--- a flag that could stick would block a wipe for ever, and 8.10 is explicit
--- that nothing may.
---
--- @param body function
--- @return boolean started
Collect.runExclusive = run

--- Runs a progress action. Only ever called from inside `run`, which is the one
--- place `busy` is set: a second check here would see the flag `run` had just
--- taken and refuse the action it is part of.
--- @return boolean completed
local function perform(label, duration, anim)
    local completed = lib.progressCircle({
        duration = duration,
        label = label,
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = anim,
    })

    return completed == true
end

-- -----------------------------------------------------------------------------
-- Collection (8.4, 8.5)
-- -----------------------------------------------------------------------------

local function packagingOptions()
    local options = {}

    for index = 1, #PACKAGING do
        options[index] = {
            value = PACKAGING[index],
            -- Built by concatenation from the packaging list, the same way the
            -- interface builds it. The keys themselves ship with the core.
            label = FredPD.t('evidence.packaging.' .. PACKAGING[index]),
        }
    end

    return options
end

--- The collection dialog: packaging, marker number, description (8.4, 8.5).
---
--- These three are genuinely the officer's to decide, which is why they are
--- asked for. Everything else about the item -- its number, its type, its
--- quality, its owner row and the first link of its chain of custody -- is
--- generated server-side by `evidence.collect` (invariant 1).
local function ask(trace)
    local dialog = lib.inputDialog(FredPD.t('evidence.collect.title'), {
        {
            type = 'select',
            label = FredPD.t('evidence.collect.packaging'),
            options = packagingOptions(),
            default = SUGGESTED_PACKAGING[trace.type] or SUGGESTED_PACKAGING.default,
            required = true,
        },
        {
            type = 'number',
            label = FredPD.t('evidence.collect.marker'),
            min = 1,
            max = 999,
            default = render.markerNumberFor(trace.key),
        },
        {
            type = 'input',
            label = FredPD.t('forensics.collect.description'),
            max = 512,
        },
    })

    if not dialog then return nil end

    local marker = tonumber(dialog[2])
    local description = dialog[3]

    if type(description) == 'string' and description:gsub('%s', '') == '' then
        description = nil
    end

    return {
        packaging = dialog[1],
        markerNumber = marker and math.floor(marker) or nil,
        description = description,
    }
end

local function collect(trace)
    if not idle() then return end

    local choice = ask(trace)
    if not choice then return end

    local duration = COLLECT_MS[trace.type] or COLLECT_MS.default

    -- The dialog is outside `run` on purpose: choosing packaging is not a timed
    -- action and holding the flag through it would refuse an officer their own
    -- tool menu while they read a select box. `run` re-checks `idle()` anyway,
    -- so two dialogs opened at once still produce one collection.
    run(function()
        if not perform(FredPD.t('forensics.collect.progress'), duration, COLLECT_ANIM) then
            notify(FredPD.t('forensics.collect.cancelled'))
            return
        end

        -- The key is the only thing about the trace that is sent. What it names
        -- -- and whether it names anything at all any more -- is the grid's
        -- answer, not this client's claim (8.3.2).
        local response = call('evidence.collect', {
            traceKey = trace.key,
            packaging = choice.packaging,
            markerNumber = choice.markerNumber,
            description = choice.description,
        })

        if not response.ok then
            noteRefusal('collect', response)
            showError(response)
            return
        end

        -- The server has already taken it out of the grid, so the next stream
        -- tick would remove it within the second. Dropping it now only makes
        -- the world agree with the officer's hands immediately.
        render.forget(trace.key)

        notify(FredPD.t('forensics.collect.done', {
            number = response.data and response.data.item and response.data.item.evidenceNumber or '?',
        }), 'success')
    end)
end

-- -----------------------------------------------------------------------------
-- Numbered evidence markers (8.4)
-- -----------------------------------------------------------------------------

local function placeMarker(trace)
    local dialog = lib.inputDialog(FredPD.t('forensics.marker.title'), {
        {
            type = 'number',
            label = FredPD.t('forensics.marker.number'),
            min = 1,
            max = 999,
            default = render.markerNumberFor(trace.key) or render.nextMarkerNumber(),
            required = true,
        },
    })

    if not dialog then return end

    local number = tonumber(dialog[1])
    if not number then return end

    render.placeMarker(trace, number)
    notify(FredPD.t('forensics.marker.placed', { number = math.floor(number) }))
end

-- -----------------------------------------------------------------------------
-- The gunshot residue swab (8.2, 8.5)
-- -----------------------------------------------------------------------------

--- The server id of the player a ped belongs to, or nil when it is not one.
---
--- This is the whole of what the swab sends about the person being swabbed, and
--- it is a name rather than a claim: the server resolves it back to a ped of its
--- own, measures the distance between its copy of the two positions and refuses
--- a swab taken across the map (8.3.2). Nothing about the residue -- whether
--- there is any, how strong it is, how long ago they fired -- is known here or
--- asked for (8.11).
---
--- `NetworkGetPlayerIndexFromPed` answers -1 for an NPC, and `GetPlayerServerId`
--- answers 0 for an index it cannot place; either is somebody there is no swab
--- to take, and the schema's `min = 1` would refuse the call anyway.
---
--- Both are client natives. They are declared inline here rather than in
--- `.luacheckrc`, where the rest of this resource's natives live, because this
--- file was the only part of the tree the change that added the swab could
--- touch. Moving the two names into that file's `**/client/**/*.lua` block is a
--- behaviour-free follow-up, and this line goes with them when they move.
-- luacheck: read globals NetworkGetPlayerIndexFromPed GetPlayerServerId
local function serverIdOf(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    local player = NetworkGetPlayerIndexFromPed(ped)
    if not player or player == -1 then return nil end

    local serverId = GetPlayerServerId(player)
    if not serverId or serverId < 1 then return nil end

    return serverId
end

--- Swabs a person's hands and clothes for gunshot residue (8.2).
---
--- The same route the casing on the pavement goes through, because a swab *is*
--- a collection: one item, one owner row, one first link of the custody chain,
--- written in the one transaction (8.5, 8.6). Residue has no position and so no
--- trace key, which is why the call names a `targetId` instead -- the two are
--- exclusive and the server refuses a call carrying both.
---
--- There is no dialog. The other collections ask for packaging because an
--- officer reaching for the wrong container is a mistake they are allowed to
--- make at a scene; a swab goes in a swab box and there is nothing to choose,
--- so the same value the collection dialog would have offered as its default
--- for residue is sent directly. No marker number either: a marker stands next
--- to something on the ground, and this is a person.
---
--- Held by `run` for the progress circle *and* the call after it, like every
--- other action in this resource, so a swab cannot be started underneath a
--- collection or a wipe and neither can be started underneath a swab.
local function swab(ped)
    local targetId = serverIdOf(ped)
    if not targetId then return end

    -- `run` is the gate as well as the flag, so there is no `idle()` here: with
    -- no dialog there is nothing to ask the officer before the circle starts.
    run(function()
        if not perform(FredPD.t('forensics.swab.progress'), SWAB_MS, TOOL_ANIM) then
            notify(FredPD.t('forensics.swab.cancelled'))
            return
        end

        local response = call('evidence.collect', {
            targetId = targetId,
            packaging = SUGGESTED_PACKAGING.gsr,
        })

        if not response.ok then
            noteRefusal('swab', response)

            -- One message for every refusal, and `showError` deliberately not
            -- used here. The server answers `not_found` to every way a swab
            -- comes to nothing -- no such player, out of reach, nothing on
            -- their hands, residue already decayed, nobody the sample could be
            -- attributed to -- precisely so they cannot be told apart, and
            -- naming the code would start sorting them for the officer (8.11).
            notify(FredPD.t('forensics.swab.failed'), 'error')
            return
        end

        -- Nothing to forget: residue was never streamed to this client and
        -- there is no prop, no zone and no key to drop. What changed is on the
        -- server, where `claimGsr` cleared it -- a second officer swabbing the
        -- same hands finds nothing, exactly as a second officer reaching for
        -- the same casing does.
        notify(FredPD.t('forensics.swab.done'), 'success')
    end)
end

--- The prompt, on a player rather than on a trace.
---
--- `render.registerInteraction` is the wrong mechanism for this one: it hangs
--- options off the sphere zones this client builds around streamed traces, and
--- residue is never in the grid, so there is no zone for it to hang off.
--- `addGlobalPlayer` is the ox_target registry for other players' peds, and it
--- is registered once at load: it costs nothing until somebody looks at
--- somebody (12.1).
---
--- Drawn for anyone standing next to another player, which is as much as this
--- machine can honestly say. Whether the person holding the swab may take it is
--- the server's answer and not this file's (invariant 4): `evidence.collect`
--- carries `forensics.evidence.collect` and the on-duty condition, and refuses
--- everybody else. The suppression above only stops that refusal following an
--- officer down a crowded street.
local SWAB_NAME <const> = 'fredpd_collect_swab'

exports.ox_target:addGlobalPlayer({
    {
        name = SWAB_NAME,
        icon = 'fa-solid fa-vial',
        label = FredPD.t('forensics.swab.option'),
        distance = ZONE_DISTANCE,
        canInteract = function(entity)
            return not suppressed('swab') and serverIdOf(entity) ~= nil
        end,
        onSelect = function(data) swab(data and data.entity) end,
    },
})

--- Never leave the option behind on a restart. ox_target keeps it keyed by
--- name, and a reload would otherwise leave a prompt on every player that calls
--- into a Lua state that no longer exists -- the same reason
--- `client/destroy.lua` removes its global options.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    exports.ox_target:removeGlobalPlayer({ SWAB_NAME })
end)

-- -----------------------------------------------------------------------------
-- The prompts on a trace
-- -----------------------------------------------------------------------------

render.registerInteraction(function(trace)
    return {
        name = 'fredpd_collect_' .. trace.key,
        icon = 'fa-solid fa-box-archive',
        label = FredPD.t('forensics.collect.option', {
            -- The type is render data: it is what the trace is, not whose it is.
            type = FredPD.t('evidence.type.' .. trace.type),
        }),
        distance = ZONE_DISTANCE,
        canInteract = function() return not suppressed('collect') end,
        onSelect = function() collect(trace) end,
    }
end)

render.registerInteraction(function(trace)
    return {
        name = 'fredpd_marker_' .. trace.key,
        icon = 'fa-solid fa-location-pin',
        label = FredPD.t('forensics.marker.option'),
        distance = ZONE_DISTANCE,
        canInteract = function() return not suppressed('collect') end,
        onSelect = function() placeMarker(trace) end,
    }
end)

-- -----------------------------------------------------------------------------
-- The tools (8.4)
-- -----------------------------------------------------------------------------

--- Works the ground the officer is standing on with one tool.
---
--- The radius is the server's and the position is the server's. This call says
--- which tool was used and nothing else, and the answer is a count: how many
--- traces became visible. Not what they are, not where, not whose -- those reach
--- the client as render data if they reach it at all (8.11).
local function useTool(tool, label)
    if not TOOL_MS[tool] then return end

    -- `run` is the gate as well as the flag, so there is no `idle()` here: the
    -- tool menu has nothing to ask the officer first.
    run(function()
        if not perform(FredPD.t('forensics.tool.progress', { tool = label }), TOOL_MS[tool], TOOL_ANIM) then
            notify(FredPD.t('forensics.tool.cancelled'))
            return
        end

        local response = call('forensics.process', { tool = tool })

        if not response.ok then
            showError(response)
            return
        end

        local found = (response.data and response.data.found) or 0

        if found > 0 then
            notify(FredPD.t('forensics.tool.found', { count = found }), 'success')
        else
            notify(FredPD.t('forensics.tool.nothing'))
        end
    end)
end

--- The kit. Registered once, because every label in it is static.
---
--- Which tools an officer may actually use is the server's answer: the route
--- behind each of these carries `forensics.tools.use` and the on-duty condition,
--- and a menu entry is not a grant.
lib.registerContext({
    id = TOOL_MENU,
    title = FredPD.t('forensics.tools.title'),
    options = {
        {
            title = FredPD.t('forensics.tool.powder'),
            description = FredPD.t('forensics.tool.powderHint'),
            icon = 'fa-solid fa-fingerprint',
            onSelect = function()
                useTool('powder', FredPD.t('forensics.tool.powder'))
            end,
        },
        {
            title = FredPD.t('forensics.tool.luminol'),
            description = FredPD.t('forensics.tool.luminolHint'),
            icon = 'fa-solid fa-spray-can',
            onSelect = function()
                useTool('luminol', FredPD.t('forensics.tool.luminol'))
            end,
        },
        {
            title = FredPD.t('forensics.tool.forensic_light'),
            description = FredPD.t('forensics.tool.forensicLightHint'),
            icon = 'fa-solid fa-lightbulb',
            onSelect = function()
                useTool('forensic_light', FredPD.t('forensics.tool.forensic_light'))
            end,
        },
        {
            title = FredPD.t('forensics.tools.clearMarkers'),
            description = FredPD.t('forensics.tools.clearMarkersHint'),
            icon = 'fa-solid fa-broom',
            onSelect = function()
                notify(FredPD.t('forensics.marker.cleared', { count = render.clearMarkers() }))
            end,
        },
    },
})

--- Opening the kit is a client command that opens a menu, not a path to the
--- server: every entry in it goes through a route (invariant 3).
RegisterCommand(COMMAND, function()
    lib.showContext(TOOL_MENU)
end, false)

--- No default key, so nothing is taken from a player who already bound one.
RegisterKeyMapping(COMMAND, FredPD.t('forensics.tools.keybind'), 'keyboard', '')

-- -----------------------------------------------------------------------------
-- For an item to hang off
-- -----------------------------------------------------------------------------

--- Uses a tool by name, for an inventory item handler to call.
---
--- Exposed so that "use the fingerprint powder in your inventory" can run the
--- same timed action as the menu does, once the item side of 8.4 exists. It
--- still ends in `forensics.process`, which still checks the permission, the
--- duty context and the rate limit.
function Collect.useTool(tool)
    local labels = {
        powder = FredPD.t('forensics.tool.powder'),
        luminol = FredPD.t('forensics.tool.luminol'),
        forensic_light = FredPD.t('forensics.tool.forensic_light'),
    }

    if not labels[tool] then return end

    useTool(tool, labels[tool])
end

FredPDForensics.Client.collect = Collect
