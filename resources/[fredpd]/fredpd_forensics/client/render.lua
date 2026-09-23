--- Drawing the evidence the server streamed to this client (spec 8.4, 8.1.6, 12.1).
---
--- This file renders render data and holds no opinions about it. Three rules
--- shape everything below:
---
---   * **What arrives is what exists.** `fredpd:evidence:cells` carries a key, a
---     type, a position and a model -- `FredPD.Modules.evidence.renderData` and
---     nothing more (8.1.6, 8.11). There is no owner in it, no quality and no
---     record id, so there is nothing here to leak and nothing to ask about.
---   * **Latent evidence is not hidden here, it is absent.** A print, a glove
---     mark, touch DNA, a cleaned pool of blood: the server does not send them
---     at all until a tool has revealed them, and then only to a session cleared
---     to use forensic tools. So there is deliberately no "hide until revealed"
---     branch in this file -- a client-side one would mean the data was already
---     on the machine, which is exactly what 8.11 forbids. If it arrived, it is
---     drawn.
---   * **Persist, never rebuild.** The stream is at most one update per second
---     per cell (12.1) and it is a delta: a cell arrives with its whole current
---     contents, and the keys that were already there are the same traces. They
---     keep their prop, their zone and their fade, and only the difference is
---     spawned or deleted. Re-creating a cell's props once a second would make
---     every casing in the city blink, and would cost more than the stream does.
---
--- Interaction lives in `collect.lua`; this file owns the entities and the
--- target zones they hang off, and asks that file what to put in them.

FredPDForensics = FredPDForensics or {}
FredPDForensics.Client = FredPDForensics.Client or {}

local Render = {}

-- -----------------------------------------------------------------------------
-- Rendering settings
-- -----------------------------------------------------------------------------

--- How far a trace without a prop is drawn as a marker. Well inside the 96 m
--- the server streams (8.1.6): being told about something and drawing it at
--- full distance are different budgets.
local DRAW_DISTANCE <const> = 25.0

--- How close the number on an evidence marker is legible from.
local NUMBER_DISTANCE <const> = 14.0

--- How often the draw thread rebuilds the short list of things near the player,
--- in milliseconds. Everything in between iterates that list and nothing else.
local SCAN_INTERVAL <const> = 500

--- What the draw thread waits when there is nothing in the world to draw. The
--- early-out is a single `next()` on an empty table, which is what keeps this
--- resource at 0.00 ms while nobody is standing at a scene (12.1).
local IDLE_WAIT <const> = 500

--- How long a newly streamed trace fades in over, in milliseconds. The stream
--- is a one hertz delta, so without this a casing appears between two frames;
--- with it, a cell that arrives late looks like something being noticed rather
--- than something popping into existence.
local FADE_MS <const> = 400

--- The interaction sphere around a trace, in metres. Deliberately tighter than
--- the server's 3 m collection range, so reaching a prompt means being in
--- reach: the server re-measures against its own copy of where the player is
--- and refuses otherwise (8.3.2), and a prompt that reached further would only
--- produce refusals.
local ZONE_RADIUS <const> = 1.0

--- The prop an evidence marker is placed as (8.4).
---
--- A replicated convar, because it is a rendering decision a server makes about
--- its own prop set, and `setr` is what a client can read. An unknown model
--- falls back to a drawn marker with the number above it rather than leaving an
--- invisible marker at the scene -- the same choice `client/placements.lua`
--- makes for a misconfigured ped.
local MARKER_MODEL <const> = (function()
    local convar = GetConvar('fredpd:forensics:markerProp', '')
    if convar ~= '' then return convar end

    return 'prop_cs_documents_01'
end)()

--- Marker colours by evidence type. Agency software, not a rave (invariant 12):
--- these are muted, and the alpha is low enough that a scene reads as a place
--- with things in it rather than a light show.
---
--- `{ r, g, b, alpha }`.
local COLOURS <const> = {
    -- Physical items anybody can see, and pick up again (8.10).
    casing = { 198, 168, 96, 170 },
    bullet = { 198, 168, 96, 170 },
    magazine = { 186, 176, 150, 170 },
    -- Blood, fresh or found with luminol.
    blood = { 150, 52, 48, 170 },
    -- Ridge detail and glove marks, once powder has found them.
    print = { 196, 204, 216, 160 },
    glove_mark = { 176, 184, 198, 160 },
    tool_mark = { 176, 184, 198, 160 },
    -- What the forensic light picks out.
    dna_touch = { 140, 174, 180, 160 },
    drug_residue = { 150, 166, 150, 160 },
    footwear = { 158, 168, 178, 160 },
    default = { 190, 190, 190, 150 },
}

