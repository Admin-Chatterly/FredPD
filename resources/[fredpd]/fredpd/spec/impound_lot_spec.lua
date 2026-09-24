--- The impound lot (spec 7.15, 0037): which lots an agency has, which is
--- nearest a tow, and what counts as a lot at all.

local helper = require('spec.helper')

describe('impound lots', function()
    local I

    local placements = {
        [9] = { id = 9, kind = 'impound_lot', agencyId = 'lspd', enabled = true, x = 100, y = 0, z = 0 },
        [3] = { id = 3, kind = 'impound_lot', agencyId = nil, enabled = true, x = -500, y = 0, z = 0 },
        [4] = { id = 4, kind = 'impound_lot', agencyId = 'bcso', enabled = true, x = 0, y = 0, z = 0 },
        [5] = { id = 5, kind = 'impound_lot', agencyId = 'lspd', enabled = false, x = 0, y = 0, z = 0 },
        [6] = { id = 6, kind = 'station_terminal', agencyId = 'lspd', enabled = true, x = 0, y = 0, z = 0 },
    }

    local function usableBy(agencyId)
        return function(placement) return placement.agencyId == nil or placement.agencyId == agencyId end
    end

    before_each(function()
        I = helper.load({ 'server/modules/impound/service' }).Modules.impound
    end)

    it('lists an agency\'s enabled lots, shared ones included, each called by its own id', function()
        local lots = I.lots(placements, usableBy('lspd'))

        assert.are.equal(2, #lots)
        assert.are.same({ 3, 3 }, { lots[1].id, lots[1].number })
        assert.are.same({ 9, 9 }, { lots[2].id, lots[2].number })
    end)

    it('never offers another agency\'s lot, a disabled one, or a terminal', function()
        local lots = I.lots(placements, usableBy('lspd'))

        assert.is_false(I.isLot(lots, 4))
        assert.is_false(I.isLot(lots, 5))
        assert.is_false(I.isLot(lots, 6))
        assert.is_true(I.isLot(lots, 9))
    end)

    it('tows to the nearest lot', function()
        local lots = I.lots(placements, usableBy('lspd'))

        assert.are.equal(9, I.nearestLot(lots, { x = 80, y = 10, z = 0 }).id)
        assert.are.equal(3, I.nearestLot(lots, { x = -300, y = 0, z = 0 }).id)
    end)

    it('names no lot when the agency has none or there is no position', function()
        assert.is_nil(I.nearestLot({}, { x = 0, y = 0, z = 0 }))
        assert.is_nil(I.nearestLot(I.lots(placements, usableBy('lspd')), nil))
    end)

    it('keeps text trimmed and says nothing for blank', function()
        assert.are.equal('A3', I.text('  A3 '))
        assert.is_nil(I.text('   '))
        assert.is_nil(I.text(nil))
    end)
end)
