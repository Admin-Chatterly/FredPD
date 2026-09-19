--- Placements (spec 3.10, ADR-006).
---
--- The proximity rule is the control that makes access points mean anything: it
--- is what stops a client claiming to be standing in the property room. Worth
--- testing rather than trusting.

local helper = require('spec.helper')

describe('placements', function()
    local placements

    before_each(function()
        placements = helper.load({ 'server/modules/placements/service' }).Modules.placements
    end)

    local function at(x, y, z, radius)
        return { id = 1, kind = 'property_terminal', x = x, y = y, z = z, radius = radius or 1.5, enabled = true }
    end

    describe('isWithin', function()
        it('accepts a player standing on the placement', function()
            assert.is_true(placements.isWithin(at(100, 200, 30), 100, 200, 30))
        end)

        it('accepts a player just inside the radius', function()
            assert.is_true(placements.isWithin(at(100, 200, 30, 2.0), 101.5, 200, 30))
        end)

        it('refuses a player well outside it', function()
            assert.is_false(placements.isWithin(at(100, 200, 30, 1.5), 120, 200, 30))
        end)

        it('allows a little slack for latency', function()
            -- The player's position drifts between client and server; an officer
            -- at the counter should not be refused because of it.
            assert.is_true(placements.isWithin(at(100, 200, 30, 1.5), 102.0, 200, 30))
        end)

        it('does not allow enough slack to reach from outside the room', function()
            assert.is_false(placements.isWithin(at(100, 200, 30, 1.5), 105.0, 200, 30))
        end)

        it('measures height too, so a floor above does not count', function()
            assert.is_false(placements.isWithin(at(100, 200, 30, 1.5), 100, 200, 40))
        end)

        it('refuses a missing placement rather than erroring', function()
            assert.is_false(placements.isWithin(nil, 1, 2, 3))
        end)
    end)

    describe('isUsableBy', function()
        it('accepts a shared placement for any agency', function()
            local shared = at(1, 2, 3)
            shared.agencyId = nil

            assert.is_true(placements.isUsableBy(shared, 'lspd'))
        end)

        it('accepts an agency placement for that agency', function()
            local owned = at(1, 2, 3)
            owned.agencyId = 'lspd'

            assert.is_true(placements.isUsableBy(owned, 'lspd'))
        end)

        it('refuses another agency\'s placement', function()
            local owned = at(1, 2, 3)
            owned.agencyId = 'bcso'

            local ok, reason = placements.isUsableBy(owned, 'lspd')

            assert.is_false(ok)
            assert.are.equal('other_agency', reason)
        end)

        it('refuses a disabled placement', function()
            local off = at(1, 2, 3)
            off.enabled = false

            local ok, reason = placements.isUsableBy(off, 'lspd')

            assert.is_false(ok)
            assert.are.equal('disabled', reason)
        end)

        it('refuses a placement of the wrong kind', function()
            -- Standing at the motor pool does not satisfy "at the lab".
            local ok, reason = placements.isUsableBy(at(1, 2, 3), 'lspd', 'lab_terminal')

            assert.is_false(ok)
            assert.are.equal('wrong_kind', reason)
        end)

        it('refuses a missing placement', function()
            local ok, reason = placements.isUsableBy(nil, 'lspd')

            assert.is_false(ok)
            assert.are.equal('not_found', reason)
        end)
    end)

    describe('forClient', function()
        it('sends geometry and nothing about permissions', function()
            local placement = at(1, 2, 3)
            placement.agencyId = 'lspd'
            placement.createdBy = '100000000000000001'

            local payload = placements.forClient(placement)

            assert.are.equal(1, payload.x)
            assert.are.equal('property_terminal', payload.kind)
            -- A client knowing a door exists is not a client that can open it.
            assert.is_nil(payload.createdBy)
            assert.is_nil(payload.agencyId)
        end)
    end)

    describe('validate', function()
        it('requires a model for a prop placement', function()
            local err, fields = placements.validate({ interaction = 'prop' })

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.model)
        end)

        it('requires a model for a ped placement', function()
            local err = placements.validate({ interaction = 'ped' })

            assert.are.equal('invalid', err)
        end)

        it('rejects a model on a zone, which would imply an entity', function()
            local err, fields = placements.validate({ interaction = 'zone', model = 'prop_atm_01' })

            assert.are.equal('invalid', err)
            assert.are.equal('not_allowed', fields.model)
        end)

        it('accepts a well-formed placement', function()
            assert.is_nil(placements.validate({ interaction = 'zone' }))
            assert.is_nil(placements.validate({ interaction = 'ped', model = 's_m_y_cop_01' }))
        end)
    end)
end)
