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
---     one hertz and sends one message per client carrying every cell whose
---     contents *as that client may see them* changed since their last message.
---     A change only an officer with tools may be told about is not a change to
---     anybody else, and sending it to them anyway would be an oracle (8.11).
---     Pushing per item would blow the budget with a single magazine.
---
--- Decay is swept on a timer, not on read. A read happens once per client per
--- second; the sweep happens once every half minute for the whole world.

FredPD = FredPD or {}
FredPD.Forensics = FredPD.Forensics or {}

local Grid = {}

local service = FredPD.Modules.forensics

--- The one way out of this module (8.11), resolved per call rather than at load.
---
--- Binding `FredPD.Modules.evidence` to a local at load would make this file
--- care what order the manifest lists two modules in -- and the manifest lists
--- the evidence service *after* this file today, so the local captures nil and
--- the first push to a client standing near a casing dies with "attempt to index
--- a nil value", inside the streaming thread, where nothing surfaces it. One
--- table lookup on a path that is already building a table is the cheaper
--- mistake, and it does not break again when somebody reorders the manifest.
local function renderData(item)
    return FredPD.Modules.evidence.renderData(item)
end

--- Resolved once at boot from `config/server.lua`, falling back to the
--- documented defaults in `service.lua` when a server has not configured
--- forensics at all.
local config = service.settings(FredPD.Config.server and FredPD.Config.server.forensics)

--- cellKey -> list of items. The shape `service.placeIn` expects, and the only
--- table that holds a trace.
local cells = {}

--- cellKey -> the stamp its contents were last changed at, or nil for a cell
--- with nothing in it.
---
--- This is the *contents* stamp and no client is ever compared against it: it
--- says that something in the cell moved, which is not the same question as
--- whether what a given client may be shown moved. The stamps a client is
--- compared against are the two in `rendered` below, one per visibility tier
--- (8.11). This one exists to invalidate those.
local versions = {}

--- One counter for the whole grid, never reset, handed out by `nextStamp`.
---
--- It has to be global rather than per cell, and the reason is a bug that only
--- shows as "evidence sometimes stops updating". A per-cell counter restarts at
--- 1 when the cell empties and its entry goes with it, so this sequence, all
--- inside one push interval, leaves a client drawing a trace that no longer
--- exists and blind to the one that replaced it:
---
---   1. the cell holds one casing at version 1; the client is sent version 1;
---   2. the casing is collected -- the cell dies, and the counter with it;
---   3. another casing lands in the same cell -- (nil or 0) + 1 is 1 again;
---   4. the push compares 1 against 1, finds no change, and sends nothing.
---
--- A stamp that only ever goes up cannot collide with one a client has already
--- been sent, so step 4 becomes a resend. Nothing is kept for dead cells: the
--- entry is still dropped when the cell empties, and nil is read as 0, which no
--- live cell can ever be.
---
--- The same counter hands out the two per-tier stamps in `rendered`, so a stamp
--- of any kind that a client has been sent can never come round again.
local revision = 0

--- The next number no client has ever been sent.
local function nextStamp()
    revision = revision + 1

    return revision
end

--- traceKey -> cellKey, so claiming a trace does not scan the world.
local located = {}

--- cellKey -> { version, plain, privileged, plainVersion, privilegedVersion }:
--- the render lists for a cell, rebuilt when its contents stamp moves.
---
--- Two lists rather than one because a revealed latent trace is visible to an
--- officer with tools and to nobody else, and rebuilding per client per second
--- at 200 players is exactly the cost spec 12.1 budgets against.
---
--- Two *stamps* rather than one for a reason that is not performance at all. A
--- single stamp per cell is an oracle (8.11): powdering a door handle changes
--- only the privileged list, and a client with no clearance whose plain list is
--- byte-for-byte what it already holds would still be re-sent the cell -- a
--- message that tells a criminal standing in the street that latent evidence has
--- just been created, or that an officer next to them has just revealed some.
--- So each list carries the stamp of the last time *that list* actually changed,
--- and `Grid.push` compares a client against the stamp for its own tier.
---
--- The comparison that decides whether a list changed happens here, once per
--- cell per change -- never per client -- which is what keeps it inside the
--- budget: the work of a revealed print is one list rebuild and one walk of a
--- list of keys, whether nobody or fifty people are standing in the cell.
---
--- The entry survives `touch` on purpose. It is the only copy of what the lists
--- looked like before the change, and without it there is nothing to compare the
--- rebuilt lists against. It is dropped with the cell, so the table is still the
--- size of the evidence actually in the world.
local rendered = {}