local MARKER_SIZE <const> = 0.12
local MARKER_COLOUR <const> = { 214, 186, 88, 190 }

-- -----------------------------------------------------------------------------
-- State
-- -----------------------------------------------------------------------------

--- traceKey -> the trace as it was streamed, plus what this client made of it:
--- `object` (a prop, when the server configured a model), `zone` (its ox_target
--- id), `at` (when it arrived, for the fade) and `cell`.
local traces = {}

--- cellKey -> { traceKey -> true }. What each cell held at the last update, so
--- reconciling a cell is a diff rather than a walk of the world.
local cells = {}

--- Numbered evidence markers this officer has placed (8.4). Local decoration:
--- the number that matters is the one recorded with the item at collection, and
--- that is written server-side by `evidence.collect`.
local markers = {}
local markerByTrace = {}

--- Option builders registered by `collect.lua`. Each is called with a trace and
--- answers an ox_target option, or nil when it does not apply.
local builders = {}

--- The short lists the draw thread iterates, rebuilt every `SCAN_INTERVAL`.
local nearTraces = {}
local nearMarkers = {}

-- -----------------------------------------------------------------------------
-- Props
-- -----------------------------------------------------------------------------

--- Spawns a prop for something in the world, off the main path.
---
--- Client-side and not networked, on purpose: every client builds its own world
--- from the render data it was sent, so there is nothing here to broadcast and
--- no entity anybody else's machine has to be told about (invariant 5).
---
--- @param model string
--- @param x number
--- @param y number
--- @param z number
--- @param keep function called with the handle; answers false when whatever
---   asked for the prop has gone away in the meantime, in which case it is
---   deleted again rather than left in the world. Called with `nil`, and its
---   answer ignored, when there is no prop to keep -- see below.
--- @return boolean false when this client has no such model, so the caller can
---   draw the thing itself instead. Answering nothing here is what made
---   evidence invisible in ef88b44: the caller had already decided not to draw
---   a marker by the time this gave up, so a server whose configured model is
---   missing on a client put evidence at a scene that nobody could see (8.4).
local function spawnProp(model, x, y, z, keep)
    local hash = joaat(model)

    if not IsModelInCdimage(hash) then
        print(('[fredpd_forensics] unknown prop model "%s", drawing a marker instead'):format(model))
        return false
    end

    CreateThread(function()
        -- A model that is in the archive but never streams in is the same
        -- outcome for the officer standing at the scene as one that is not
        -- there at all, so it takes the same path back to the caller: `nil`,
        -- and the caller draws something. `lib.requestModel` raises on timeout
        -- rather than answering, hence the pcall.
        local loaded = pcall(lib.requestModel, hash, 10000)
        local object = loaded and CreateObject(hash, x, y, z, false, false, false) or nil

        if not object or object == 0 or not DoesEntityExist(object) then
            keep(nil)
            return
        end

        SetEntityCollision(object, false, false)
        FreezeEntityPosition(object, true)
        SetModelAsNoLongerNeeded(hash)

        if not keep(object) and DoesEntityExist(object) then
            DeleteEntity(object)
        end
    end)

    return true
end

local function deleteProp(object)
    if object and DoesEntityExist(object) then DeleteEntity(object) end
end

-- -----------------------------------------------------------------------------
-- Target zones
-- -----------------------------------------------------------------------------

