--- Motor pool (spec 7.31).
---
--- The fleet filter decides which vehicles an officer is offered *and* which
--- they may actually draw. Both answers come from the same function on the
--- server, so a client asking for a vehicle it was never shown still fails.

local helper = require('spec.helper')

describe('garage', function()
    local garage

    before_each(function()
        garage = helper.load({ 'server/modules/garage/service' }).Modules.garage
    end)

    local fleet = {
        { model = 'police', labelKey = 'fleet.cruiser', enabled = true },
        { model = 'police2', labelKey = 'fleet.interceptor', permission = 'garage.pursuit', enabled = true },
        { model = 'polmav', labelKey = 'fleet.helicopter', certification = 'air', enabled = true },
        { model = 'riot', labelKey = 'fleet.riot', permission = 'garage.tactical', certification = 'tactical', enabled = true },
        { model = 'police4', labelKey = 'fleet.unmarked', enabled = false },
    }

    local function grants(...)
        local held = {}
        for _, permission in ipairs({ ... }) do held[permission] = true end

        return function(permission) return held[permission] == true end
    end

    local function certified(...)
        local held = {}
        for _, name in ipairs({ ... }) do held[name] = true end
        return held
    end

    describe('allowedFleet', function()
        it('offers the unrestricted vehicles to any officer', function()
            local allowed = garage.allowedFleet(fleet, grants(), certified())

            assert.are.equal(1, #allowed)
            assert.are.equal('police', allowed[1].model)
        end)

        it('offers a permission-gated vehicle once the permission is held', function()
            local allowed = garage.allowedFleet(fleet, grants('garage.pursuit'), certified())

            assert.are.equal(2, #allowed)
        end)

        it('withholds a vehicle whose certification the officer lacks', function()
            local allowed = garage.allowedFleet(fleet, grants(), certified())

            for index = 1, #allowed do
                assert.are_not.equal('polmav', allowed[index].model)
            end
        end)

        it('offers it once the certification is held', function()
            local allowed = garage.allowedFleet(fleet, grants(), certified('air'))
            local models = {}
            for index = 1, #allowed do models[allowed[index].model] = true end

            assert.is_true(models.polmav)
        end)

        it('requires both when an entry demands a permission and a certification', function()
            local permissionOnly = garage.allowedFleet(fleet, grants('garage.tactical'), certified())
            local certificationOnly = garage.allowedFleet(fleet, grants(), certified('tactical'))
            local both = garage.allowedFleet(fleet, grants('garage.tactical'), certified('tactical'))

            local function includes(list, model)
                for index = 1, #list do
                    if list[index].model == model then return true end
                end
                return false
            end

            assert.is_false(includes(permissionOnly, 'riot'))
            assert.is_false(includes(certificationOnly, 'riot'))
            assert.is_true(includes(both, 'riot'))
        end)

        it('never offers a disabled entry', function()
            local allowed = garage.allowedFleet(fleet, grants('garage.pursuit', 'garage.tactical'), certified('air', 'tactical'))

            for index = 1, #allowed do
                assert.are_not.equal('police4', allowed[index].model)
            end
        end)
    end)

    describe('findAllowed', function()
        it('finds a vehicle the officer may draw', function()
            local entry = garage.findAllowed(fleet, 'police', grants(), certified())

            assert.is_not_nil(entry)
            assert.are.equal('police', entry.model)
        end)

        it('refuses a model the officer was never offered', function()
            -- The restriction is applied here, on the server, not by the menu
            -- that displayed it.
            assert.is_nil(garage.findAllowed(fleet, 'polmav', grants(), certified()))
            assert.is_nil(garage.findAllowed(fleet, 'police2', grants(), certified()))
        end)

        it('refuses a disabled model', function()
            assert.is_nil(garage.findAllowed(fleet, 'police4', grants(), certified()))
        end)

        it('refuses a model that is not in the fleet at all', function()
            assert.is_nil(garage.findAllowed(fleet, 'adder', grants(), certified()))
        end)
    end)

    describe('generatePlate', function()
        it('produces an 8 character plate', function()
            assert.are.equal(8, #garage.generatePlate('LSPD'))
        end)

        it('starts with the agency prefix', function()
            assert.are.equal('LSPD', garage.generatePlate('LSPD'):sub(1, 4))
        end)

        it('upper-cases the prefix', function()
            assert.are.equal('LSPD', garage.generatePlate('lspd'):sub(1, 4))
        end)

        it('still fills the plate when there is no prefix', function()
            assert.are.equal(8, #garage.generatePlate(''))
            assert.are.equal(8, #garage.generatePlate(nil))
        end)

        it('truncates a prefix that would leave no room for the random part', function()
            local plate = garage.generatePlate('VERYLONGAGENCY')

            assert.are.equal(8, #plate)
        end)
    end)
end)
