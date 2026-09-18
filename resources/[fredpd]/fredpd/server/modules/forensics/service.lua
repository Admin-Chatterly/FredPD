--- The uncollected-trace grid, as pure logic (spec 8.3.5, 8.1.6, 12.1).
---
--- Everything in this file is arithmetic over plain tables: no natives, no
--- database, no clock of its own. That is what lets busted prove the three
--- rules the grid actually has to get right, none of which can be checked by
--- looking at a running server:
---
---   * a world position belongs to exactly one cell, including on a boundary;
---   * a second identical trace folds into the first instead of appending
---     (8.3.5) -- without which emptying a magazine leaves thirty rows and the
---     cell becomes a performance problem rather than an investigation;
---   * a shot leaves a casing at a fixed, documented rate (8.2, spec 12.2),
---     decided by a counter rather than by chance.
---
--- Sampling is deterministic on purpose. `math.random` would make the rate
--- untestable, and the test harness bans it; more importantly a rate that is
--- argued about in a bug report should be a rate somebody can read off a table.
---
--- Nothing here knows who left a trace. `ownerKey` hashes nothing and reveals
--- nothing -- it is a comparison key for merging, and it never leaves the
--- server, because nothing in this file ever reaches a client. What a client
--- receives is built by `FredPD.Modules.evidence.renderData` and by nothing
--- else (8.11).

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Forensics = {}

-- -----------------------------------------------------------------------------
-- Configuration
-- -----------------------------------------------------------------------------

