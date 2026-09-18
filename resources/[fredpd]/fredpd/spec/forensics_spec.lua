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
    local forensics

    before_each(function()
        -- The evidence service comes first: `placeIn` merges through
        -- `evidence.shouldMerge`, which is the one definition of "these are the
        -- same trace" and is deliberately not restated in the forensics service.
        local fredpd = helper.load({
            'server/modules/evidence/service',
            'server/modules/forensics/service',
        })

        forensics = fredpd.Modules.forensics
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

    describe('dueForPush', function()
        it('always pushes a cell a client has never been sent', function()
            assert.is_true(forensics.dueForPush(nil, 1000, 1))
        end)

        it('holds a client to one update per second per cell', function()
            -- Spec 12.1, as an acceptance criterion rather than a property of
            -- how often a loop happens to run.
            assert.is_false(forensics.dueForPush(1000, 1000.5, 1))
            assert.is_true(forensics.dueForPush(1000, 1001, 1))
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
    end)
end)
