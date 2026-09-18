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

        it('answers nil for a list of entries that carry no drawable at all', function()
            local appearance = { components = { { component_id = 9 }, { component_id = 10 } } }

            assert.is_nil(Appearance.component(appearance, ARMS, 'arms'))
        end)
    end)
end)