--- src -> { version = {}, any = {}, privileged = boolean }
---
--- What each connected player has been told, and *only* the players who have
--- been told something. `version` is the stamp last sent per cell -- the stamp
--- of the tier they were on when it was sent, never the cell's contents stamp --
--- and `any` the set of cells they were given something to draw in, which is
--- what decides whether leaving a cell needs a message at all.
---
--- `privileged` is what their tier was at that point, so a player who gains or
--- loses `forensics.tools.use` is resent what they hold rather than being
--- compared against stamps from the other tier.
---
--- A player with nothing drawn and nothing outstanding has no entry here at all,
--- and one that runs empty is dropped again. That is not tidiness: the streaming
--- loop's early-out below is `next(cells) or next(subscriptions)`, and an entry
--- per connected player would make it always true and the claim in 12.1 false.
local subscriptions = {}

--- How many traces are in the grid, kept as a running count so the global cap
--- does not cost a walk of the world to check.
local itemCount = 0

--- Counters for the admin health screen (spec 12.3). Never per-player, never
--- per-trace: totals only, so nothing here can become a record.
---
--- `evicted` is what the grid threw away to stay inside its caps or its decay
--- times, `collected` what an officer turned into evidence, and `destroyed` what
--- a player wiped away or picked up under 8.10. Three counters rather than one
--- because a server whose evidence is disappearing needs to know which of the
--- three is doing it, and they mean completely different things.
local stats = { placed = 0, merged = 0, evicted = 0, refused = 0, collected = 0, destroyed = 0 }

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

--- Marks a cell changed, so its render lists are rebuilt within the second.
---
--- Not "so every subscriber is re-sent it": whether a subscriber hears anything
--- is decided in `renderLists`, by whether the list for their tier came out
--- different (8.11). A change only an officer with tools may see moves this
--- stamp and reaches nobody else.
---
--- Tolerates a nil key rather than trusting its callers. `versions[nil] = n` is
--- not a no-op in Lua, it is a hard error inside whatever was running -- a route
--- handler, or worse the streaming thread, which would then stop pushing for
--- everybody. Every caller here passes a key it has just read out of `cells` or
--- out of `cellsAround`, but a stale `located` entry used to be able to reach
--- this with nil (`Grid.clean`), and a crash is a disproportionate answer to a
--- trace that is already gone.
local function touch(cellKey)
    if cellKey == nil then return end

    -- The cached lists are left where they are: `renderLists` sees that the
    -- stamp on them is not this one, rebuilds, and uses the old lists to work
    -- out which of the two tiers actually moved.
    versions[cellKey] = nextStamp()
end

--- Drops a cell that has just lost its last trace.
---
--- The version entry and the cached lists go with it, which is safe only because
--- `nextStamp` hands out a number that never repeats: a rebuilt cell gets stamps
--- no client has been sent, in both tiers, so nothing is kept for a cell nobody
--- is standing in and the tables stay the size of the evidence actually in the
--- world.
local function dropCell(cellKey)
    cells[cellKey] = nil
    versions[cellKey] = nil
    rendered[cellKey] = nil
end

--- Finds a trace and the cell it is actually in.
---
--- `located` is a lookup, not the truth: the truth is the cell list. A key whose
--- lookup points at a cell that no longer holds it -- the item was evicted by a
--- cap, or the cell was rebuilt around it -- answers nil here and the stale
--- entry is cleared on the way out, so the next call does not walk a cell again
--- for a trace that is not in it.
---
--- @return table|nil item
--- @return string|nil cellKey
local function locate(traceKey)
    local cellKey = located[traceKey]
    if not cellKey then return nil, nil end

    local cell = cells[cellKey]

    if cell then
        for index = 1, #cell do
            if cell[index].key == traceKey then return cell[index], cellKey end
        end
    end

    located[traceKey] = nil

    return nil, nil
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

    local stored, merged, cellKey, evicted = service.placeIn(cells, item, config)

    -- A full cell gives up its oldest trace to make room (12.2). That is a swap,
    -- not a second arrival: counting the new one without counting the old one
    -- out leaves `itemCount` above the truth until the global cap starts
    -- refusing traces the grid has room for, and leaves the evicted key in
    -- `located` pointing at a cell it is no longer in -- a lookup table that
    -- only ever grows, and a `Grid.take` that walks a cell for nothing.
    if evicted then
        located[evicted.key] = nil
        itemCount = itemCount - 1
        stats.evicted = stats.evicted + 1
    end

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

