--- The live grid of uncollected evidence (spec 8.3.5, 8.1.6, 12.1).
---
--- Everything lying in the world that has not been collected yet lives here, in
--- memory, keyed by grid cell. It is in the core resource rather than in
--- `fredpd_forensics` because every row in it carries an owner -- the source
--- player's hidden identifier -- and hidden truth does not leave the core
--- (ADR-011, 8.1).
---
--- Three rules hold this file together:
---
---   * **A client is told render data and nothing else.** Every payload that
---     leaves here is built by `FredPD.Modules.evidence.renderData`, which
---     carries a key, a type, a position and a model. There is no other way out
---     of this module, and `renderData` is not widened to make one (8.11).
---   * **Nothing is broadcast.** Pushes name one player at a time, to the
---     players subscribed to the cell that changed (invariant 5). The `-1`
---     target does not appear in this file and must not.
---   * **One update per second per cell per client** (12.1). The loop runs at
---     one hertz and sends one message per client carrying every cell that
---     changed since that client's last message. Pushing per item would blow
---     the budget with a single magazine.
---
--- Decay is swept on a timer, not on read. A read happens once per client per
--- second; the sweep happens once every half minute for the whole world.

FredPD = FredPD or {}
FredPD.Forensics = FredPD.Forensics or {}

local Grid = {}

local service = FredPD.Modules.forensics
local evidence = FredPD.Modules.evidence

--- Resolved once at boot from `config/server.lua`, falling back to the
--- documented defaults in `service.lua` when a server has not configured
--- forensics at all.
local config = service.settings(FredPD.Config.server and FredPD.Config.server.forensics)

--- cellKey -> list of items. The shape `service.placeIn` expects, and the only
--- table that holds a trace.
local cells = {}

--- cellKey -> a number that changes whenever the cell's contents change. A
--- client is re-sent a cell when the version it last saw is not this one, which
--- is what makes the push a delta rather than a poll.
local versions = {}

--- traceKey -> cellKey, so claiming a trace does not scan the world.
local located = {}

--- cellKey -> { version, plain, privileged }: the render lists for a cell,
--- rebuilt when its version moves. Two lists rather than one because a revealed
--- latent trace is visible to an officer with tools and to nobody else, and
--- rebuilding per client per second at 200 players is exactly the cost spec
--- 12.1 budgets against.
local rendered = {}

--- src -> { version = {}, any = {}, privileged = boolean }
---
--- What each connected player has been told. `version` is the cell version last
--- sent, `any` whether that payload had anything in it -- which is what decides
--- whether leaving the cell needs a message at all.
local subscriptions = {}

--- How many traces are in the grid, kept as a running count so the global cap
--- does not cost a walk of the world to check.
local itemCount = 0

--- Counters for the admin health screen (spec 12.3). Never per-player, never
--- per-trace: totals only, so nothing here can become a record.
local stats = { placed = 0, merged = 0, evicted = 0, refused = 0, collected = 0 }

--- Trace keys are unique for the life of the resource and mean nothing.
---
--- A counter and a boot salt rather than randomness: `math.random` is banned in
--- the test harness, and a key does not need to be unguessable. Guessing one
--- buys nothing, because collection checks that the player is standing next to
--- the trace against the server's copy of their position, and a key that names
--- no trace is a refusal.
local keySalt = ('%x'):format(os.time() % 0xFFFFFF)
local keySequence = 0

local function nextKey()
    keySequence = keySequence + 1
    return ('%s%x'):format(keySalt, keySequence)
end

--- Marks a cell changed, so every subscriber is re-sent it within the second.
local function touch(cellKey)
    versions[cellKey] = (versions[cellKey] or 0) + 1
    rendered[cellKey] = nil
end

-- -----------------------------------------------------------------------------
-- Writing
-- -----------------------------------------------------------------------------

