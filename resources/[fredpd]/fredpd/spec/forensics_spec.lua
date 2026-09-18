--- The uncollected-trace grid (spec 8.3.5, 8.1.6, 12.1).
---
--- Four of these tests are about a number nobody can eyeball on a running
--- server: which cell a position falls in, how many cells a client is
--- subscribed to, when a trace has aged out, and how often a shot leaves a
--- casing. Each of them is either exactly right or quietly wrong in a way that
--- only shows up as "evidence sometimes does not appear", which is the hardest
--- class of bug to report and the easiest to write.
---
--- The fifth is the one that matters most. Merging is what stands between a
--- magazine emptied into a wall and thirty rows in a grid cell (8.3.5, spec
--- 12), and the assertion worth making is not that merging happens but that it
--- folds into the *first* trace rather than appending a second.

local helper = require('spec.helper')

describe('forensics grid', function()
    local forensics, evidence

    before_each(function()
        -- The evidence service comes first: `placeIn` merges through
        -- `evidence.shouldMerge`, which is the one definition of "these are the
        -- same trace" and is deliberately not restated in the forensics service.
        local fredpd = helper.load({
            'server/modules/evidence/service',
            'server/modules/forensics/service',
        })

        forensics = fredpd.Modules.forensics
        -- Kept for the two rules that span the pair: merging, and what the lab
        -- makes of a residue level this module computed.
        evidence = fredpd.Modules.evidence
    end)

    -- -------------------------------------------------------------------------
    -- Cells
    -- -------------------------------------------------------------------------

    describe('cellKey', function()
        it('puts a position in the cell that contains it', function()
            assert.are.equal('0:0', forensics.cellKey(0, 0, 32))
            assert.are.equal('0:0', forensics.cellKey(31.9, 31.9, 32))
            assert.are.equal('1:2', forensics.cellKey(40, 70, 32))
        end)

        it('gives a boundary position to exactly one cell', function()
            -- The whole point: x = 32 is the *first* metre of cell 1, never the
            -- last of cell 0. A rule that answered both would stream a trace
            -- twice; one that answered neither would lose it.
            assert.are.equal('0:0', forensics.cellKey(31.999, 0, 32))
            assert.are.equal('1:0', forensics.cellKey(32, 0, 32))
            assert.are.equal('1:0', forensics.cellKey(32.001, 0, 32))
            assert.are.equal('1:0', forensics.cellKey(63.999, 0, 32))
            assert.are.equal('2:0', forensics.cellKey(64, 0, 32))
        end)

        it('holds the same rule on the negative side of the origin', function()
            -- Los Santos is mostly negative on one axis or the other, so this
            -- is not an edge case, it is half the map.
            assert.are.equal('-1:-1', forensics.cellKey(-0.001, -0.001, 32))
            assert.are.equal('-1:0', forensics.cellKey(-32, 0, 32))
            assert.are.equal('-2:0', forensics.cellKey(-32.001, 0, 32))
            assert.are.equal('-1:0', forensics.cellKey(-0.5, 0, 32))
        end)

        it('never answers two cells for one position', function()
            -- Walked across four cell boundaries a tenth of a metre at a time:
            -- every position gets exactly one key, and the key only ever changes
            -- forward.
            local previous = forensics.cellKey(-64, 0, 32)
            local changes = 0

            for step = -640, 640 do
                local key = forensics.cellKey(step / 10, 0, 32)

                if key ~= previous then
                    changes = changes + 1
                    previous = key
                end
            end

            -- -64 .. 64 crosses -32, 0, 32 and 64: four boundaries.
            assert.are.equal(4, changes)
        end)

        it('uses the configured cell size by default', function()
            local size = forensics.defaults.cellSize

            assert.are.equal(forensics.cellKey(100, 100, size), forensics.cellKey(100, 100))
        end)
    end)

    describe('cellsAround', function()
        it('subscribes to the three-by-three ring at one cell of range', function()
            local cells = forensics.cellsAround(16, 16, 32, 32)

            assert.are.equal(9, #cells)
            assert.are.same({
                '-1:-1', '-1:0', '-1:1',
                '0:-1', '0:0', '0:1',
                '1:-1', '1:0', '1:1',
            }, cells)
        end)

        it('subscribes to one cell when the range stays inside it', function()
            local cells = forensics.cellsAround(16, 16, 1, 32)

            assert.are.same({ '0:0' }, cells)
        end)

        it('grows to four cells when the player stands on a corner', function()
            -- Standing exactly on the intersection of four cells with a metre of
            -- range: all four, and no more.
            local cells = forensics.cellsAround(32, 32, 1, 32)

            assert.are.same({ '0:0', '0:1', '1:0', '1:1' }, cells)
        end)

        it('always contains the cell the player is standing in', function()
            local here = forensics.cellKey(-1234.5, 678.9, 32)
            local cells = forensics.cellsAround(-1234.5, 678.9, 96, 32)

            local found = false
            for index = 1, #cells do
                if cells[index] == here then found = true end
            end

            assert.is_true(found)
        end)

        it('covers the default streaming range at the default cell size', function()
            -- 96 m of range over 32 m cells is seven cells across at worst, so
            -- the budget in 12.1 is at most 49 updates a second for one client
            -- who is teleporting. Standing still it is zero.
            local cells = forensics.cellsAround(0, 0, 96, 32)

            assert.are.equal(49, #cells)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Merging (8.3.5)
    -- -------------------------------------------------------------------------

    describe('placeIn', function()
        local function trace(overrides)
            local item = {
                key = 'k1',
                type = 'casing',
                x = 10.0,
                y = 10.0,
                z = 30.0,
                ownerKey = '|SN-0001',
                quality = 100,
                count = 1,
                createdAt = 1000,
            }

            for key, value in pairs(overrides or {}) do item[key] = value end

            return item
        end

        it('files a trace in its own cell', function()
            local grid = {}
            local stored, merged, cell = forensics.placeIn(grid, trace(), { cellSize = 32 })

            assert.is_false(merged)
            assert.are.equal('0:0', cell)
            assert.are.equal(1, #grid['0:0'])
            assert.are.equal('k1', stored.key)
        end)

        it('folds an identical second trace into the first', function()
            -- The rule the whole of 12.2's "casing and blood generation sampled
            -- and merged" rests on. Two casings from the same gun, 10 cm apart.
            local grid = {}

            forensics.placeIn(grid, trace(), { cellSize = 32 })
            local stored, merged = forensics.placeIn(
                grid, trace({ key = 'k2', x = 10.1, createdAt = 1060 }), { cellSize = 32 }
            )

            assert.is_true(merged)
            assert.are.equal(1, #grid['0:0'], 'the second trace must not be appended')
            assert.are.equal('k1', stored.key, 'the first trace stays, keys and all')
            assert.are.equal(2, stored.count)
            -- The position does not move, so a client already drawing it does
            -- not see the pile jump.
            assert.are.equal(10.0, stored.x)
        end)

        it('keeps the better sample and the older age when it folds', function()
            local grid = {}

            forensics.placeIn(grid, trace({ quality = 60 }), { cellSize = 32 })
            local stored = forensics.placeIn(
                grid, trace({ key = 'k2', quality = 95, createdAt = 9000 }), { cellSize = 32 }
            )

            -- The freshest casing in the pile is what the lab works from...
            assert.are.equal(95, stored.quality)
            -- ...but adding to a pile does not renew it, or a trace could be
            -- kept alive forever by dropping one more casing on it.
            assert.are.equal(1000, stored.createdAt)
        end)

        it('empties a magazine into one row', function()
            local grid = {}

            for shot = 1, 30 do
                forensics.placeIn(
                    grid,
                    trace({ key = 'k' .. shot, x = 10.0 + shot * 0.01, createdAt = 1000 + shot }),
                    { cellSize = 32 }
                )
            end

            assert.are.equal(1, #grid['0:0'])
            assert.are.equal(30, grid['0:0'][1].count)
        end)

        it('does not merge traces of different types', function()
            local grid = {}

            forensics.placeIn(grid, trace(), { cellSize = 32 })
            local _, merged = forensics.placeIn(grid, trace({ key = 'k2', type = 'blood' }), { cellSize = 32 })

            assert.is_false(merged)
            assert.are.equal(2, #grid['0:0'])
        end)

        it('does not merge traces from different owners', function()
            -- Two people bled on the same doorstep. Folding them together would
            -- turn two profiles into one and lose an entire suspect.
            local grid = {}

            forensics.placeIn(grid, trace({ type = 'blood', ownerKey = 'char1|' }), { cellSize = 32 })
            local _, merged = forensics.placeIn(
                grid, trace({ key = 'k2', type = 'blood', ownerKey = 'char2|' }), { cellSize = 32 }
            )

            assert.is_false(merged)
            assert.are.equal(2, #grid['0:0'])
        end)

        it('does not merge traces further apart than the radius', function()
            local grid = {}

            forensics.placeIn(grid, trace(), { cellSize = 32, mergeRadius = 0.5 })
            local _, merged = forensics.placeIn(
                grid, trace({ key = 'k2', x = 11.0 }), { cellSize = 32, mergeRadius = 0.5 }
            )

            assert.is_false(merged)
            assert.are.equal(2, #grid['0:0'])
        end)

        it('puts traces in different cells in different cells', function()
            local grid = {}

            forensics.placeIn(grid, trace(), { cellSize = 32 })
            forensics.placeIn(grid, trace({ key = 'k2', x = 40.0 }), { cellSize = 32 })

            assert.are.equal(1, #grid['0:0'])
            assert.are.equal(1, #grid['1:0'])
        end)

        it('caps a cell by dropping its oldest trace', function()
            -- Spec 12.2's evidence cap. The newest evidence is the evidence that
            -- survives, because it is the evidence somebody might still be
            -- looking for.
            local grid = {}
            local options = { cellSize = 32, maxPerCell = 3 }

            for index = 1, 4 do
                forensics.placeIn(grid, trace({
                    key = 'k' .. index,
                    -- Far enough apart not to merge.
                    x = 1.0 + index * 2,
                    createdAt = 1000 + index,
                }), options)
            end

            local cell = grid['0:0']
            assert.are.equal(3, #cell)

            for index = 1, #cell do
                assert.are_not.equal('k1', cell[index].key)
            end
        end)

        it('hands the evicted trace back to the caller', function()
            -- The caller keeps a running item count and a key lookup, and a cap
            -- that swapped silently left both wrong: the count grew for what was
            -- not an arrival, and the lookup kept pointing at a trace that had
            -- left the grid. Neither is visible from in here, which is exactly
            -- why the eviction has to leave through the return values.
            local grid = {}
            local options = { cellSize = 32, maxPerCell = 2 }

            for index = 1, 2 do
                forensics.placeIn(grid, trace({ key = 'k' .. index, x = 1.0 + index * 2, createdAt = 1000 + index }), options)
            end

            local _, _, _, evicted = forensics.placeIn(
                grid, trace({ key = 'k3', x = 9.0, createdAt = 1003 }), options
            )

            assert.is_not_nil(evicted)
            assert.are.equal('k1', evicted.key)
        end)

        it('evicts nothing while the cell has room', function()
            local grid = {}
            local _, _, _, evicted = forensics.placeIn(grid, trace(), { cellSize = 32, maxPerCell = 2 })

            assert.is_nil(evicted)
        end)

        it('evicts nothing when the trace merged instead of landing', function()
            -- A merge does not add a row, so it can never need to make room --
            -- and a caller that decremented its count for an eviction reported
            -- here would lose a trace that is still in the grid.
            local grid = {}
            local options = { cellSize = 32, maxPerCell = 1 }

            forensics.placeIn(grid, trace(), options)
            local _, merged, _, evicted = forensics.placeIn(grid, trace({ key = 'k2', x = 10.1 }), options)

            assert.is_true(merged)
            assert.is_nil(evicted)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Decay (8.1.4)
    -- -------------------------------------------------------------------------

    describe('decayed', function()
        local config

        before_each(function()
            -- Overrides merge onto the defaults per type, so a type named here
            -- takes this lifetime and every other type keeps its own.
            config = forensics.settings({
                defaultLifetimeSeconds = 100,
                lifetimeSeconds = { casing = 600, print = 100, tool_mark = 0 },
            })
        end)

        it('keeps a trace inside its lifetime', function()
            assert.is_false(forensics.decayed({ type = 'casing', createdAt = 0 }, 599, config))
        end)

        it('removes a trace the moment its lifetime is up', function()
            assert.is_true(forensics.decayed({ type = 'casing', createdAt = 0 }, 600, config))
            assert.is_true(forensics.decayed({ type = 'casing', createdAt = 0 }, 60000, config))
        end)

        it('removes only what is past its own lifetime', function()
            -- The same sweep, the same second, two types: the casing stays
            -- because casings lie around, the print is gone.
            local now = 200

            assert.is_false(forensics.decayed({ type = 'casing', createdAt = 0 }, now, config))
            assert.is_true(forensics.decayed({ type = 'print', createdAt = 0 }, now, config))
        end)

        it('falls back to the default lifetime for a type with none configured', function()
            -- Residue has no lifetime of its own in the defaults or in the
            -- overrides above, so it takes the default one.
            assert.is_false(forensics.decayed({ type = 'gsr', createdAt = 0 }, 99, config))
            assert.is_true(forensics.decayed({ type = 'gsr', createdAt = 0 }, 100, config))
        end)

        it('never removes a type configured to last forever', function()
            assert.is_false(forensics.decayed({ type = 'tool_mark', createdAt = 0 }, 10 ^ 9, config))
        end)

        it('measures from when the trace was left, not from the sweep', function()
            local item = { type = 'casing', createdAt = 1000 }

            assert.is_false(forensics.decayed(item, 1599, config))
            assert.is_true(forensics.decayed(item, 1600, config))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Sampling (8.2, 12.2)
    -- -------------------------------------------------------------------------

    describe('sampleShot', function()
        it('leaves one casing per five shots at the default', function()
            local config = forensics.settings()
            local left = {}

            for shot = 1, 30 do
                if forensics.sampleShot(shot, config) then left[#left + 1] = shot end
            end

            assert.are.same({ 1, 6, 11, 16, 21, 26 }, left)
            -- The documented rate, and the reason a thirty-round magazine does
            -- not become thirty rows (8.2).
            assert.are.equal(6, #left)
        end)

        it('always leaves a casing for the first shot', function()
            -- A single shot fired at somebody is the most investigable event in
            -- the game. A rule that started counting later would leave nothing
            -- behind it at all.
            assert.is_true(forensics.sampleShot(1, forensics.settings()))
        end)

        it('honours a configured rate', function()
            local config = forensics.settings({ casingEvery = 3 })
            local left = {}

            for shot = 1, 10 do
                if forensics.sampleShot(shot, config) then left[#left + 1] = shot end
            end

            assert.are.same({ 1, 4, 7, 10 }, left)
        end)

        it('leaves a casing for every shot when the rate is one', function()
            local config = forensics.settings({ casingEvery = 1 })

            for shot = 1, 10 do
                assert.is_true(forensics.sampleShot(shot, config))
            end
        end)

        it('is deterministic, so the rate is a number and not an anecdote', function()
            local config = forensics.settings()

            for _ = 1, 20 do
                assert.is_true(forensics.sampleShot(11, config))
                assert.is_false(forensics.sampleShot(12, config))
            end
        end)

        it('refuses a counter that is not a count', function()
            local config = forensics.settings()

            assert.is_false(forensics.sampleShot(0, config))
            assert.is_false(forensics.sampleShot(-4, config))
            assert.is_false(forensics.sampleShot('3', config))
            assert.is_false(forensics.sampleShot(nil, config))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Owners, visibility and the push budget
    -- -------------------------------------------------------------------------

    describe('ownerKey', function()
        it('is the same for two traces from the same source', function()
            assert.are.equal(
                forensics.ownerKey({ identifier = 'char1:abc' }),
                forensics.ownerKey({ identifier = 'char1:abc' })
            )
        end)

        it('separates a person from a weapon', function()
            assert.are_not.equal(
                forensics.ownerKey({ identifier = 'char1:abc' }),
                forensics.ownerKey({ weaponSerial = 'char1:abc' })
            )
        end)

        it('never merges two unattributed traces', function()
            -- A trace with no owner is a bug in the generation pipeline (8.3.4).
            -- Merging two of them would hide it behind a count of two.
            local left = { type = 'blood', x = 0, y = 0, z = 0, ownerKey = forensics.ownerKey(nil) }
            local right = { type = 'blood', x = 0, y = 0, z = 0, ownerKey = forensics.ownerKey({}) }

            assert.are.equal('?', left.ownerKey)
            assert.are.equal('?', right.ownerKey)

            -- They compare equal, so `placeIn` would fold them -- which is why
            -- the routes refuse to create one at all. Asserted here so that
            -- staying true is a decision somebody has to make again.
            assert.is_true(FredPD.Modules.evidence.shouldMerge(left, right, 0.5))
        end)
    end)

    describe('visibility', function()
        it('makes prints and trace material invisible until processed', function()
            assert.is_true(forensics.isLatent('print'))
            assert.is_true(forensics.isLatent('glove_mark'))
            assert.is_true(forensics.isLatent('dna_touch'))
        end)

        it('leaves casings, magazines and blood visible to anyone', function()
            -- 8.10 is built on this: a criminal has to be able to walk back and
            -- pick up their own casings.
            assert.is_false(forensics.isLatent('casing'))
            assert.is_false(forensics.isLatent('magazine'))
            assert.is_false(forensics.isLatent('blood'))
        end)

        it('matches each tool to what it finds', function()
            assert.is_true(forensics.revealedBy('powder', 'print'))
            assert.is_true(forensics.revealedBy('powder', 'glove_mark'))
            -- Blood is visible until somebody cleans it, and then luminol is the
            -- only thing that finds it again (8.10).
            assert.is_true(forensics.revealedBy('luminol', 'blood'))
            assert.is_true(forensics.revealedBy('forensic_light', 'dna_touch'))
        end)

        it('does not match a tool to a type it cannot find', function()
            assert.is_false(forensics.revealedBy('powder', 'blood'))
            assert.is_false(forensics.revealedBy('luminol', 'print'))
            assert.is_false(forensics.revealedBy('forensic_light', 'casing'))
        end)

        it('refuses a tool it does not know', function()
            assert.is_false(forensics.revealedBy('hammer', 'print'))
            assert.is_false(forensics.revealedBy(nil, 'print'))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Gunshot residue (8.2) -- the arithmetic, without a clock
    -- -------------------------------------------------------------------------

    describe('gsrLevel', function()
        it('is everything the moment the shot is fired', function()
            assert.are.equal(100, forensics.gsrLevel(1000, 1000, forensics.settings()))
        end)

        it('falls at the configured rate per minute', function()
            local config = forensics.settings({ gsrDecayPerMinute = 1, gsrLifetimeSeconds = 0 })

            assert.are.equal(90, forensics.gsrLevel(0, 10 * 60, config))
            assert.are.equal(50, forensics.gsrLevel(0, 50 * 60, config))
            assert.are.equal(0, forensics.gsrLevel(0, 100 * 60, config))
        end)

        it('is gone at the lifetime even when the rate would keep it forever', function()
            -- The ceiling is why the rate is safe to configure: a server that
            -- sets the decay to zero gets residue that ends, not every player
            -- who has ever fired a weapon swabbing positive for the rest of the
            -- night (8.2, "destroyed by ... time").
            local config = forensics.settings({ gsrDecayPerMinute = 0, gsrLifetimeSeconds = 3600 })

            assert.are.equal(100, forensics.gsrLevel(0, 3599, config))
            assert.are.equal(0, forensics.gsrLevel(0, 3600, config))
        end)

        it('reads a clock that went backwards as a fresh shot', function()
            -- A server time change must not decay residue upwards, which is what
            -- a negative age multiplied by a negative rate would do.
            assert.are.equal(100, forensics.gsrLevel(5000, 1000, forensics.settings()))
        end)

        it('answers nothing for a player who has never fired', function()
            assert.are.equal(0, forensics.gsrLevel(nil, 1000, forensics.settings()))
        end)

        it('never exceeds a hundred', function()
            local config = forensics.settings({ gsrDecayPerMinute = -10 })

            assert.are.equal(100, forensics.gsrLevel(0, 3600, config))
        end)

        it('is not a world trace, so it has no lifetime among the types', function()
            -- GSR is on the shooter, not on the ground (8.2). A lifetime entry
            -- for it would mean the grid sweep believed it was in the grid.
            assert.is_nil(forensics.defaults.lifetimeSeconds.gsr)
        end)

        it('is what the lab reads a swab off, from the level alone', function()
            -- The two halves of the residue mechanic meet here and used to
            -- disagree: `claimGsr` stores this level as the item's quality, and
            -- the GSR rule used to search for a weapon serial that 8.2 says a
            -- swab never carries -- so a suspect swabbed with residue all over
            -- their hands was formally reported as not having fired.
            local config = forensics.settings()
            local fresh = forensics.gsrLevel(0, 0, config)
            local stale = forensics.gsrLevel(0, 3 * 3600, config)

            assert.are.equal('candidate_match', evidence.resultFor('gsr', { quality = fresh }))
            assert.are.equal('insufficient', evidence.resultFor('gsr', { quality = stale }))
        end)
    end)

    describe('settings', function()
        it('answers the defaults when a server configures nothing', function()
            local config = forensics.settings(nil)

            assert.are.equal(forensics.defaults.cellSize, config.cellSize)
            assert.are.equal(forensics.defaults.casingEvery, config.casingEvery)
        end)

        it('keeps the other types when one lifetime is overridden', function()
            local config = forensics.settings({ lifetimeSeconds = { casing = 60 } })

            assert.are.equal(60, config.lifetimeSeconds.casing)
            assert.are.equal(forensics.defaults.lifetimeSeconds.blood, config.lifetimeSeconds.blood)
        end)

        it('never mutates the defaults', function()
            local config = forensics.settings({ cellSize = 8, lifetimeSeconds = { casing = 1 } })

            config.cellSize = 4

            assert.are.equal(32.0, forensics.defaults.cellSize)
            assert.are.equal(6 * 3600, forensics.defaults.lifetimeSeconds.casing)
        end)

        it('names an item for each destruction action that costs one (8.10)', function()
            local config = forensics.settings()

            assert.are.equal('wiping_kit', config.destroyItems.wipe)
            assert.are.equal('wiping_kit', config.destroyItems.weapon)
            assert.are.equal('cleaning_chemicals', config.destroyItems.clean)
        end)

        it('charges nothing for a sink or a hand', function()
            -- 8.10 is explicit that destruction is available to every player;
            -- an item on washing or on picking your own brass up would make it
            -- available to the prepared ones.
            local config = forensics.settings()

            assert.is_nil(config.destroyItems.wash)
            assert.is_nil(config.destroyItems.pickup)
        end)

        it('keeps the other kits when a server renames one of them', function()
            local config = forensics.settings({ destroyItems = { clean = 'bleach' } })

            assert.are.equal('bleach', config.destroyItems.clean)
            assert.are.equal('wiping_kit', config.destroyItems.wipe)
            assert.are.equal('wiping_kit', config.destroyItems.weapon)
        end)

        it('wipes at an arm\'s length and not at the reach of the entity check', function()
            -- The sphere is centred on something `entityRange` allows to be six
            -- metres from the player, so a radius of `entityRange` destroys
            -- everything within twelve -- four times the three an officer must
            -- be inside to collect. A door handle is an arm's length.
            local config = forensics.settings()

            assert.are.equal(1.5, config.wipeRadius)
            assert.is_true(config.wipeRadius < config.collectRange)
            assert.is_true(config.wipeRadius * 2 < config.entityRange)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Merging state (8.3.5, 8.10)
    -- -------------------------------------------------------------------------

    describe('placeIn and a trace in another state', function()
        local function trace(overrides)
            local item = {
                type = 'blood', x = 0.0, y = 0.0, z = 0.0,
                ownerKey = 'char1|', quality = 100, count = 1, createdAt = 1000,
                latent = false, revealed = false, cleaned = false,
            }

            for key, value in pairs(overrides or {}) do item[key] = value end

            return item
        end

        it('refuses to fold a fresh trace into a cleaned one', function()
            local world = { }
            local cleaned = trace({ cleaned = true, latent = true })

            local _, mergedCleaned = FredPD.Modules.forensics.placeIn(world, cleaned, { mergeRadius = 0.5 })
            assert.is_false(mergedCleaned)

            local fresh = trace({ x = 0.1 })
            local stored, merged = FredPD.Modules.forensics.placeIn(world, fresh, { mergeRadius = 0.5 })

            -- Merging would give the new blood the old pool's quarter yield and
            -- its invisibility (8.10) -- for free, an hour after the mopping.
            assert.is_false(merged)
            assert.are.equal(fresh, stored)
            assert.is_false(stored.cleaned)
            assert.are.equal(1, cleaned.count)
        end)

        it('refuses to fold a fresh latent trace into a revealed one', function()
            local world = {}
            local revealed = trace({ type = 'print', latent = true, revealed = true })

            FredPD.Modules.forensics.placeIn(world, revealed, { mergeRadius = 0.5 })

            local fresh = trace({ type = 'print', x = 0.1, latent = true })
            local _, merged = FredPD.Modules.forensics.placeIn(world, fresh, { mergeRadius = 0.5 })

            -- Otherwise a print left after the powder went down is disclosed to
            -- every officer in range without anybody dusting for it (8.4, 8.11).
            assert.is_false(merged)
        end)

        it('still folds two traces in the same state', function()
            local world = {}
            local first = trace()

            FredPD.Modules.forensics.placeIn(world, first, { mergeRadius = 0.5 })

            local second = trace({ x = 0.1 })
            local stored, merged = FredPD.Modules.forensics.placeIn(world, second, { mergeRadius = 0.5 })

            assert.is_true(merged)
            assert.are.equal(first, stored)
            assert.are.equal(2, first.count)
        end)

        it('reads a trace that says nothing about its state as fresh', function()
            -- The lab-facing callers pass plain rows with none of the three
            -- flags on them; two of those are in the same state as each other.
            local left = { type = 'casing', x = 0.0, y = 0.0, z = 0.0, ownerKey = 'SN-1' }
            local right = { type = 'casing', x = 0.1, y = 0.0, z = 0.0, ownerKey = 'SN-1' }

            assert.is_true(FredPD.Modules.evidence.shouldMerge(left, right, 0.5))
            assert.is_false(FredPD.Modules.evidence.shouldMerge(left, trace({
                type = 'casing', x = 0.1, ownerKey = 'SN-1', cleaned = true,
            }), 0.5))
        end)
    end)
end)

-- -----------------------------------------------------------------------------
-- The live grid and gunshot residue, in memory
-- -----------------------------------------------------------------------------

--- Why these load `grid.lua` and `gsr.lua` rather than testing around them.
---
--- The house rule is that only `service.lua` is loadable under busted, because
--- only `service.lua` is free of natives (spec 3.4), and the four bugs these
--- tests exist for -- a cell version that restarts, a cap that miscounts, a
--- subscription created for a player with nothing to say to, and a `touch(nil)`
--- -- all live in `grid.lua`. Extracting them into `service.lua` was the other
--- option and it is the wrong one: what is wrong is the *bookkeeping between*
--- the cell list, the version table, the key lookup and the running count, and
--- moving four tables into a pure module to test them would be moving the module
--- rather than testing it.
---
--- So the natives are stubbed instead, the way `admin_spec` stubs `json` and
--- `evidence_spec` stubs `print`, and they are restored afterwards so the stubs
--- cannot leak into another spec file. There are six of them, all trivial, and
--- `CreateThread` is a no-op -- the two timers never run, and `Grid.push` is
--- called directly so a test drives the streaming loop a tick at a time instead
--- of waiting a second for it.
local NATIVES <const> = {
    'AddEventHandler', 'CreateThread', 'GetEntityCoords', 'GetPlayerPed', 'GetPlayers', 'Wait',
}

--- Decay is a function of the clock, so the clock has to be a thing a test can
--- move. `os.time` is replaced for the duration of a test and put back in
--- `after_each`; luacheck reads that as writing to a standard library (W122),
--- which it normally should. Sleeping for four hours is the alternative.
-- luacheck: ignore 122

describe('forensics grid, in memory', function()
    local grid
    local pushes, positions, sessions, clock
    local saved, realTime
    local osLib = os

    --- Loads the grid and the residue table over the pure services.
    ---
    --- Called again inside a test that needs different settings: everything is
    --- module state, so a fresh load is the only honest way to change a setting
    --- the grid resolved at boot.
    local function load(overrides)
        local fredpd = helper.load({
            'server/modules/evidence/service',
            'server/modules/forensics/service',
        })

        fredpd.Config = { server = { forensics = overrides } }
        fredpd.markArrays = function(value) return value end

        fredpd.Core = {
            push = {
                toSession = function(src, event, payload)
                    pushes[#pushes + 1] = { src = src, event = event, payload = payload }
                end,
            },
            session = { all = function() return sessions end },
            perms = {
                satisfies = function(permissions, permission)
                    for index = 1, #(permissions or {}) do
                        if permissions[index] == permission then return true end
                    end

                    return false
                end,
            },
        }

        assert(loadfile('resources/[fredpd]/fredpd/server/modules/forensics/grid.lua'))()

        grid = fredpd.Forensics.grid
    end

    --- Everything the client at `src` is currently drawing, by trace key.
    ---
    --- Built by replaying the pushes the way the client does -- each message
    --- replaces the contents of the cells it names -- because that is the only
    --- assertion worth making. "A message was sent" is not the property; "the
    --- player can see the casing that is there and cannot see the one that was
    --- collected" is.
    local function drawing(src)
        local world = {}

        for index = 1, #pushes do
            local push = pushes[index]

            if push.src == src then
                local sent = push.payload.cells

                for cellIndex = 1, #sent do
                    local keys = {}

                    for itemIndex = 1, #sent[cellIndex].items do
                        keys[sent[cellIndex].items[itemIndex].key] = true
                    end

                    world[sent[cellIndex].cell] = keys
                end
            end
        end

        local flat = {}

        for _, keys in pairs(world) do
            for key in pairs(keys) do flat[key] = true end
        end

        return flat
    end

    --- How many messages this client has been sent.
    ---
    --- The count is the assertion for 8.11's oracle: a message a client cannot
    --- read anything new out of is still a message, and its arrival is itself the
    --- fact -- that somebody with powder is working the ground they are standing
    --- on. "What they can see" is unchanged in those tests by construction, so
    --- the only thing left to assert on is whether they heard anything at all.
    local function messages(src)
        local count = 0

        for index = 1, #pushes do
            if pushes[index].src == src then count = count + 1 end
        end

        return count
    end

    local function casing(x, serial)
        return grid.place({
            type = 'casing', x = x, y = 10.0, z = 30.0, owner = { weaponSerial = serial or ('SN-' .. x) },
        })
    end

    before_each(function()
        saved = {}
        for index = 1, #NATIVES do saved[NATIVES[index]] = _G[NATIVES[index]] end

        realTime = osLib.time
        clock = 1700000000
        osLib.time = function() return clock end

        pushes, positions, sessions = {}, {}, {}

        _G.AddEventHandler = function() end
        _G.CreateThread = function() end
        _G.Wait = function() end
        _G.GetPlayers = function() return {} end
        -- A player's ped handle is their server id, so a coordinate lookup is a
        -- source lookup. Zero means "no ped", which is what the grid checks for.
        _G.GetPlayerPed = function(src) return positions[src] and src or 0 end
        _G.GetEntityCoords = function(ped) return positions[ped] end

        load(nil)
    end)

    after_each(function()
        for index = 1, #NATIVES do _G[NATIVES[index]] = saved[NATIVES[index]] end
        osLib.time = realTime
    end)

    -- -------------------------------------------------------------------------
    -- Cell versions
    -- -------------------------------------------------------------------------

    describe('streaming a cell that changed', function()
        it('re-sends a cell that emptied and refilled between two pushes', function()
            -- The stale-render bug, and it needs no walking about to reproduce:
            -- one officer collects the casing, another shot lands in the same
            -- cell, and with a per-cell counter that restarts at one the client
            -- is still drawing a key that names nothing and is never told about
            -- the casing that is actually there.
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            local first = casing(10.0, 'SN-1')
            grid.push(1)

            assert.is_true(drawing(1)[first.key])

            grid.take(first.key)
            local second = casing(10.4, 'SN-2')

            grid.push(1)

            assert.is_true(drawing(1)[second.key], 'the new casing must reach a client who saw the old one')
            assert.is_nil(drawing(1)[first.key], 'the collected casing must not still be drawn')
        end)

        it('retracts a cell emptied under a player who has not moved', function()
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            local trace = casing(10.0, 'SN-1')
            grid.push(1)
            grid.take(trace.key)
            grid.push(1)

            assert.are.equal(2, #pushes)
            assert.are.equal(0, #pushes[2].payload.cells[1].items)
            assert.is_nil(drawing(1)[trace.key])
        end)

        it('retracts what a player drew when they walk out of range', function()
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            local trace = casing(10.0, 'SN-1')
            grid.push(1)

            positions[1] = { x = 5000.0, y = 5000.0, z = 30.0 }
            grid.push(1)

            assert.is_nil(drawing(1)[trace.key])
            assert.are.equal(0, grid.stats().subscribers)
        end)

        it('says nothing twice about a cell that has not changed', function()
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            casing(10.0, 'SN-1')
            grid.push(1)
            grid.push(1)
            grid.push(1)

            assert.are.equal(1, #pushes)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Subscriptions (12.1)
    -- -------------------------------------------------------------------------

    describe('subscriptions', function()
        it('never makes a subscriber of a player nowhere near evidence', function()
            -- The streaming loop's early-out is `next(cells) or
            -- next(subscriptions)`, so a subscription created for every player
            -- the loop touches makes the idle cost claimed in 12.1 unreachable
            -- for the rest of the resource's life.
            positions[1] = { x = 5000.0, y = 5000.0, z = 30.0 }
            casing(10.0, 'SN-1')

            grid.push(1)

            assert.are.equal(0, #pushes)
            assert.are.equal(0, grid.stats().subscribers)
        end)

        it('drops a subscriber once the last thing it drew is retracted', function()
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            local trace = casing(10.0, 'SN-1')
            grid.push(1)

            assert.are.equal(1, grid.stats().subscribers)

            grid.take(trace.key)
            grid.push(1)

            assert.are.equal(0, grid.stats().subscribers)
        end)

        it('makes no subscriber of a player standing over a latent trace', function()
            -- Nothing has been sent, so there is nothing to retract, so there is
            -- nothing to remember -- and a print nobody has dusted must not cost
            -- 200 players a subscription each.
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            grid.place({ type = 'print', x = 10.0, y = 10.0, z = 30.0, owner = { identifier = 'char1' } })
            grid.push(1)

            assert.are.equal(0, #pushes)
            assert.are.equal(0, grid.stats().subscribers)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Latent traces and privilege (8.4, 8.11)
    -- -------------------------------------------------------------------------

    describe('revealed latent traces', function()
        it('reaches an officer with tools and nobody else', function()
            -- The suspect standing next to the officer must not learn which of
            -- their prints the powder found (8.11).
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }
            positions[2] = { x = 10.0, y = 10.0, z = 30.0 }
            sessions[2] = helper.session({ src = 2, permissions = { 'forensics.tools.use' } })

            local latent = grid.place({
                type = 'print', x = 10.0, y = 10.0, z = 30.0, owner = { identifier = 'char1' },
            })

            assert.are.equal(1, grid.reveal(10.0, 10.0, 30.0, 4.0, 'powder'))

            grid.push(1)
            grid.push(2)

            assert.is_nil(drawing(1)[latent.key])
            assert.is_true(drawing(2)[latent.key])
        end)

        it('does not tell an unprivileged client that a print has been created', function()
            -- The oracle, half of it (8.11). The player is already a subscriber,
            -- because there is a casing at their feet, so "they were sent
            -- nothing" is a claim about this change and not about their being
            -- near evidence at all. A latent print landing next to them changes
            -- only a list they may never be shown, so the second push must be
            -- silent -- otherwise the tick itself says a print was just left.
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            casing(10.0, 'SN-1')
            grid.push(1)

            assert.are.equal(1, messages(1))

            grid.place({ type = 'print', x = 10.0, y = 10.0, z = 30.0, owner = { identifier = 'char1' } })
            grid.push(1)

            assert.are.equal(1, messages(1))
        end)

        it('does not tell an unprivileged client that an officer is dusting', function()
            -- The other half, and the worse one: a criminal watching for the
            -- tick learns that the scene they left is being processed, without
            -- clearance, without a tool and from across the street.
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            local visible = casing(10.0, 'SN-1')
            grid.place({ type = 'print', x = 10.0, y = 10.0, z = 30.0, owner = { identifier = 'char1' } })
            grid.push(1)

            assert.are.equal(1, messages(1))
            assert.is_true(drawing(1)[visible.key])

            assert.are.equal(1, grid.reveal(10.0, 10.0, 30.0, 4.0, 'powder'))
            grid.push(1)

            assert.are.equal(1, messages(1), 'revealing a print must be silent to a client who may not see it')
        end)

        it('still tells the officer who dusted, in the same cell', function()
            -- The suppression must be about the tier and not about the cell:
            -- the officer standing over the same casing is told about the print
            -- on the very next push.
            positions[2] = { x = 10.0, y = 10.0, z = 30.0 }
            sessions[2] = helper.session({ src = 2, permissions = { 'forensics.tools.use' } })

            casing(10.0, 'SN-1')
            local latent = grid.place({
                type = 'print', x = 10.0, y = 10.0, z = 30.0, owner = { identifier = 'char1' },
            })

            grid.push(2)

            assert.are.equal(1, messages(2))
            assert.is_nil(drawing(2)[latent.key])

            grid.reveal(10.0, 10.0, 30.0, 4.0, 'powder')
            grid.push(2)

            assert.are.equal(2, messages(2))
            assert.is_true(drawing(2)[latent.key])
        end)

        it('still tells an unprivileged client about a casing in a cell being worked', function()
            -- The suppression must not swallow a change they *may* see because
            -- something else in the cell moved in the same second.
            positions[1] = { x = 10.0, y = 10.0, z = 30.0 }

            casing(10.0, 'SN-1')
            grid.place({ type = 'print', x = 10.0, y = 10.0, z = 30.0, owner = { identifier = 'char1' } })
            grid.push(1)

            grid.reveal(10.0, 10.0, 30.0, 4.0, 'powder')
            local second = casing(10.4, 'SN-2')
            grid.push(1)

            assert.are.equal(2, messages(1))
            assert.is_true(drawing(1)[second.key])
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Cleaned traces (8.10) -- what must not be laundered into them
    -- -------------------------------------------------------------------------

    describe('blood dropped where blood was cleaned', function()
        local function blood(x)
            return grid.place({ type = 'blood', x = x, y = 0.0, z = 0.0, owner = { identifier = 'char1' } })
        end

        it('does not fold the fresh trace into the cleaned one', function()
            -- The laundering: same type, same person, a tenth of a metre apart
            -- and well inside the merge radius. Folding them hands the new blood
            -- the old pool's `cleaned` -- a quarter of the DNA yield -- and its
            -- invisibility, for the price of having mopped an hour ago.
            local pool = blood(0.0)

            assert.is_true(grid.clean(pool.key))

            local fresh = blood(0.1)

            assert.are_not.equal(pool.key, fresh.key)
            assert.are.equal(2, grid.stats().items)
            assert.are.equal(0, grid.stats().merged)

            assert.is_false(fresh.cleaned)
            assert.is_false(fresh.latent)

            -- And the cleaned pool is still cleaned: it did not get washed of
            -- its own penalty by somebody bleeding on it either.
            local cleaned = grid.peek(pool.key)

            assert.is_true(cleaned.cleaned)
            assert.is_true(cleaned.latent)
            assert.are.equal(1, cleaned.count)
        end)

        it('leaves the fresh blood visible to anybody standing there', function()
            positions[1] = { x = 0.0, y = 0.0, z = 0.0 }

            local pool = blood(0.0)
            grid.clean(pool.key)

            local fresh = blood(0.1)
            grid.push(1)

            assert.is_true(drawing(1)[fresh.key], 'fresh blood must not inherit a cleaned pool\'s invisibility')
            assert.is_nil(drawing(1)[pool.key])
        end)

        it('still folds two fresh pools into one', function()
            -- The merge itself is not what was wrong (8.3.5): same type, same
            -- owner, same state, half a metre apart is still one trace.
            local first = blood(0.0)
            local second = blood(0.1)

            assert.are.equal(first.key, second.key)
            assert.are.equal(2, second.count)
            assert.are.equal(1, grid.stats().items)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- The per-cell cap (12.2)
    -- -------------------------------------------------------------------------

    describe('the per-cell cap', function()
        it('keeps the item count honest when a full cell swaps its oldest out', function()
            load({ maxPerCell = 3 })

            local keys = {}

            for index = 1, 4 do
                clock = clock + 1
                keys[index] = casing(1.0 + index * 2).key
            end

            -- Three in the cell, and three is what the grid believes it holds.
            -- Counting the swap as an arrival walks the count away from the
            -- truth until the world cap refuses traces there is room for.
            assert.are.equal(3, grid.stats().items)

            -- The evicted key names nothing any more, in either direction.
            assert.is_nil(grid.peek(keys[1]))
            assert.is_nil(grid.take(keys[1]))

            for index = 2, 4 do
                assert.is_not_nil(grid.take(keys[index]))
            end

            assert.are.equal(0, grid.stats().items)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Destruction (8.10)
    -- -------------------------------------------------------------------------

    describe('wipeAround', function()
        local prints, gloves, blood, far

        before_each(function()
            prints = grid.place({ type = 'print', x = 0.0, y = 0.0, z = 0.0, owner = { identifier = 'char1' } })
            gloves = grid.place({ type = 'glove_mark', x = 1.0, y = 0.0, z = 0.0, owner = { identifier = 'char2' } })
            blood = grid.place({ type = 'blood', x = 0.5, y = 0.0, z = 0.0, owner = { identifier = 'char3' } })
            far = grid.place({ type = 'print', x = 20.0, y = 0.0, z = 0.0, owner = { identifier = 'char4' } })
        end)

        it('removes only the named types', function()
            assert.are.equal(1, grid.wipeAround(0.0, 0.0, 0.0, 5.0, { print = true }))

            assert.is_nil(grid.peek(prints.key))
            assert.is_not_nil(grid.peek(gloves.key))
            assert.is_not_nil(grid.peek(blood.key))
        end)

        it('removes only what is inside the radius', function()
            -- The far print is in the same grid cell, which is what makes this
            -- worth asserting: the cell is the search unit, the radius is the
            -- rule.
            assert.are.equal(1, grid.wipeAround(0.0, 0.0, 0.0, 5.0, { print = true }))

            assert.is_not_nil(grid.peek(far.key))
        end)

        it('removes every named type in one pass and counts them', function()
            assert.are.equal(2, grid.wipeAround(0.0, 0.0, 0.0, 5.0, { print = true, glove_mark = true }))
            assert.are.equal(2, grid.stats().items)
        end)

        it('keeps the count and the lookup honest', function()
            grid.wipeAround(0.0, 0.0, 0.0, 5.0, { print = true, glove_mark = true })

            assert.are.equal(2, grid.stats().items)
            assert.are.equal(2, grid.stats().destroyed)
            assert.is_nil(grid.take(prints.key))
            assert.are.equal(2, grid.stats().items)
        end)

        it('removes nothing when nothing matches', function()
            assert.are.equal(0, grid.wipeAround(0.0, 0.0, 0.0, 5.0, { casing = true }))
            assert.are.equal(0, grid.wipeAround(500.0, 500.0, 0.0, 5.0, { print = true }))
            assert.are.equal(4, grid.stats().items)
        end)

        it('is not what cleaning blood does', function()
            -- 8.10 in one assertion. Cleaning leaves the blood in the world,
            -- invisible and marked, for luminol to find at a reduced yield;
            -- wiping a print leaves nothing at all. A cleaning chemical routed
            -- through `wipeAround` would delete the evidence outright and quietly
            -- remove the only counter-mechanic the section has.
            assert.is_true(grid.clean(blood.key))

            local cleaned = grid.peek(blood.key)

            assert.is_not_nil(cleaned)
            assert.is_true(cleaned.cleaned)
            assert.is_true(cleaned.latent)
            assert.is_false(cleaned.revealed)
        end)

        it('tells a client drawing a wiped trace that it is gone', function()
            positions[1] = { x = 0.0, y = 0.0, z = 0.0 }

            grid.reveal(0.0, 0.0, 0.0, 4.0, 'powder')
            sessions[1] = helper.session({ src = 1, permissions = { 'forensics.tools.use' } })
            grid.push(1)

            assert.is_true(drawing(1)[prints.key])

            grid.wipeAround(0.0, 0.0, 0.0, 5.0, { print = true, glove_mark = true })
            grid.push(1)

            assert.is_nil(drawing(1)[prints.key])
        end)
    end)

    describe('takeNear', function()
        local near, alsoNear, blood, far

        before_each(function()
            near = grid.place({ type = 'casing', x = 0.0, y = 0.0, z = 0.0, owner = { weaponSerial = 'SN-1' } })
            alsoNear = grid.place({ type = 'casing', x = 2.0, y = 0.0, z = 0.0, owner = { weaponSerial = 'SN-1' } })
            blood = grid.place({ type = 'blood', x = 1.0, y = 0.0, z = 0.0, owner = { identifier = 'char1' } })
            far = grid.place({ type = 'casing', x = 12.0, y = 0.0, z = 0.0, owner = { weaponSerial = 'SN-1' } })
        end)

        it('picks up the casings on the ground without anybody naming a key', function()
            -- The blind half of 8.10: the player targeted the ground, and the
            -- brass may never have been in their streaming range, so there is no
            -- key to pass.
            assert.are.equal(2, grid.takeNear(0.0, 0.0, 0.0, 3.0, { casing = true, magazine = true }))

            assert.is_nil(grid.peek(near.key))
            assert.is_nil(grid.peek(alsoNear.key))
        end)

        it('leaves the types it was not asked for', function()
            grid.takeNear(0.0, 0.0, 0.0, 3.0, { casing = true, magazine = true })

            assert.is_not_nil(grid.peek(blood.key))
        end)

        it('leaves what is out of reach', function()
            grid.takeNear(0.0, 0.0, 0.0, 3.0, { casing = true })

            assert.is_not_nil(grid.peek(far.key))
        end)

        it('keeps the count honest', function()
            grid.takeNear(0.0, 0.0, 0.0, 3.0, { casing = true })

            assert.are.equal(2, grid.stats().items)
            assert.are.equal(2, grid.stats().destroyed)
        end)

        it('answers zero rather than failing on a set it cannot read', function()
            assert.are.equal(0, grid.takeNear(0.0, 0.0, 0.0, 3.0, nil))
            assert.are.equal(4, grid.stats().items)
        end)
    end)

    describe('destroy', function()
        --- The keyed half of 8.10: the player could see the casing and named it.
        local function casingAt(x)
            return grid.place({ type = 'casing', x = x, y = 0.0, z = 0.0, owner = { weaponSerial = 'SN-1' } })
        end

        it('removes the trace it names', function()
            local trace = casingAt(0.0)

            local removed = grid.destroy(trace.key)

            assert.is_not_nil(removed)
            assert.are.equal(trace.key, removed.key)
            assert.is_nil(grid.peek(trace.key))
            assert.are.equal(0, grid.stats().items)
        end)

        it('books a destruction and never a collection', function()
            -- The whole reason it exists (12.3). The destroy route writes no
            -- audit row -- there is no session to attribute one to -- so this
            -- counter is the only signal a server has that evidence is being
            -- carried away, and `Grid.take` would file thirty pocketed casings
            -- as thirty officers' worth of bagged brass.
            for index = 1, 3 do
                grid.destroy(casingAt(index * 2.0).key)
            end

            assert.are.equal(3, grid.stats().destroyed)
            assert.are.equal(0, grid.stats().collected)
        end)

        it('leaves collection counting collections', function()
            grid.take(casingAt(0.0).key)

            assert.are.equal(1, grid.stats().collected)
            assert.are.equal(0, grid.stats().destroyed)
        end)

        it('moves no counter for a key that names nothing', function()
            assert.is_nil(grid.destroy('nothing'))

            assert.are.equal(0, grid.stats().destroyed)
            assert.are.equal(0, grid.stats().collected)
        end)

        it('tells a client drawing it that it is gone', function()
            positions[1] = { x = 0.0, y = 0.0, z = 0.0 }

            local trace = casingAt(0.0)
            grid.push(1)

            assert.is_true(drawing(1)[trace.key])

            grid.destroy(trace.key)
            grid.push(1)

            assert.is_nil(drawing(1)[trace.key])
            assert.are.equal(0, grid.stats().subscribers)
        end)

        it('does not leave the key behind for a second removal', function()
            local trace = casingAt(0.0)

            assert.is_not_nil(grid.destroy(trace.key))
            assert.is_nil(grid.destroy(trace.key))
            assert.is_nil(grid.take(trace.key))

            assert.are.equal(1, grid.stats().destroyed)
            assert.are.equal(0, grid.stats().collected)
            assert.are.equal(0, grid.stats().items)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Stale lookups (the `touch(nil)` that used to be reachable)
    -- -------------------------------------------------------------------------

    describe('a key that names nothing', function()
        it('is refused by every entry point instead of throwing', function()
            assert.is_nil(grid.peek('nothing'))
            assert.is_nil(grid.take('nothing'))
            assert.is_false(grid.clean('nothing'))
        end)

        it('is refused after the trace it named was destroyed', function()
            local trace = grid.place({ type = 'print', x = 0.0, y = 0.0, z = 0.0, owner = { identifier = 'char1' } })

            grid.wipeAround(0.0, 0.0, 0.0, 5.0, { print = true })

            assert.is_false(grid.clean(trace.key))
            assert.is_nil(grid.take(trace.key))
        end)
    end)
end)

-- -----------------------------------------------------------------------------
-- Gunshot residue (8.2, 8.10)
-- -----------------------------------------------------------------------------

describe('gunshot residue', function()
    local gsr, clock, saved, realTime
    local osLib = os

    local function load(overrides)
        local fredpd = helper.load({
            'server/modules/evidence/service',
            'server/modules/forensics/service',
        })

        fredpd.Config = { server = { forensics = overrides } }
        fredpd.Core = { push = {}, session = { all = function() return {} end }, perms = {} }
        fredpd.markArrays = function(value) return value end

        assert(loadfile('resources/[fredpd]/fredpd/server/modules/forensics/grid.lua'))()
        assert(loadfile('resources/[fredpd]/fredpd/server/modules/forensics/gsr.lua'))()

        gsr = fredpd.Forensics.gsr
    end

    before_each(function()
        saved = {}
        for index = 1, #NATIVES do saved[NATIVES[index]] = _G[NATIVES[index]] end

        realTime = osLib.time
        clock = 1700000000
        osLib.time = function() return clock end

        _G.AddEventHandler = function() end
        _G.CreateThread = function() end
        _G.Wait = function() end
        _G.GetPlayers = function() return {} end
        _G.GetPlayerPed = function() return 0 end
        _G.GetEntityCoords = function() return nil end

        load(nil)
    end)

    after_each(function()
        for index = 1, #NATIVES do _G[NATIVES[index]] = saved[NATIVES[index]] end
        osLib.time = realTime
    end)

    it('finds nothing on a player who has not fired', function()
        local present, level = gsr.present(7)

        assert.is_false(present)
        assert.are.equal(0, level)
    end)

    it('marks a shooter, at full strength', function()
        gsr.mark(7)

        local present, level = gsr.present(7)

        assert.is_true(present)
        assert.are.equal(100, level)
    end)

    it('fades with time rather than at a cliff edge', function()
        gsr.mark(7)

        clock = clock + 3600

        local present, level = gsr.present(7)

        assert.is_true(present)
        -- Half a point a minute, so an hour costs thirty. A swab an hour later
        -- is a weaker result, not an identical one (8.7).
        assert.are.equal(70, level)
    end)

    it('is gone once its lifetime is up', function()
        load({ gsrDecayPerMinute = 0 })

        gsr.mark(7)

        clock = clock + 4 * 3600 - 1
        assert.is_true((gsr.present(7)))

        clock = clock + 1
        assert.is_false((gsr.present(7)))
    end)

    it('washes off, once', function()
        -- 8.10: washing at a sink destroys it. The answer is what the route
        -- turns into "you scrub your hands" or a refusal.
        gsr.mark(7)

        assert.is_true(gsr.clear(7))
        assert.is_false(gsr.clear(7))
        assert.is_false((gsr.present(7)))
    end)

    it('tells a player whose residue had already decayed that there was none', function()
        -- Otherwise the sink is a detector: a suspect could wash to find out
        -- whether a swab would have found anything (8.11).
        gsr.mark(7)

        clock = clock + 5 * 3600

        assert.is_false(gsr.clear(7))
    end)

    it('is refreshed by firing again rather than accumulated', function()
        gsr.mark(7)

        clock = clock + 3600
        gsr.mark(7)

        local _, level = gsr.present(7)

        assert.are.equal(100, level)
    end)

    it('is per player', function()
        gsr.mark(7)

        assert.is_true((gsr.present(7)))
        assert.is_false((gsr.present(8)))
    end)

    it('is forgotten when the player drops', function()
        gsr.mark(7)
        gsr.forget(7)

        assert.is_false((gsr.present(7)))
    end)

    it('takes its decay from the server configuration', function()
        load({ gsrDecayPerMinute = 10 })

        gsr.mark(7)
        clock = clock + 600

        assert.is_false((gsr.present(7)))
    end)
end)