--- Takes the trace a key names out of the world.
---
--- The shared half of `Grid.take` and `Grid.destroy`. Everything about the
--- removal is the same -- the lookup, the cell, the running count and what the
--- clients standing there are told -- and the only difference between an officer
--- bagging a casing and a criminal pocketing one is which counter moves (12.3).
--- That difference is the caller's, so it is not in here.
---
--- @param traceKey string
--- @return table|nil the removed trace, owner and all
local function removeKeyed(traceKey)
    local item, cellKey = locate(traceKey)
    if not item then return nil end

    local cell = cells[cellKey]

    for index = 1, #cell do
        if cell[index] == item then
            table.remove(cell, index)
            break
        end
    end

    located[traceKey] = nil
    itemCount = itemCount - 1

    if #cell == 0 then
        -- The last trace in the cell. Dropping it reads as a change to everyone
        -- subscribed -- they were told a stamp and the cell is back at nothing
        -- -- so the casing disappears from the world for them within the second.
        dropCell(cellKey)
    else
        touch(cellKey)
    end

    return item
end

--- Takes a trace out of the world because an officer is collecting it.
---
--- Removal is the collection: the trace stops existing here as the row is
--- written in `evidence.collect`, so two officers cannot collect the same
--- casing and a failed insert cannot leave half a collection behind.
---
--- @param traceKey string
--- @return table|nil the removed trace, owner and all
function Grid.take(traceKey)
    local item = removeKeyed(traceKey)
    if not item then return nil end

    stats.collected = stats.collected + 1

    return item
end

--- Takes a trace out of the world because somebody destroyed it (8.10).
---
--- The same removal as `Grid.take` and a different counter, and the difference
--- is the whole point. There is deliberately no audit row on the destruction
--- path -- there is no session and no `discordId` to attribute one to (ADR-013)
--- -- so `destroyed` on the health screen (12.3) is the only signal a server has
--- that its evidence is being carried away rather than collected. Counting a
--- criminal picking up thirty casings as thirty collections would put that
--- signal into the number that is supposed to contradict it.
---
--- Keyed, unlike `Grid.takeNear`: the player could see this trace and named it.
---
--- @param traceKey string
--- @return table|nil the removed trace, owner and all
function Grid.destroy(traceKey)
    local item = removeKeyed(traceKey)
    if not item then return nil end

    stats.destroyed = stats.destroyed + 1

    return item
end

--- Reads a trace without removing it. Server-side callers only: what comes back
--- carries the owner.
function Grid.peek(traceKey)
    return (locate(traceKey))
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
--- No counter moves here, and that is a decision rather than an omission. The
--- four totals in `stats` count traces *leaving* the grid and say which of the
--- four ways it happened; cleaning removes nothing, and the pool it marked is
--- still in the world to be collected at a quarter yield or swept when it ages
--- out. Counting it as destroyed would book the same trace twice, and the second
--- booking would land in the one number a server watching its evidence disappear
--- reads (12.3) -- so a scene somebody cleaned would look like a scene somebody
--- had emptied. A fifth counter for cleanings would be honest, but `Grid.stats`
--- is read by the admin health screen and widening its shape is a change to that
--- screen, not to this file.
---
--- @return boolean whether anything was cleaned
function Grid.clean(traceKey)
    -- The cell comes back with the item, rather than being looked up again in
    -- `located` afterwards: the lookup can be stale where the item is not, and
    -- `touch(nil)` on the stale case used to be an error thrown at whoever was
    -- scrubbing the floor.
    local item, cellKey = locate(traceKey)
    if not item then return false end

    item.cleaned = true
    item.latent = true
    item.revealed = false

    touch(cellKey)

    return true
end

-- -----------------------------------------------------------------------------
-- Destruction (8.10) -- the half of it that is blind
-- -----------------------------------------------------------------------------