--- Puts a trace into the world.
---
--- The caller has already decided that this trace exists and who it belongs to
--- (`routes.lua`, 8.3.2). This function decides nothing about truth: it fills in
--- the bookkeeping -- key, age, latency, merge key -- and files it.
---
--- @param trace table { type, x, y, z, heading, model, owner, quality, count }
--- @return table|nil stored the trace now in the grid, which may be one it
---   merged into (8.3.5); nil when the world is full
--- @return boolean merged
function Grid.place(trace)
    -- The global cap (12.2). Rate limits bound how fast one player can generate;
    -- this bounds every player at once. Sweeping first means a full world that
    -- is merely stale empties itself instead of refusing.
    if itemCount >= config.maxItems then
        Grid.sweep()

        if itemCount >= config.maxItems then
            stats.refused = stats.refused + 1
            return nil, false
        end
    end

    local item = {
        key = nextKey(),
        type = trace.type,
        x = trace.x,
        y = trace.y,
        z = trace.z,
        heading = trace.heading or 0.0,
        -- The prop is a rendering decision and comes from configuration, never
        -- from the observation that created the trace.
        model = (config.models or {})[trace.type],
        -- Hidden truth (8.1). Present on every trace, on the server, always.
        owner = trace.owner,
        ownerKey = service.ownerKey(trace.owner),
        quality = trace.quality or 100,
        count = trace.count or 1,
        createdAt = os.time(),
        -- Latent traces are in the world but invisible until a tool is used on
        -- them (8.4). Until then they are not sent to anybody at all -- not
        -- hidden in the payload, absent from it.
        latent = service.isLatent(trace.type),
        revealed = false,
        sceneId = trace.sceneId,
        outdoors = trace.outdoors,
        cleaned = false,
        -- Which door, which panel. Recorded for the description an officer
        -- writes at collection; never used as a position, because the client
        -- that named it is not where positions come from (8.3.2).
        part = trace.part,
    }

    local stored, merged, cellKey = service.placeIn(cells, item, config)

    if merged then
        stats.merged = stats.merged + 1
    else
        located[stored.key] = cellKey
        itemCount = itemCount + 1
        stats.placed = stats.placed + 1
    end

    touch(cellKey)

    return stored, merged
end

--- Takes a trace out of the world.
---
--- Removal is the collection: the trace stops existing here as the row is
--- written in `evidence.collect`, so two officers cannot collect the same
--- casing and a failed insert cannot leave half a collection behind.
---
--- @param traceKey string
--- @return table|nil the removed trace, owner and all
function Grid.take(traceKey)
    local cellKey = located[traceKey]
    if not cellKey then return nil end

    local cell = cells[cellKey]
    if not cell then
        located[traceKey] = nil
        return nil
    end

    for index = 1, #cell do
        if cell[index].key == traceKey then
            local item = table.remove(cell, index)

            located[traceKey] = nil
            itemCount = itemCount - 1
            stats.collected = stats.collected + 1

            if #cell == 0 then
                -- The last trace in the cell. Forgetting the version with it
                -- keeps the bookkeeping from outliving the cell, and reads as a
                -- change to everyone subscribed -- they were told about version
                -- n and the cell is back at nothing -- so the casing disappears
                -- from the world for them within the second.
                cells[cellKey] = nil
                versions[cellKey] = nil
                rendered[cellKey] = nil
            else
                touch(cellKey)
            end

            return item
        end
    end

    located[traceKey] = nil
    return nil
end

--- Reads a trace without removing it. Server-side callers only: what comes back
--- carries the owner.
function Grid.peek(traceKey)
    local cellKey = located[traceKey]
    if not cellKey then return nil end

    local cell = cells[cellKey]
    if not cell then return nil end

    for index = 1, #cell do
        if cell[index].key == traceKey then return cell[index] end
    end

    return nil
end