--- Working defaults for the whole grid.
---
--- A server overrides any of it in `config/server.lua` under `forensics`; the
--- defaults are here rather than there because they are the values the tests
--- assert against, and a spec that read the server config would be testing the
--- installation instead of the code.
---
--- The numbers that matter to spec 12.1 are `cellSize`, `streamRange` and
--- `pushIntervalSeconds`: together they decide how much a client is told and
--- how often. `maxPerCell` is the cap 12.2 asks for -- the grid refuses to grow
--- without bound even if the generation pipeline is wrong.
Forensics.defaults = {
    --- Metres per grid cell, on both axes. A cell is the unit of subscription
    --- and of the per-second push budget, so bigger cells mean fewer, larger
    --- updates and smaller cells mean more, smaller ones.
    cellSize = 32.0,

    --- How far a client is told about evidence, in metres. Below GTA's entity
    --- streaming distance deliberately: a player is told about traces they
    --- could walk up to, not about everything their machine has loaded (8.11).
    streamRange = 96.0,

    --- The push budget from spec 12.1: at most one update per second per cell
    --- per client. The grid coalesces everything that happened in the interval
    --- into a single message rather than pushing per item.
    ---
    --- This number *is* the budget and there is no second rule enforcing it:
    --- the streaming thread in `grid.lua` waits this long between passes, and
    --- that thread is the only caller of `Grid.push`. Anything that wants to
    --- push a client outside the loop has to answer 12.1 for itself.
    pushIntervalSeconds = 1,

    --- How often decayed traces are swept out of the grid, in seconds. On a
    --- timer rather than on read (12.2): a read happens once per client per
    --- second and would pay for the sweep every time.
    evictIntervalSeconds = 30,

    --- Two traces closer together than this, of the same type and the same
    --- owner, are one trace (8.3.5).
    mergeRadius = 0.5,

    --- The cap per cell: how much evidence one grid cell may hold at once.
    ---
    --- A memory bound and nothing else (12.2). It removes nothing: a cell that
    --- is full refuses the arriving trace rather than clearing a space in it,
    --- so no arrival can ever cost anybody a row (`placeIn`).
    maxPerCell = 64,

    --- The cap per owner per cell: how much of one cell one source of traces --
    --- a character, or a weapon's serial -- may hold at once.
    ---
    --- This is the cap that actually bounds anybody, and the reason it exists is
    --- 8.10 rather than 12.2. `forensics.observe` is public (ADR-013): no
    --- session, no permission, no item and no progress bar stand in front of it,
    --- so a client can loop it, and with a per-cell cap alone every call past the
    --- cap threw away the oldest trace in the cell whoever had left it. That made
    --- an accomplice walking a slow circle a faster, cheaper and quieter way of
    --- destroying a scene than the wiping kit 8.10 charges time and items for.
    ---
    --- "Source" is the acting player (`sourceKeyOf`), not the owner. The owner is
    --- deliberately not one value per player -- a casing carries a weapon serial
    --- and no identifier (8.3.4) -- so a share counted by owner would have given
    --- one client three shares of every cell and a fourth per further weapon.
    ---
    --- A quarter of the cell, so filling one needs four separate sources and no
    --- single player can deny the rest of the cell to anybody. Well above what a
    --- scene produces once merging has folded what is within half a metre: six
    --- casings from a magazine (8.2 at the default sampling), a pool of blood,
    --- the prints on the doors of a car.
    maxPerOwnerPerCell = 16,

    --- The cap across the whole world. Per-cell caps bound one street corner;
    --- this bounds a player driving across the map generating as they go. Past
    --- it the grid sweeps early and then refuses to grow (12.2).
    maxItems = 5000,

    --- One casing per this many shots (8.2, 12.2). Emptying a thirty-round
    --- magazine leaves six casings at the default, not thirty.
    casingEvery = 5,

    --- How long a trace lies in the world before it is gone entirely, per type,
    --- in seconds. This is not quality decay -- `evidence.qualityAfter` does
    --- that at collection time (8.1.4) -- it is the point past which there is
    --- nothing left to collect at all.
    defaultLifetimeSeconds = 2 * 3600,

    lifetimeSeconds = {
        -- Physical objects lie where they fell until somebody picks them up.
        casing = 6 * 3600,
        magazine = 6 * 3600,
        bullet = 12 * 3600,
        -- Latent traces are fragile: they are the ones a scene has to be worked
        -- quickly to recover.
        print = 3 * 3600,
        glove_mark = 3 * 3600,
        dna_touch = 90 * 60,
        blood = 8 * 3600,
        drug_residue = 2 * 3600,
        footwear = 45 * 60,
        tool_mark = 12 * 3600,
    },

    --- Quality lost per hour, per type, handed to `evidence.qualityAfter` when
    --- the trace is finally collected (8.1.4).
    decayPerHour = {
        print = 4,
        glove_mark = 4,
        dna_touch = 8,
        blood = 2,
        casing = 0.5,
        bullet = 0.5,
        magazine = 1,
        drug_residue = 6,
        footwear = 10,
        tool_mark = 0.5,
    },

    --- How close an officer has to be to collect a trace, in metres. Checked
    --- against the server's copy of their position, never against the call.
    collectRange = 3.0,

    --- How far powder, luminol and the forensic light reach from where the
    --- officer is standing, in metres (8.4).
    processRadius = 4.0,

    --- The prop a type is drawn as, by type. Empty by default and deliberately
    --- so: a model name is a rendering decision, and a server that has not
    --- chosen one gets a marker drawn by `fredpd_forensics` instead of a prop
    --- this file guessed at. The value only ever travels as part of render data
    --- (8.1.6).
    models = {},

    --- How close a reported entity has to be to the player reporting it (8.3.2).
    --- A door handle they are nowhere near is not an observation, it is a claim.
    entityRange = 6.0,

    --- How far the wiping kit reaches from the surface it is used on, in metres
    --- (8.2, 8.10).
    ---
    --- Its own setting, and much smaller than `entityRange`, because the two
    --- numbers answer different questions. `entityRange` is how far away the
    --- entity being wiped is allowed to be from the player; wiping at that same
    --- radius around that entity destroys everything within twice it -- twelve
    --- metres at the defaults, four times the three an officer has to be inside
    --- to collect (`collectRange`). A door handle is an arm's length from the
    --- hand on the cloth, so the kit reaches an arm's length.
    wipeRadius = 1.5,

    --- What each destruction action in 8.10 costs, as ox_inventory item names.
    ---
    --- `wipe` and `weapon` are the same kit: 8.2 names one wiping kit, for
    --- surfaces and for weapons. Washing at a sink and picking casings up off the
    --- ground have no entry and cost nothing -- a sink is a sink and a hand is a
    --- hand, and charging for them would make walking back for your own brass
    --- something only a prepared player could do.
    ---
    --- Which item names an ox_inventory actually has is a property of the server,
    --- so these are documented defaults rather than truth: a server that spells
    --- its kit differently sets `forensics.destroyItems` in `config/server.lua`,
    --- and `settings` merges it a key at a time like every other table here, so
    --- renaming one item does not mean restating the other two.
    destroyItems = {
        wipe = 'wiping_kit',
        weapon = 'wiping_kit',
        clean = 'cleaning_chemicals',
    },

    --- Damage above which a hit leaves blood (8.2).
    bloodDamageThreshold = 12,

    --- Gunshot residue: how much of it a shooter loses per minute (8.2).
    ---
    --- GSR is the one trace in 8.2 that is not left anywhere in the world -- it
    --- is on the shooter's hands and clothes and it travels with them -- so it
    --- is not in the grid and deliberately not in `lifetimeSeconds` either. It
    --- decays on a level rather than by disappearing at a cliff edge, because
    --- what the GSR kit reads is how much is there: a shooter swabbed an hour
    --- after the fact is a weaker result than one swabbed at the scene, not an
    --- identical one.
    ---
    --- Half a point a minute takes a fresh 100 to nothing in three hours and
    --- twenty minutes, which sits inside the four-to-six hours the kit is
    --- realistically any use over.
    gsrDecayPerMinute = 0.5,

    --- The point past which residue is simply gone, whatever the rate says.
    ---
    --- A ceiling rather than the mechanic: at the default rate the level reaches
    --- zero well before this. It exists so that a server which configures a very
    --- slow decay -- or zero -- cannot leave every player who has ever fired a
    --- weapon permanently swabbable, which would make "washing at sinks and
    --- showers" (8.10) the only way residue ever ended.
    gsrLifetimeSeconds = 4 * 3600,
}