--- Removes every trace of the named types within a radius.
---
--- Blind on purpose: the caller names a position and a set of types, never a
--- key. Both of the destruction methods in 8.10 that reach this are things a
--- player does to a *place* rather than to a trace they can see -- the whole
--- point of wiping a door handle is that the prints on it were invisible, and a
--- player picking casings up off the ground has no key for anything, because
--- render data is what carries keys and the casings may never have been in
--- their streaming range.
---
--- @param x number
--- @param y number
--- @param z number
--- @param radius number metres
--- @param types table a set, `{ print = true, glove_mark = true }`
--- @return number how many traces were removed
local function removeAround(x, y, z, radius, types)
    if type(types) ~= 'table' then return 0 end

    local removed = 0
    local limit = radius * radius
    -- `cellsAround` rather than a walk of the world: at the radius of a door
    -- handle this is one or four cells, and the cost does not depend on how much
    -- evidence exists elsewhere in the city (12.1).
    local around = service.cellsAround(x, y, radius, config.cellSize)

    for index = 1, #around do
        local cellKey = around[index]
        local cell = cells[cellKey]

        if cell then
            local changed = false

            -- Backwards, because `table.remove` shifts everything after it.
            for itemIndex = #cell, 1, -1 do
                local item = cell[itemIndex]

                if types[item.type] then
                    local dx, dy, dz = item.x - x, item.y - y, item.z - z

                    if (dx * dx + dy * dy + dz * dz) <= limit then
                        located[item.key] = nil
                        table.remove(cell, itemIndex)
                        removed = removed + 1
                        changed = true
                    end
                end
            end

            if #cell == 0 then
                dropCell(cellKey)
            elseif changed then
                touch(cellKey)
            end
        end
    end

    itemCount = itemCount - removed
    stats.destroyed = stats.destroyed + removed

    return removed
end

--- The wiping kit (8.2, 8.10): the trace is gone, not hidden.
---
--- This is the distinction that will be got wrong by whoever reads this next, so
--- it is worth stating twice. `Grid.clean` above is for **blood**, and it must
--- never delete: 8.10 says in as many words that cleaning leaves something
--- luminol still finds, at a reduced DNA yield, and a cleaning chemical that
--- removed the row would make the one forensic tool in the spec with a named
--- counter-mechanic useless. `wipeAround` is for **latent fingerprints and glove
--- marks**, the two rows where 8.2's "Removed or reduced by" column names wiping
--- and where there is no residue mechanic at all -- a wiped handle has nothing
--- left on it for powder or anything else to find, so the row goes.
---
--- Tool marks are *not* one of them, whatever this comment used to say: 8.2
--- removes tool marks and broken glass by **repair**, which is a different
--- action on a different object and is not modelled here. A wiping kit that
--- deleted them would let a player rub a cloth over a jemmied door and take the
--- comparison evidence with it.
---
--- `blood` therefore must never appear in `types` either. The grid does not
--- filter anything out, because a silent filter would answer a count that did
--- not match what happened; the route that owns the wiping kit passes the
--- surface types it is allowed to remove and nothing else.
function Grid.wipeAround(x, y, z, radius, types)
    return removeAround(x, y, z, radius, types)
end

--- Picking casings and magazines up off the ground (8.10).
---
--- Same removal, different fiction and a different route: the player is bending
--- down where they stood, not wiping a surface, and what they may pick up is
--- limited to the visible physical types by the caller. Two names rather than
--- one flag because the two are audited and rate-limited separately, and because
--- a call site reading `wipeAround` while collecting brass would be a lie.
function Grid.takeNear(x, y, z, radius, types)
    return removeAround(x, y, z, radius, types)
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
            dropCell(cellKey)
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

--- Do two render lists say exactly the same thing?
---
--- Render data is fixed for the life of a trace: the key, the type, the position
--- and the model are written once in `Grid.place` and never written again, and
--- the fields a merge does move -- `count`, `quality`, `mergedAt` -- are not in
--- it. So two lists naming the same keys in the same order are the same message,
--- and comparing the keys is the whole comparison. The order is stable because
--- the lists are built by walking the cell, and nothing reorders a cell.
---
--- @param before table|nil
--- @param after table
local function sameList(before, after)
    if before == nil or #before ~= #after then return false end

    for index = 1, #after do
        if before[index].key ~= after[index].key then return false end
    end

    return true