--- Reveals the latent traces a tool works on, within a radius (8.4).
---
--- The position is the officer's, read by the caller from the server's copy of
--- it. Revealing does not tell anybody what the trace is until the push goes
--- out on the next tick, and it never tells them whose it is.
---
--- @param x number
--- @param y number
--- @param z number
--- @param radius number
--- @param tool string one of `service.TOOLS`
--- @return number how many traces became visible
function Grid.reveal(x, y, z, radius, tool)
    local found = 0
    local limit = radius * radius
    local around = service.cellsAround(x, y, radius, config.cellSize)

    for index = 1, #around do
        local cell = cells[around[index]]

        if cell then
            local changed = false

            for itemIndex = 1, #cell do
                local item = cell[itemIndex]

                if item.latent and not item.revealed and service.revealedBy(tool, item.type) then
                    local dx, dy, dz = item.x - x, item.y - y, item.z - z

                    if (dx * dx + dy * dy + dz * dz) <= limit then
                        item.revealed = true
                        found = found + 1
                        changed = true
                    end
                end
            end

            if changed then touch(around[index]) end
        end
    end

    return found
end

--- Marks a trace as cleaned rather than removing it (8.10).
---
--- Cleaning blood leaves blood: luminol still finds it, with a lower yield,
--- which `evidence.qualityAfter` applies at collection through `cleaned`. What
--- cleaning changes is what the eye can see, so the trace becomes latent
--- whatever it was before -- a scrubbed pool is invisible until somebody puts
--- luminol on it. A cleaned scene is a worse scene, never an innocent one.
---
--- @return boolean whether anything was cleaned
function Grid.clean(traceKey)
    local item = Grid.peek(traceKey)
    if not item then return false end

    item.cleaned = true
    item.latent = true
    item.revealed = false

    touch(located[traceKey])

    return true
end

-- -----------------------------------------------------------------------------
-- Decay (8.1.4) -- on a timer, never on read
-- -----------------------------------------------------------------------------

--- Sweeps out everything that has aged out of the world.
---
--- Walks the whole grid, which is why it runs every half minute rather than on
--- every read: a read happens once per client per second and would pay for this
--- 200 times over.
---
--- @return number how many traces were removed
function Grid.sweep()
    local now = os.time()
    local removed = 0

    for cellKey, cell in pairs(cells) do
        local changed = false

        for index = #cell, 1, -1 do
            if service.decayed(cell[index], now, config) then
                located[cell[index].key] = nil
                table.remove(cell, index)
                removed = removed + 1
                changed = true
            end
        end

        if #cell == 0 then
            cells[cellKey] = nil
            versions[cellKey] = nil
            rendered[cellKey] = nil
        elseif changed then
            touch(cellKey)
        end
    end

    itemCount = itemCount - removed
    stats.evicted = stats.evicted + removed

    return removed
end

-- -----------------------------------------------------------------------------
-- Streaming (8.1.6, 12.1)
-- -----------------------------------------------------------------------------