local function optionsFor(trace)
    local options = {}

    for index = 1, #builders do
        local option = builders[index](trace)
        if option then options[#options + 1] = option end
    end

    return options
end

--- Hangs the registered interactions off a trace.
---
--- One sphere per trace, created when the trace arrives and removed when it
--- goes. Nothing is re-created while a trace persists, which is the same reason
--- the props are not: the stream re-sends a cell whenever anything in it
--- changes, and rebuilding every zone in the cell each time would churn
--- ox_target once a second for as long as anyone stood there.
local function attachZone(trace)
    if trace.zone then return end

    local options = optionsFor(trace)
    if #options == 0 then return end

    trace.zone = exports.ox_target:addSphereZone({
        coords = vec3(trace.x, trace.y, trace.z),
        radius = ZONE_RADIUS,
        debug = false,
        options = options,
    })
end

local function detachZone(trace)
    if not trace.zone then return end

    exports.ox_target:removeZone(trace.zone)
    trace.zone = nil
end

-- -----------------------------------------------------------------------------
-- Traces
-- -----------------------------------------------------------------------------

local function addTrace(cellKey, data)
    local trace = {
        key = data.key,
        type = data.type,
        x = data.x,
        y = data.y,
        z = data.z,
        model = data.model,
        cell = cellKey,
        at = GetGameTimer(),
        -- A type with no configured prop is drawn as a marker. The server ships
        -- no models at all by default and says why: a model name is a rendering
        -- decision, and guessing one here would be worse than a marker.
        drawMarker = data.model == nil or data.model == '',
    }

    traces[trace.key] = trace
    attachZone(trace)

    if not trace.drawMarker then
        -- The marker is the fallback the field above promises it is, so the
        -- answer has to be read and the failure inside the spawn has to come
        -- back. A trace with neither a prop nor a marker is evidence at a scene
        -- that nobody standing on it can see (8.4). `scan()` rebuilds its list
        -- twice a second, so flipping the flag late shows the marker within
        -- half a second rather than requiring the stream to re-send the cell.
        local spawning = spawnProp(trace.model, trace.x, trace.y, trace.z, function(object)
            -- Collected, decayed or streamed away while the model loaded.
            if traces[trace.key] ~= trace then return false end

            if not object then
                trace.drawMarker = true
                return false
            end

            trace.object = object
            return true
        end)

        if not spawning then trace.drawMarker = true end
    end
end

--- Takes a trace out of the world on this client.
---
--- Called when the server stops sending it -- because somebody collected it,
--- because it decayed, or because the player walked out of its cell. The three
--- are indistinguishable from here, which is correct: the client is not told
--- which of them happened (8.11).
local function removeTrace(key)
    local trace = traces[key]
    if not trace then return end

    detachZone(trace)
    deleteProp(trace.object)

    traces[key] = nil

    local cell = cells[trace.cell]
    if cell then cell[key] = nil end
end

--- Applies one cell's current contents.
---
--- The payload is the whole cell, so anything missing from it is gone and
--- anything already present is the same trace it was a second ago. Persisting
--- those is the entire point of the diff (12.1).
local function applyCell(cellKey, items)
    local previous = cells[cellKey] or {}
    local current = {}

    for index = 1, #items do
        local item = items[index]

        if type(item) == 'table' and type(item.key) == 'string' then
            current[item.key] = true

            if not traces[item.key] then
                addTrace(cellKey, item)
            end
        end
    end

    for key in pairs(previous) do
        if not current[key] then removeTrace(key) end
    end

    if next(current) == nil then
        cells[cellKey] = nil
    else
        cells[cellKey] = current
    end
end

--- The stream (8.1.6). One message per client per second at most, carrying
--- every cell that changed since the last one.
RegisterNetEvent('fredpd:evidence:cells', function(payload)
    if type(payload) ~= 'table' or type(payload.cells) ~= 'table' then return end

    for index = 1, #payload.cells do
        local entry = payload.cells[index]

        if type(entry) == 'table' and type(entry.cell) == 'string' then
            applyCell(entry.cell, type(entry.items) == 'table' and entry.items or {})
        end
    end
end)

-- -----------------------------------------------------------------------------
-- Numbered evidence markers (8.4)
-- -----------------------------------------------------------------------------

--- The next unused number, offered as the default in the collection dialog.
function Render.nextMarkerNumber()
    local highest = 0

    for index = 1, #markers do
        if markers[index].number > highest then highest = markers[index].number end
    end

    return highest + 1
end

--- The number already standing on a trace, if this officer marked it.
function Render.markerNumberFor(traceKey)
    local marker = markerByTrace[traceKey]
    return marker and marker.number or nil
end

--- Places a numbered marker on a trace.
---
--- The marker is drawn by this client for this client. The number only becomes
--- a record when it is passed to `evidence.collect`, which writes it on the item
--- server-side -- markers in the world are how a scene is read, and the item's
--- marker number is what the record says (8.4, 8.5).
---
--- @param trace table a trace from `Render.get`
--- @param number number
function Render.placeMarker(trace, number)
    if not trace or type(number) ~= 'number' then return end

    Render.clearMarker(trace.key)

    local marker = {
        number = math.floor(number),
        traceKey = trace.key,
        x = trace.x,
        y = trace.y,
        z = trace.z,
    }

    markers[#markers + 1] = marker
    markerByTrace[trace.key] = marker

    -- No branch on the answer here, unlike a trace: the draw loop already draws
    -- a marker under any number whose `object` is nil, so a missing model is
    -- already the fallback for this one.
    spawnProp(MARKER_MODEL, marker.x, marker.y, marker.z, function(object)
        if markerByTrace[trace.key] ~= marker then return false end
        if not object then return false end

        marker.object = object
        return true
    end)
end

--- Removes the marker standing on a trace, if there is one.
function Render.clearMarker(traceKey)
    local marker = markerByTrace[traceKey]
    if not marker then return end

    deleteProp(marker.object)
    markerByTrace[traceKey] = nil

    for index = #markers, 1, -1 do
        if markers[index] == marker then table.remove(markers, index) end
    end
end

--- Clears every marker this officer placed. Offered in the tool menu, for the
--- end of a scene.
--- @return number how many were removed
function Render.clearMarkers()
    local removed = #markers

    for index = 1, #markers do
        deleteProp(markers[index].object)
    end

    markers = {}
    markerByTrace = {}
    nearMarkers = {}

    return removed
end

-- -----------------------------------------------------------------------------
-- Interaction surface, filled in by collect.lua
-- -----------------------------------------------------------------------------

--- Registers an ox_target option builder.
---
--- `builder(trace)` answers an option table, or nil for a trace it does not
--- apply to. Zones already in the world are rebuilt once, so registration order
--- against the stream does not matter.
function Render.registerInteraction(builder)
    builders[#builders + 1] = builder

    for _, trace in pairs(traces) do
        detachZone(trace)
        attachZone(trace)
    end
end

--- A streamed trace by key, for `collect.lua`. Everything in it came from the
--- server in render data; there is nothing else to hand out.
function Render.get(traceKey)
    return traces[traceKey]
end

--- The closest streamed trace of one type within a radius, or nil.
---
--- For the fingerprint scanner's quick-scan: it needs *a* nearby print without
--- the officer picking one off a target menu, the same way the GSR swab needs
--- no key at all. Only ever finds a trace this client has already been sent,
--- so it is no more of an oracle than looking at the screen already is (8.11) --
--- it cannot name a print the officer has not been streamed, and the server
--- still re-measures distance itself when the collection call reaches it.
---
--- @param kind string trace type, e.g. 'print'
--- @param position vector3
--- @param radius number
--- @return table|nil
function Render.nearestOfType(kind, position, radius)
    local nearest, nearestDistance = nil, radius

    for _, trace in pairs(traces) do
        if trace.type == kind then
            local distance = #(position - vec3(trace.x, trace.y, trace.z))

            if distance <= nearestDistance then
                nearest, nearestDistance = trace, distance
            end
        end
    end

    return nearest
end

--- Drops a trace immediately, without waiting for the next stream tick.
---
--- Used after a successful collection so the casing disappears as the officer
--- bags it rather than up to a second later. Not a decision: the server has
--- already taken it out of the grid, and the next push would remove it anyway.
function Render.forget(traceKey)
    removeTrace(traceKey)
end

-- -----------------------------------------------------------------------------
-- Drawing
-- -----------------------------------------------------------------------------

local function drawTrace(trace, now)
    local colour = COLOURS[trace.type] or COLOURS.default
    local fade = math.min((now - trace.at) / FADE_MS, 1.0)

    DrawMarker(
        28,
        trace.x, trace.y, trace.z + 0.02,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        MARKER_SIZE, MARKER_SIZE, MARKER_SIZE,
        colour[1], colour[2], colour[3], math.floor(colour[4] * fade),
        false, false, 2, false, nil, nil, false
    )
end

local function drawNumber(marker)
    SetDrawOrigin(marker.x, marker.y, marker.z + 0.45, 0)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextScale(0.32, 0.32)
    SetTextColour(226, 226, 226, 210)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(tostring(marker.number))
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

--- Rebuilds the short lists the fast path iterates.
---
--- Walks everything this client has been told about, which is bounded by the
--- streaming range and the per-cell cap rather than by the size of the world.
local function scan(position)
    nearTraces = {}
    nearMarkers = {}

    for _, trace in pairs(traces) do
        if trace.drawMarker and #(position - vec3(trace.x, trace.y, trace.z)) <= DRAW_DISTANCE then
            nearTraces[#nearTraces + 1] = trace
        end
    end

    for index = 1, #markers do
        local marker = markers[index]

        if #(position - vec3(marker.x, marker.y, marker.z)) <= NUMBER_DISTANCE then
            nearMarkers[#nearMarkers + 1] = marker
        end
    end
end

--- The one loop in this resource.
---
--- It costs a table lookup every half second when there is nothing in the world
--- -- which is the state a client is in almost all of the time -- and only runs
--- per frame while something is actually within sight of the player (12.1).
--- Traces the server gave a prop to are not drawn at all: the prop is the
--- rendering, and it costs nothing per frame.
CreateThread(function()
    local nextScan = 0

    while true do
        local sleep = IDLE_WAIT

        if next(traces) ~= nil or #markers > 0 then
            local now = GetGameTimer()

            if now >= nextScan then
                nextScan = now + SCAN_INTERVAL
                scan(GetEntityCoords(PlayerPedId()))
            end

            if #nearTraces > 0 or #nearMarkers > 0 then
                sleep = 0

                for index = 1, #nearTraces do
                    drawTrace(nearTraces[index], now)
                end

                for index = 1, #nearMarkers do
                    local marker = nearMarkers[index]

                    if not marker.object then
                        -- No prop, because the configured model is unknown to
                        -- this client. The number still has to stand somewhere.
                        DrawMarker(
                            21,
                            marker.x, marker.y, marker.z + 0.15,
                            0.0, 0.0, 0.0,
                            0.0, 0.0, 0.0,
                            0.2, 0.2, 0.2,
                            MARKER_COLOUR[1], MARKER_COLOUR[2], MARKER_COLOUR[3], MARKER_COLOUR[4],
                            false, false, 2, false, nil, nil, false
                        )
                    end

                    drawNumber(marker)
                end
            end
        elseif #nearTraces > 0 or #nearMarkers > 0 then
            nearTraces = {}
            nearMarkers = {}
        end

        Wait(sleep)
    end
end)

-- -----------------------------------------------------------------------------
-- Teardown
-- -----------------------------------------------------------------------------

--- Never leave props or target zones behind. A restart of this resource with
--- objects still in the world would leave casings nobody can collect and zones
--- ox_target still believes in.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for key in pairs(traces) do
        local trace = traces[key]
        detachZone(trace)
        deleteProp(trace.object)
    end

    traces = {}
    cells = {}

    Render.clearMarkers()
end)

FredPDForensics.Client.render = Render

-- -----------------------------------------------------------------------------
-- Cross-resource exports
-- -----------------------------------------------------------------------------

--- For `fredpd`'s fingerprint scanner placement, which has no trace table of
--- its own -- this resource owns every trace a client has been streamed
--- (8.1.6), and a placement is a `fredpd` concept this resource never touches
--- otherwise. Answers a key, never the trace itself: naming what to collect
--- is all a placement needs, and the collection call still goes to
--- `evidence.collect` exactly as it does from a target zone (8.11).
exports('nearestPrintTraceKey', function(x, y, z, radius)
    local trace = Render.nearestOfType('print', vec3(x, y, z), radius)
    return trace and trace.key or nil
end)

--- So a successful scan drops the trace immediately, the same as bagging one
--- from a target zone does (`Render.forget`).
exports('forgetTrace', function(traceKey)
    Render.forget(traceKey)
end)
