--- Locations and premises (spec 7.6): the geometry and the clock.

local helper = require('spec.helper')

describe('locations service', function()
    local L

    before_each(function()
        L = helper.load({ 'server/modules/locations/service' }).Modules.locations
    end)

    it('keeps an address trimmed, with one space between words', function()
        assert.are.equal('12 Alta Street', L.normalizeLabel('  12   Alta  Street '))
        assert.is_nil(L.normalizeLabel('   '))
        assert.is_nil(L.normalizeLabel(nil))
    end)

    it('matches an address typed on a phone call, whatever the case', function()
        assert.is_true(L.sameLabel('12 alta street', '12 Alta  Street'))
        assert.is_false(L.sameLabel('12 Alta Street', '14 Alta Street'))
        assert.is_false(L.sameLabel(nil, '12 Alta Street'))
    end)

    it('puts a call at a premise when it is inside the radius', function()
        local premise = { x = 100, y = 100, radius = 30 }

        assert.is_true(L.contains(premise, { x = 120, y = 110 }))
        assert.is_false(L.contains(premise, { x = 140, y = 100 }))
    end)

    it('measures the circle, not the square', function()
        -- Inside the bounding square the repo searches, outside the circle.
        assert.is_false(L.contains({ x = 0, y = 0, radius = 30 }, { x = 25, y = 25 }))
    end)

    it('never puts a call at a premise that has no position', function()
        assert.is_false(L.contains({ radius = 30 }, { x = 0, y = 0 }))
        assert.is_false(L.contains({ x = 0, y = 0, radius = 30 }, {}))
    end)

    it('uses the default radius when none is set', function()
        assert.is_true(L.contains({ x = 0, y = 0 }, { x = L.DEFAULT_RADIUS, y = 0 }))
        assert.is_false(L.contains({ x = 0, y = 0 }, { x = L.DEFAULT_RADIUS + 1, y = 0 }))
    end)

    it('keeps a hazard standing until it is cancelled or lapses', function()
        assert.is_true(L.isLive({}, 1000))
        assert.is_true(L.isLive({ expiresAt = 2000 }, 1000))
        assert.is_false(L.isLive({ expiresAt = 1000 }, 1000))
        assert.is_false(L.isLive({ cancelledAt = 500 }, 1000))
    end)

    it('finds the premises a call is at, by position or by address, once each', function()
        local near = { id = 1, label = '12 Alta Street', x = 0, y = 0, radius = 30 }
        local far = { id = 2, label = 'Vinewood Bowl', x = 400, y = 0, radius = 30 }
        local byText = { id = 3, label = 'Pillbox Hill Medical', radius = 30 }

        local found = L.premisesFor({ near, far, byText, near },
            { x = 10, y = 0, locationText = 'pillbox hill medical' })

        assert.are.equal(2, #found)
        assert.are.equal(1, found[1].id)
        assert.are.equal(3, found[2].id)
    end)
end)