end

--- The two render lists for a cell, with the stamp each of them last changed at.
---
--- `plain` is what anybody standing there may see: the traces that are visible
--- without a tool. `privileged` is that list plus the latent traces somebody has
--- already revealed, which only a session cleared to use forensic tools is told
--- about -- a suspect must not learn which of their prints the powder found.
---
--- A tier's stamp moves only when that tier's list actually came out different
--- (8.11). Powdering a handle therefore moves `privilegedVersion` and leaves
--- `plainVersion` exactly where it was, and the player with no clearance
--- standing in the same cell is sent nothing at all -- where a single stamp per
--- cell would have sent them a copy of the list they already hold and told them,
--- by the timing of it alone, that the scene was being processed.
---
--- The cost of that: one rebuild and one walk of a list of keys per cell per
--- change, which is where it was before, and nothing per client. The alternative
--- -- comparing what each subscriber last received against a freshly built list
--- -- is the same comparison multiplied by everybody standing in the cell, every
--- second, which is the shape 12.1 budgets against at 200 players.
local function renderLists(cellKey)
    local previous = rendered[cellKey]
    local version = versions[cellKey] or 0

    if previous and previous.version == version then return previous end

    local cell = cells[cellKey] or {}
    local plain, privileged = {}, {}

    for index = 1, #cell do
        local item = cell[index]

        if not item.latent then
            local data = renderData(item)
            plain[#plain + 1] = data
            privileged[#privileged + 1] = data
        elseif item.revealed then
            privileged[#privileged + 1] = renderData(item)
        end
    end

    local plainVersion, privilegedVersion

    if previous and sameList(previous.plain, plain) then
        plainVersion = previous.plainVersion
    else
        plainVersion = nextStamp()
    end

    if previous and sameList(previous.privileged, privileged) then
        privilegedVersion = previous.privilegedVersion
    else
        privilegedVersion = nextStamp()
    end

    local lists = {
        version = version,
        plain = plain,
        privileged = privileged,
        plainVersion = plainVersion,
        privilegedVersion = privilegedVersion,
    }

    rendered[cellKey] = lists

    return lists
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

--- Is there anything at all in the cells this player is standing in?
---
--- The cheap half of the question `Grid.push` has to answer for a player who is
--- nowhere near any evidence, which at 200 players is nearly all of them. At
--- most 49 hash lookups against a table that is usually a handful of entries,
--- and no allocation: the answer for a player driving across an empty half of
--- the map is "no" without a render list, a subscription or a message.
local function anythingAround(around)
    for index = 1, #around do
        if versions[around[index]] ~= nil then return true end
    end

    return false
end

--- Sends one player everything that changed in the cells they are standing in.
---
--- One message, carrying every changed cell. Per cell that is at most one update
--- per second, which is the budget (12.1); per client it is at most one message,
--- which is better than the budget and costs less.
---
--- A player is a *subscriber* only while they are drawing something or owe a
--- retraction for something they were drawing. Standing in an empty part of the
--- city records nothing, and the last retraction removes them again. Without
--- that, `subscriptions` filled up with every player who had ever taken a step
--- and the streaming loop's early-out below could never fire again -- the idle
--- cost it claims in 12.1 was being paid by every server that had had one casing
--- dropped on it since the last restart.
---
--- The cost at the 200-player budget, measured as operations rather than guessed
--- at: an empty grid is two `next` calls for the whole server, per second. A grid
--- with evidence in it somewhere and the players elsewhere is, per player per
--- second, one ped lookup, one coordinate read, one `cellsAround` (49 keys at the
--- default 96 m range over 32 m cells) and 49 hash lookups -- and then it stops.
--- Only players actually standing near evidence build render lists, and those are
--- cached per cell per stamp, so two officers over one casing build one list.
---
--- @param src number
function Grid.push(src)
    if not src then return end

    local ped = GetPlayerPed(src)
    if ped == 0 then return end

    local position = GetEntityCoords(ped)
    local around = service.cellsAround(position.x, position.y, config.streamRange, config.cellSize)

    local subscription = subscriptions[src]

    -- Nothing here, and nothing they were told about anywhere: not a subscriber,
    -- and this is where that stays true.
    if not subscription and not anythingAround(around) then return end

    if not subscription then
        subscription = { version = {}, any = {}, privileged = false }
        subscriptions[src] = subscription
    end

    local privileged = isPrivileged(src)

    -- A permission change moves what this player may be shown without moving
    -- any cell's stamp, so the cells they hold are resent once.
    if privileged ~= subscription.privileged then
        subscription.privileged = privileged
        subscription.version = {}
    end

    local changed, seen = {}, {}

    for index = 1, #around do
        local cellKey = around[index]
        seen[cellKey] = true

        -- nil rather than 0: a cell with no entry has nothing in it, and a live
        -- cell always has a stamp, so the two can never be confused.
        local version = versions[cellKey]
        local drawn = subscription.any[cellKey]

        if version == nil then
            -- Emptied while they stood in it. They keep drawing what was there
            -- until they are told otherwise, so the retraction is sent here and
            -- not only when they walk away.
            if drawn then
                changed[#changed + 1] = { cell = cellKey, items = {} }
                subscription.any[cellKey] = nil
            end

            subscription.version[cellKey] = nil
        else
            -- The stamp this client is held against is the one for its own tier,
            -- never the cell's contents stamp (8.11). `renderLists` is a cached
            -- lookup and a compare whenever the cell has not changed, which is
            -- almost always, and it is only reached for cells that hold
            -- something -- at most a handful of the 49 in range.
            local lists = renderLists(cellKey)
            local items, tier

            if privileged then
                items, tier = lists.privileged, lists.privilegedVersion
            else
                items, tier = lists.plain, lists.plainVersion
            end

            if subscription.version[cellKey] ~= tier then
                if #items > 0 then
                    changed[#changed + 1] = { cell = cellKey, items = items }
                    subscription.version[cellKey] = tier
                    subscription.any[cellKey] = true
                elseif drawn then
                    changed[#changed + 1] = { cell = cellKey, items = {} }
                    subscription.version[cellKey] = nil
                    subscription.any[cellKey] = nil
                else
                    -- A cell holding only latent traces nobody has revealed, to
                    -- a player who may not be told about them either way.
                    -- Remembering the stamp would make them a subscriber for a
                    -- cell they have never been sent anything about; the
                    -- re-check costs one cached table lookup a second.
                    subscription.version[cellKey] = nil
                end
            end
        end
    end

    -- Cells they have walked out of. Sent as empty so the client drops what it
    -- drew; `any` only ever holds cells they were given something to draw in.
    for cellKey in pairs(subscription.any) do
        if not seen[cellKey] then
            changed[#changed + 1] = { cell = cellKey, items = {} }
            subscription.any[cellKey] = nil
        end
    end

    for cellKey in pairs(subscription.version) do
        if not seen[cellKey] then subscription.version[cellKey] = nil end
    end

    if next(subscription.version) == nil and next(subscription.any) == nil then
        subscriptions[src] = nil
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

    -- How many players are being told anything, which is the number the idle
    -- cost in 12.1 turns on: it should be the officers and criminals actually
    -- standing over evidence, not "everyone who has connected since the
    -- restart". A health screen showing the latter is showing the bug.
    local subscriberCount = 0
    for _ in pairs(subscriptions) do subscriberCount = subscriberCount + 1 end

    return {
        items = itemCount,
        cells = cellCount,
        subscribers = subscriberCount,
        placed = stats.placed,
        merged = stats.merged,
        evicted = stats.evicted,
        refused = stats.refused,
        collected = stats.collected,
        destroyed = stats.destroyed,
    }
end

-- -----------------------------------------------------------------------------
-- Timers
-- -----------------------------------------------------------------------------

--- The streaming loop.
---
--- One pass per second over the connected players, and the early-out is first:
--- with nothing in the grid and nothing outstanding to retract, the whole pass
--- is two table lookups. An idle server pays almost nothing for forensics, which
--- is what the 200-player budget in 12.1 is measured against -- and the claim is
--- only true because `Grid.push` refuses to make a subscriber out of a player it
--- has nothing to say to, and drops one whose last cell has been retracted.
CreateThread(function()
    local interval = math.max(math.floor((config.pushIntervalSeconds or 1) * 1000), 1000)

    while true do
        Wait(interval)

        if next(cells) ~= nil or next(subscriptions) ~= nil then
            local players = GetPlayers()

            for index = 1, #players do
                Grid.push(tonumber(players[index]))
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