--- The two render lists for a cell, built once per version.
---
--- `plain` is what anybody standing there may see: the traces that are visible
--- without a tool. `privileged` is that list plus the latent traces somebody has
--- already revealed, which only a session cleared to use forensic tools is told
--- about -- a suspect must not learn which of their prints the powder found.
local function renderLists(cellKey)
    local cached = rendered[cellKey]
    local version = versions[cellKey] or 0

    if cached and cached.version == version then return cached end

    local cell = cells[cellKey] or {}
    local plain, privileged = {}, {}

    for index = 1, #cell do
        local item = cell[index]

        if not item.latent then
            local data = evidence.renderData(item)
            plain[#plain + 1] = data
            privileged[#privileged + 1] = data
        elseif item.revealed then
            privileged[#privileged + 1] = evidence.renderData(item)
        end
    end

    cached = { version = version, plain = plain, privileged = privileged }
    rendered[cellKey] = cached

    return cached
end

--- May this player be told about revealed latent traces?
---
--- The same permission check a read would go through (invariant 4), against the
--- session the server holds. A player with no FredPD session -- every criminal
--- in the city -- still sees casings and blood, because 8.10 is built on their
--- being able to walk back and pick them up.
local function isPrivileged(src)
    local session = FredPD.Core.session.all()[src]
    if not session then return false end

    return FredPD.Core.perms.satisfies(session.permissions, 'forensics.tools.use')
end

--- Sends one player everything that changed in the cells they are standing in.
---
--- One message, carrying every changed cell. Per cell that is at most one update
--- per second, which is the budget (12.1); per client it is at most one message,
--- which is better than the budget and costs less.
local function pushTo(src)
    if not src then return end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end

    local position = GetEntityCoords(ped)
    local around = service.cellsAround(position.x, position.y, config.streamRange, config.cellSize)

    local subscription = subscriptions[src]

    if not subscription then
        subscription = { version = {}, any = {}, privileged = false }
        subscriptions[src] = subscription
    end

    local privileged = isPrivileged(src)

    -- A permission change moves what this player may be shown without moving
    -- any cell's version, so the cells they hold are resent once.
    if privileged ~= subscription.privileged then
        subscription.privileged = privileged
        subscription.version = {}
    end

    local changed, seen = {}, {}

    for index = 1, #around do
        local cellKey = around[index]
        seen[cellKey] = true

        local version = versions[cellKey] or 0
        local lastSeen = subscription.version[cellKey]

        if lastSeen ~= version then
            -- An empty cell they have never been sent is nothing to say.
            if lastSeen == nil and version == 0 then
                subscription.version[cellKey] = 0
            else
                local lists = renderLists(cellKey)
                local items = privileged and lists.privileged or lists.plain

                subscription.version[cellKey] = version

                if #items > 0 or subscription.any[cellKey] then
                    changed[#changed + 1] = { cell = cellKey, items = items }
                    subscription.any[cellKey] = #items > 0
                end
            end
        end
    end

    -- Cells they have walked out of. Sent as empty so the client drops what it
    -- drew, and only when it was given something to draw in the first place.
    for cellKey, hadItems in pairs(subscription.any) do
        if not seen[cellKey] then
            if hadItems then
                changed[#changed + 1] = { cell = cellKey, items = {} }
            end

            subscription.any[cellKey] = nil
        end
    end

    for cellKey in pairs(subscription.version) do
        if not seen[cellKey] then subscription.version[cellKey] = nil end
    end

    if #changed > 0 then
        FredPD.Core.push.toSession(src, 'fredpd:evidence:cells', { cells = FredPD.markArrays(changed) })
    end
end

--- Forgets a player. Called on drop, and on anything that invalidates what they
--- have been told.
function Grid.forget(src)
    subscriptions[src] = nil
end

--- The resolved forensics settings, so the routes read the same merged table
--- rather than merging the defaults with the config a second time and drifting
--- from it.
function Grid.settings()
    return config
end

--- Totals for the admin health screen (12.3). No trace, no player, no owner.
function Grid.stats()
    local cellCount = 0
    for _ in pairs(cells) do cellCount = cellCount + 1 end

    return {
        items = itemCount,
        cells = cellCount,
        placed = stats.placed,
        merged = stats.merged,
        evicted = stats.evicted,
        refused = stats.refused,
        collected = stats.collected,
    }
end

-- -----------------------------------------------------------------------------
-- Timers
-- -----------------------------------------------------------------------------

--- The streaming loop.
---
--- One pass per second over the connected players, and the early-out is first:
--- with nothing in the grid and nothing outstanding to retract, the whole pass
--- is a table lookup. An idle server pays almost nothing for forensics, which is
--- what the 200-player budget in 12.1 is measured against.
CreateThread(function()
    local interval = math.max(math.floor((config.pushIntervalSeconds or 1) * 1000), 1000)

    while true do
        Wait(interval)

        if next(cells) ~= nil or next(subscriptions) ~= nil then
            local players = GetPlayers()

            for index = 1, #players do
                pushTo(tonumber(players[index]))
            end
        end
    end
end)

--- The decay sweep (12.2). Separate from the streaming loop and much slower,
--- because it walks the world rather than the players.
CreateThread(function()
    local interval = math.max(math.floor((config.evictIntervalSeconds or 30) * 1000), 5000)

    while true do
        Wait(interval)

        if next(cells) ~= nil then Grid.sweep() end
    end
end)

AddEventHandler('playerDropped', function()
    Grid.forget(source)
end)

FredPD.Forensics.grid = Grid