--- Merges a server's overrides onto the defaults.
---
--- Two levels, because `lifetimeSeconds` and `decayPerHour` are tables of their
--- own and a server that wants to change how long a casing lies around should
--- not have to restate every other type to do it.
---
--- @param overrides table|nil
--- @return table a new table; the defaults are never mutated
function Forensics.settings(overrides)
    local merged = {}

    for key, value in pairs(Forensics.defaults) do
        if type(value) == 'table' then
            local copy = {}
            for innerKey, innerValue in pairs(value) do copy[innerKey] = innerValue end
            merged[key] = copy
        else
            merged[key] = value
        end
    end

    for key, value in pairs(overrides or {}) do
        if type(value) == 'table' and type(merged[key]) == 'table' then
            for innerKey, innerValue in pairs(value) do merged[key][innerKey] = innerValue end
        else
            merged[key] = value
        end
    end

    return merged
end

-- -----------------------------------------------------------------------------
-- Cells (12.2: a spatial grid for evidence)
-- -----------------------------------------------------------------------------

--- The cell a world position falls in.
---
--- `math.floor` on the division is the whole rule, and it is the reason a
--- position on a boundary belongs to exactly one cell: at x = 32 with a 32 m
--- cell the division is exactly 1, so the boundary is the *first* metre of the
--- higher cell and never the last of the lower one. Any rule works as long as
--- it is total and consistent; this one is both, and it holds for negative
--- coordinates too, where -32 is the first metre of cell -1.
---
--- Z is deliberately absent. A grid cell is a subscription unit for streaming,
--- and a player on the tenth floor is streaming the street below them.
---
--- @param x number
--- @param y number
--- @param size number|nil metres per cell; defaults to `defaults.cellSize`
--- @return string
function Forensics.cellKey(x, y, size)
    size = size or Forensics.defaults.cellSize

    return ('%d:%d'):format(math.floor(x / size), math.floor(y / size))
end

