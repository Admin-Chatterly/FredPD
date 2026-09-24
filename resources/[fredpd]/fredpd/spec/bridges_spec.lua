--- The pure parts of the bridges (spec 3.8, 15).
---
--- A bridge is mostly natives, and mostly untestable here for that reason. The
--- shape normalisation in the appearance bridge is the exception: it is the one
--- piece with no native in it, and it is the piece where being wrong is silent.
--- It answers with *a* garment whatever shape it is handed, so a wrong answer
--- does not error, does not print and does not show up anywhere except in the
--- type of the trace a touch leaves an hour later.

local helper = require('spec.helper')

describe('appearance bridge', function()
    local Appearance

    before_each(function()
        Appearance = helper.load({ 'server/bridges/appearance' }).Bridge.appearance
    end)

    --- Component 3 is the arms, component 6 the feet.
    local ARMS <const> = 3
    local FEET <const> = 6

    describe('component, list shape', function()
        --- What illenium-appearance and fivem-appearance actually hand back: a
        --- list whose entries name their own component id, in no particular
        --- order and not one entry per id.
        local function listShape()
            return {
                components = {
                    { component_id = 0, drawable = 1, texture = 0 },
                    { component_id = 1, drawable = 2, texture = 1 },
                    { component_id = 2, drawable = 3, texture = 2 },
                    { component_id = 4, drawable = 4, texture = 3 },
                    { component_id = 6, drawable = 55, texture = 4 },
                    { component_id = 3, drawable = 77, texture = 5 },
                    { component_id = 8, drawable = 6, texture = 6 },
                    { component_id = 11, drawable = 7, texture = 7 },
                },
            }
        end

        it('reads the entry whose component_id matches, not the one at that index', function()
            local arms = Appearance.component(listShape(), ARMS, 'arms')

            -- The third entry in the list is component 2, drawable 3. Reading
            -- the list as if it were keyed by component id returns that, and
            -- every glove verdict on this server is then about somebody's
            -- t-shirt.
            assert.are.same({ drawable = 77, texture = 5 }, arms)
        end)

        it('reads footwear out of the same list', function()
            assert.are.same({ drawable = 55, texture = 4 }, Appearance.component(listShape(), FEET, 'shoes'))
        end)

        it('answers nil when the list carries no such component', function()
            local appearance = { components = { { component_id = 1, drawable = 2, texture = 0 } } }

            assert.is_nil(Appearance.component(appearance, ARMS, 'arms'))
        end)

        it('accepts the list unwrapped, without a components key', function()
            local arms = Appearance.component(listShape().components, ARMS, 'arms')

            assert.are.same({ drawable = 77, texture = 5 }, arms)
        end)

        it('defaults a missing texture to zero', function()
            local appearance = { components = { { component_id = 3, drawable = 12 } } }

            assert.are.same({ drawable = 12, texture = 0 }, Appearance.component(appearance, ARMS, 'arms'))
        end)

        it('answers nil for a matching entry that carries no drawable', function()
            -- A missing drawable is not drawable 0. Zero is a real garment, so
            -- answering it would be inventing what the resource declined to
            -- say -- and inventing it in the direction that matters: a
            -- fabricated arms drawable is a glove verdict about nothing, where
            -- nil is the "do not know" every caller degrades safely on.
            local appearance = { components = { { component_id = 3, texture = 2 } } }

            assert.is_nil(Appearance.component(appearance, ARMS, 'arms'))
        end)

        it('keeps looking past a matching entry with no drawable', function()
            local appearance = {
                components = {
                    { component_id = 3, texture = 2 },
                    { component_id = 3, drawable = 12, texture = 1 },
                },
            }

            assert.are.same({ drawable = 12, texture = 1 }, Appearance.component(appearance, ARMS, 'arms'))
        end)
    end)

    describe('component, keyed shape', function()
        local function keyedShape()
            return {
                components = {
                    [0] = { drawable = 1, texture = 0 },
                    [1] = { drawable = 2, texture = 0 },
                    [3] = { drawable = 12, texture = 2 },
                    [6] = { drawable = 34, texture = 1 },
                },
            }
        end

        it('reads the component id as a key', function()
            assert.are.same({ drawable = 12, texture = 2 }, Appearance.component(keyedShape(), ARMS, 'arms'))
            assert.are.same({ drawable = 34, texture = 1 }, Appearance.component(keyedShape(), FEET, 'shoes'))
        end)

        it('answers nil when the map has no such component', function()
            assert.is_nil(Appearance.component({ components = { [1] = { drawable = 2 } } }, ARMS, 'arms'))
        end)

        it('reads a map that happens to have a component 1, which a list also has an index 1', function()
            -- The gate between the two shapes cannot be "does index 1 exist":
            -- component 1 is the mask, and a map keyed by component id has one.
            local appearance = { components = { [1] = { drawable = 5 }, [3] = { drawable = 12 } } }

            assert.are.same({ drawable = 12, texture = 0 }, Appearance.component(appearance, ARMS, 'arms'))
        end)
    end)

    describe('component, ESX flat skin', function()
        it('reads the flat key and its _2 texture', function()
            local skin = { arms = 5, arms_2 = 3, shoes = 9, shoes_2 = 1 }

            assert.are.same({ drawable = 5, texture = 3 }, Appearance.component(skin, ARMS, 'arms'))
            assert.are.same({ drawable = 9, texture = 1 }, Appearance.component(skin, FEET, 'shoes'))
        end)

        it('defaults the texture to zero when only the drawable is stored', function()
            assert.are.same({ drawable = 5, texture = 0 }, Appearance.component({ arms = 5 }, ARMS, 'arms'))
        end)

        it('answers nil without a flat key to look under', function()
            assert.is_nil(Appearance.component({ arms = 5 }, ARMS, nil))
        end)
    end)

    describe('component, nothing to read', function()
        it('answers nil for a non-table appearance', function()
            assert.is_nil(Appearance.component(nil, ARMS, 'arms'))
            assert.is_nil(Appearance.component('mp_m_freemode_01', ARMS, 'arms'))
        end)

        it('answers nil for an empty appearance', function()
            assert.is_nil(Appearance.component({}, ARMS, 'arms'))
            assert.is_nil(Appearance.component({ components = {} }, ARMS, 'arms'))
        end)

        it('answers nil for a list whose entries all name some other component', function()
            -- Every entry names a component id, so the list branch is the one
            -- that runs and the keyed branch stays off -- and none of them is
            -- the arms, so there is nothing to answer with. The entries carry
            -- no drawable either, which is not what this case is about: see
            -- "answers nil for a matching entry that carries no drawable"
            -- above for that.
            local appearance = { components = { { component_id = 9 }, { component_id = 10 } } }

            assert.is_nil(Appearance.component(appearance, ARMS, 'arms'))
        end)
    end)
end)