--- Every cell a client at this position is subscribed to.
---
--- The square that covers `range` in every direction, which is between nine and
--- sixteen cells at the default settings. A square rather than a circle because
--- the cell is the unit of the push budget (12.1): trimming the corners would
--- save a cell whose contents are usually empty and cost a distance check per
--- cell per client per second, which is the wrong trade at 200 players.
---
--- The order is stable -- x ascending, then y -- so a test can assert on the
--- whole list and a diff between two positions is readable.
---
--- @param x number
--- @param y number
--- @param range number metres
--- @param size number|nil
--- @return table list of cell keys
function Forensics.cellsAround(x, y, range, size)
    size = size or Forensics.defaults.cellSize
    range = range or Forensics.defaults.streamRange

    local minX = math.floor((x - range) / size)
    local maxX = math.floor((x + range) / size)
    local minY = math.floor((y - range) / size)
    local maxY = math.floor((y + range) / size)

    local keys = {}

    for cx = minX, maxX do
        for cy = minY, maxY do
            keys[#keys + 1] = ('%d:%d'):format(cx, cy)
        end
    end

    return keys
end

-- -----------------------------------------------------------------------------
-- Owners (8.3.4) -- hidden, and only ever compared
-- -----------------------------------------------------------------------------

--- The key two traces are compared on to decide whether they are one trace.
---
--- It contains the source's hidden identifier, so it is hidden truth in the
--- sense of 8.1: it stays in the grid, it is never part of render data, and
--- nothing derived from it is returned by a route. It exists because
--- `evidence.shouldMerge` needs a single value to compare and the owner is two
--- nullable fields.
---
--- A trace with no owner at all answers `'?'`, and `'?'` is one key rather than
--- one key each: two unattributed traces of the same type lying close together
--- compare equal, so `evidence.shouldMerge` folds them together and `placeIn`
--- counts them against one another's share of a cell. Nothing in the generation
--- pipeline can reach that today -- every rule in `routes.lua` answers nil when
--- it cannot name an identifier or a serial, and 8.3.4 says the owner is always
--- whoever left the trace -- so `'?'` exists to keep this total rather than to
--- describe anything the grid holds. A caller that starts creating unattributed
--- traces gets one merged pile per type per place, which is a bug made visible
--- rather than a bug hidden, but it is not a shape to build on.
---
--- @param owner table|nil { identifier, weaponSerial }
--- @return string
function Forensics.ownerKey(owner)
    if type(owner) ~= 'table' then return '?' end

    local identifier = type(owner.identifier) == 'string' and owner.identifier or ''
    local serial = type(owner.weaponSerial) == 'string' and owner.weaponSerial or ''

    if identifier == '' and serial == '' then return '?' end

    return identifier .. '|' .. serial
end

--- Which share of a cell a trace is counted against (8.3.5, 12.2).
---
--- The *generator*, not the owner. `ownerKey` answers "whose trace is this",
--- which is what merging needs and what a cap must not use: one player leaves
--- prints under their identifier, casings under a weapon serial with no
--- identifier at all, and magazines under both, so capping by owner would give
--- a single client three shares of every cell and a fourth per further weapon --
--- enough to hold a whole cell and refuse everybody else's evidence a place to
--- land. `Grid.place` stamps `sourceKey` from the server's own idea of who
--- called it, so those three collapse back into one.
---
--- Hidden truth in the sense of 8.1, like the owner beside it: it is on the
--- trace, on the server, and `Evidence.renderData` does not carry it.
---
--- @param item table
--- @return string
function Forensics.sourceKeyOf(item)
    if type(item) ~= 'table' then return '?' end

    return type(item.sourceKey) == 'string' and item.sourceKey
        or (type(item.ownerKey) == 'string' and item.ownerKey)
        or '?'
end

-- -----------------------------------------------------------------------------
-- Visibility (8.4)
-- -----------------------------------------------------------------------------

--- Types that are invisible until a tool is used on them (8.4).
---
--- The rest -- casings, magazines, bullets, a pool of blood -- can be seen
--- without anything, which is what makes 8.10 work: a criminal can walk back
--- and pick up their own casings.
local LATENT <const> = {
    print = true,
    glove_mark = true,
    dna_touch = true,
    drug_residue = true,
    footwear = true,
    tool_mark = true,
}

--- Is this type invisible until processed?
function Forensics.isLatent(type_)
    return LATENT[type_] == true
end

--- Which tool reveals which type (8.4).
---
--- Powder for the ridge detail somebody left on a surface, luminol for blood
--- including blood that has been cleaned (8.10), the forensic light for the
--- trace material neither of the other two shows.
local REVEALS <const> = {
    powder = { print = true, glove_mark = true, tool_mark = true },
    luminol = { blood = true },
    forensic_light = { dna_touch = true, drug_residue = true, footwear = true },
}

--- Does using `tool` find a trace of this type?
---
--- Only whether the tool works on the type, not whether this particular trace is
--- hidden -- the caller knows that, and it is not a property of the type. Blood
--- is the case that proves it: a fresh pool is visible to anybody and luminol
--- adds nothing, but blood somebody has cleaned is invisible again and luminol
--- is the only thing that finds it (8.10).
function Forensics.revealedBy(tool, type_)
    local reveals = REVEALS[tool]

    return reveals ~= nil and reveals[type_] == true
end

--- Every tool the grid knows, for the route's allowlist.
Forensics.TOOLS = { 'powder', 'luminol', 'forensic_light' }

-- -----------------------------------------------------------------------------
-- Placement and merging (8.3.5)
-- -----------------------------------------------------------------------------

--- Puts a trace into the grid, folding it into an identical neighbour.
---
--- `grid` is a plain map of cell key to a list of items; the caller owns it and
--- this function is the only thing that adds to it. The merge rule itself is
--- `evidence.shouldMerge` (8.3.5) and is deliberately not restated here: there
--- is one definition of "these are the same trace" and both the grid and the
--- lab-facing code read it. That definition includes the trace's state, so a
--- fresh trace never folds into a cleaned, latent or revealed one -- which is
--- why the merge below can copy `count` and `quality` without reconciling
--- anything: the two traces it is merging were already in the same state.
---
--- What a merge does:
---   * the *first* trace stays, with its key and its position. A client that
---     was told about it keeps a key that still works, and the pile does not
---     jump half a metre every time another casing lands on it;
---   * `count` grows, which is what makes "six casings here" one row;
---   * `quality` takes the better of the two -- the freshest casing in the pile
---     is the one the lab would actually work from;
---   * `createdAt` stays at the oldest. A trace cannot be kept alive forever by
---     adding to it, which is what refreshing the age would allow.
---
--- Merging is searched within the trace's own cell only. The merge radius is
--- half a metre against a 32 m cell, so the cases this misses are traces within
--- half a metre of a cell boundary -- two rows instead of one, occasionally,
--- which costs a row and never costs correctness. Searching the eight
--- neighbours to catch it would multiply the cost of the hottest function in
--- the module by nine (12.1).
---
--- **A cap only ever takes from the owner it is capping.** The rule is one
--- sentence -- eviction may only remove a trace whose `ownerKey` is the arriving
--- trace's, and a cell with no such trace in it refuses the arrival instead --
--- and it closes the cheapest way there was of destroying a crime scene. The
--- sensor route is public (ADR-013, 8.3.1), so a client can loop it; with a cap
--- that threw away the oldest trace in the cell whoever had left it, about a
--- minute of that filled a cell and every call afterwards deleted somebody
--- else's casings and blood, oldest first, for no item, no timed action and no
--- audit row. 8.10 prices destroying evidence in time and items; this was free,
--- instant and unattributable, and the removals were booked as evictions, so the
--- one counter that means "evidence is being carried away" did not move either.
---
--- What a cap is for is bounding each source, so `maxPerOwnerPerCell` is the cap
--- that bites and `maxPerCell` is the memory bound underneath it (12.2). Two
--- numbers rather than one scan of the cell for the oldest trace of the arriving
--- owner: a scan alone still lets one player hold every row of a cell and so
--- refuse everybody else's evidence a place to land, which is the same attack
--- with denial in place of deletion.
---
--- The cap counts by **who generated the trace**, not by whose it is, and the
--- difference is the whole of its strength. The owner key is deliberately not
--- one value per player (8.3.4): a print is filed under a character identifier,
--- a casing under a weapon serial alone, a magazine under both. So one player
--- walking one cell produces at least three owner keys, and a fourth for every
--- further weapon -- capping on that would have let a single client hold the
--- whole cell and refuse everybody else, which is the denial the paragraph above
--- rules out. `sourceKey` is the acting player, stamped by `Grid.place` from the
--- server's own idea of who called (never from the trace), so their share is one
--- share however many owner keys they spread it across.
---
--- It falls back to the owner key when a caller does not stamp one, which is the
--- only thing busted can construct and the right answer for a trace the world
--- created rather than a player.
---
--- Refusal is an ordinary outcome and not an error. `Grid.place` answers nil for
--- it exactly as it does for a full world, the sensor route answers the same
--- empty table it answers for a shot that left no casing, and nothing about what
--- happened reaches the client (8.11).
---
--- **This function removes nothing, ever.** Both caps refuse, so there is no
--- eviction to report and no swap for the caller's running count and key lookup
--- to get wrong. The only thing that takes a trace out of a cell is the decay
--- sweep, which is on a timer and belongs to nobody. Two earlier versions did
--- evict here -- first the oldest row in the cell whoever had left it, then the
--- oldest of the arriving source -- and each was a free way to destroy evidence
--- that 8.10 charges time and items for.
---
--- @param grid table cellKey -> list of items
--- @param item table the new trace
--- @param options table|nil { cellSize, mergeRadius, maxPerCell,
---   maxPerOwnerPerCell }
--- @return table|nil stored the item now in the grid: the new one, or the one it
---   merged into; nil when this source is at its share of the cell, or the cell
---   is full
--- @return boolean merged
--- @return string cellKey where it landed, or would have
function Forensics.placeIn(grid, item, options)
    options = options or {}

    local size = options.cellSize or Forensics.defaults.cellSize
    local radius = options.mergeRadius or Forensics.defaults.mergeRadius
    local maxPerCell = options.maxPerCell or Forensics.defaults.maxPerCell
    local maxPerOwner = options.maxPerOwnerPerCell or Forensics.defaults.maxPerOwnerPerCell

    local key = Forensics.cellKey(item.x, item.y, size)
    local cell = grid[key]

    if not cell then
        cell = {}
        grid[key] = cell
    end

    local shouldMerge = FredPD.Modules.evidence.shouldMerge

    -- What this owner already has here, counted on the merge pass rather than on
    -- a second walk of the cell: the pass is the hottest loop in the module
    -- (12.1) and the answer is only ever needed at the end of it.
    local ownerCount = 0
    local mine = Forensics.sourceKeyOf(item)

    for index = 1, #cell do
        local existing = cell[index]

        if Forensics.sourceKeyOf(existing) == mine then
            ownerCount = ownerCount + 1
        end

        if shouldMerge(existing, item, radius) then
            existing.count = (existing.count or 1) + (item.count or 1)

            if (item.quality or 0) > (existing.quality or 0) then
                existing.quality = item.quality
            end

            -- When the pile last grew. Bookkeeping and nothing more: nothing
            -- reads it today -- render data does not carry it (8.1.6), and decay
            -- is measured from `createdAt`, which deliberately stays at the
            -- oldest so a trace cannot be kept alive by adding to it. It is kept
            -- because "when did the last casing land here" is the question a
            -- scene report would ask, and throwing the answer away at the merge
            -- is the one point at which it can never be recovered.
            existing.mergedAt = item.createdAt or existing.mergedAt

            return existing, true, key
        end
    end

    -- The share. A source at it gets nothing new here, and NOTHING OF THEIRS IS
    -- TAKEN AWAY -- which is the whole point, and the half an earlier version of
    -- this got backwards. Evicting a source's own oldest row to fit their newest
    -- makes destroying your own evidence free and deterministic: the eviction
    -- matches on the source and not on the type, so a murderer standing over
    -- their own blood could push it out of the cell with a handful of prints, in
    -- seconds, with no wiping kit and no progress bar. 8.10 prices destroying
    -- evidence in time and items; a cap must not be a way around that price.
    -- Refusing costs the newest trace instead, which is the one that has not
    -- been recorded yet rather than the one that has.
    --
    -- Refusal is also why the share is counted by source rather than by owner.
    -- A client can see which of its own traces reached the world, so a cap that
    -- refused on somebody else's account would answer "is this cell full?" --
    -- and a cell can be full of latent traces that client was never streamed,
    -- which is an 8.11 oracle. Counted by source, the only thing a refusal can
    -- tell them is how many traces they themselves have left here.
    if ownerCount >= maxPerOwner then
        return nil, false, key, nil
    end

    -- The cell cap underneath it, which is a memory bound and not a fairness one
    -- (12.2). It refuses too, and for the same reason: NO CAP IN THIS FUNCTION
    -- MAY REMOVE A TRACE. An earlier version made this one evict the oldest row
    -- of whichever source held the most, on the reasoning that one source could
    -- never reach the cell cap because their share stopped them short -- which
    -- is true at the defaults and false the moment a server configures the share
    -- at or near the cell cap, at which point the first arrival deletes somebody
    -- else's scene again. A rule that holds only for the values that shipped is
    -- not the rule; this one holds for every configuration.
    --
    -- Refusing also keeps the better half of the evidence. "Newest wins" sounds
    -- neutral and is not: the oldest trace in a cell is the shot that started
    -- it, and the newest is the sixty-fifth footprint of the crowd that gathered
    -- afterwards.
    if #cell >= maxPerCell then
        return nil, false, key, nil
    end

    cell[#cell + 1] = item

    return item, false, key
end

-- -----------------------------------------------------------------------------
-- Decay (8.1.4, 12.2)
-- -----------------------------------------------------------------------------

--- Has this trace aged out of the world entirely?
---
--- Different from quality decay, which lowers what the lab can get out of a
--- sample that is still there (8.1.4). This is the point at which there is
--- nothing to collect: the casing has been swept up, the print has degraded past
--- recovery, and the grid stops carrying the row.
---
--- A lifetime of zero or less means "never", which is how a server switches the
--- sweep off for a type it wants to keep until somebody collects it.
---
--- @param item table
--- @param now number unix seconds
--- @param config table as `Forensics.settings` returns
--- @return boolean
function Forensics.decayed(item, now, config)
    config = config or Forensics.defaults

    local lifetime = (config.lifetimeSeconds or {})[item.type]
    if lifetime == nil then lifetime = config.defaultLifetimeSeconds end
    if not lifetime or lifetime <= 0 then return false end

    return (now - (item.createdAt or 0)) >= lifetime
end

--- How much gunshot residue is left on a shooter (8.2).
---
--- The arithmetic lives here rather than in `gsr.lua` for the same reason the
--- rest of this file does: a decay curve is exactly the kind of thing that is
--- either right or quietly wrong, and it has to be assertable without a running
--- server. `gsr.lua` owns the table of who has been marked and the clock; this
--- owns what the number means.
---
--- Linear, not exponential. A curve would be more realistic and completely
--- unreadable to a server owner tuning it: a rate in points per minute is a
--- number somebody can put in a config file and predict the effect of.
---
--- @param markedAt number|nil unix seconds of the last shot fired
--- @param now number unix seconds
--- @param config table|nil as `Forensics.settings` returns
--- @return number level 0..100; zero means there is nothing left to find
function Forensics.gsrLevel(markedAt, now, config)
    config = config or Forensics.defaults

    if type(markedAt) ~= 'number' or type(now) ~= 'number' then return 0 end

    -- A clock that went backwards (a server time change) reads as "just fired"
    -- rather than as a negative age, which would decay *upwards*.
    local elapsed = math.max(now - markedAt, 0)

    local lifetime = tonumber(config.gsrLifetimeSeconds) or 0
    if lifetime > 0 and elapsed >= lifetime then return 0 end

    local perMinute = tonumber(config.gsrDecayPerMinute) or 0
    local level = math.floor(100 - (elapsed / 60) * perMinute)

    if level <= 0 then return 0 end

    return math.min(level, 100)
end

--- How much quality a trace of this type loses per hour, for `qualityAfter`.
function Forensics.decayPerHour(type_, config)
    config = config or Forensics.defaults

    return (config.decayPerHour or {})[type_] or 2
end

-- -----------------------------------------------------------------------------
-- Sampling (8.2, 12.2)
-- -----------------------------------------------------------------------------

--- Does *this* shot leave a casing?
---
--- The rate is exactly one casing per `casingEvery` shots, and the shot that
--- leaves it is the first of each run: shots 1, 6, 11 at the default of five.
--- The first shot counting is the half that matters -- a single shot fired at a
--- victim is the most investigable event in the game, and a rule that started
--- counting at the fifth would leave nothing behind it.
---
--- Deterministic in the shot counter, which the server keeps per player. Chance
--- would make the rate an anecdote instead of a number, and `math.random` is
--- not available to the tests that have to prove it.
---
--- @param shotCount number the player's running shot count, 1 for their first
--- @param config table|nil
--- @return boolean
function Forensics.sampleShot(shotCount, config)
    config = config or Forensics.defaults

    local every = tonumber(config.casingEvery) or Forensics.defaults.casingEvery
    every = math.floor(every)

    if type(shotCount) ~= 'number' or shotCount < 1 then return false end
    if every <= 1 then return true end

    return (math.floor(shotCount) - 1) % every == 0
end

FredPD.Modules.forensics = Forensics