describe('framework bridge, garage state', function()
    local Framework, executed, rows

    before_each(function()
        executed = {}
        rows = {}
        local ns = helper.load({ 'server/bridges/framework' })
        ns.Config = { server = { esxData = { vehicles = {
            table = 'owned_vehicles', plate = 'plate', owner = 'owner', stored = 'stored',
            vehicleColumn = 'vehicle', vehicleJson = true,
        } } } }
        ns.Core = {
            db = {
                query = function(query, values)
                    executed[#executed + 1] = { query = query, values = values }
                    return rows
                end,
                execute = function(query, values)
                    executed[#executed + 1] = { query = query, values = values }
                    return 1
                end,
            },
        }
        Framework = ns.Bridge.framework
    end)

    it('finds the one owned car a drawn plate belongs to, exactly', function()
        rows = { { plate = 'AB 123', owner = 'char1:x', model = '123' } }

        local owned = Framework.ownedVehicleExact('AB 123  ')

        assert.are.equal('char1:x', owned.owner)
        -- Drawn and trimmed only: never the normalised "AB123", which is
        -- somebody else's plate.
        assert.are.same({ 'AB 123  ', 'AB 123', 'AB 123  ', 'AB 123' }, executed[1].values)
        assert.truthy(executed[1].query:find('BINARY', 1, true))
    end)

    it('answers nothing when the plate matches more than one car', function()
        rows = { { plate = 'AB 123' }, { plate = 'ab 123' } }

        assert.is_nil(Framework.ownedVehicleExact('AB 123'))
    end)

    it('sets the garage state on that row only, and only from the expected state', function()
        assert.is_true(Framework.setVehicleStored('AB 123', 1, { is = 2 }))

        local call = executed[1]
        assert.truthy(call.query:find('UPDATE `owned_vehicles` SET `stored` = ?', 1, true))
        assert.truthy(call.query:find('AND `stored` = ?', 1, true))
        assert.are.same({ 1, 'AB 123', 'AB 123', 2 }, call.values)
    end)

    it('can refuse to overwrite a car already back in its garage', function()
        assert.is_true(Framework.setVehicleStored('AB 123', 2, { isnt = 1 }))

        assert.truthy(executed[1].query:find('AND `stored` <> ?', 1, true))
        assert.are.same({ 2, 'AB 123', 'AB 123', 1 }, executed[1].values)
    end)

    it('does nothing when the stored column is switched off', function()
        FredPD.Config.server.esxData.vehicles.stored = nil

        assert.is_false(Framework.setVehicleStored('AB123', 2))
        assert.are.equal(0, #executed)
    end)

    it('refuses a column name that is not a plain identifier, at startup', function()
        FredPD.Config.server.esxData.vehicles.stored = 'stored = 1, owner'
        _G.GetResourceState = function() return 'started' end

        assert.has_error(function() Framework.verify() end)
    end)
end)

describe('impound service, model check', function()
    local Impound

    before_each(function()
        Impound = helper.load({ 'server/modules/impound/service' }).Modules.impound
    end)

    it('matches the same hash stored signed and read unsigned', function()
        assert.is_true(Impound.sameModel(-1216765807, 3078201489))
        assert.is_true(Impound.sameModel('3078201489', 3078201489))
    end)

    it('refuses a different model, or one it cannot read', function()
        assert.is_false(Impound.sameModel(123, 124))
        assert.is_false(Impound.sameModel(nil, 124))
        assert.is_false(Impound.sameModel('adder', 124))
    end)
end)
