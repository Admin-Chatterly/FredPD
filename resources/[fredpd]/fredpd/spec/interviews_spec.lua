--- Field interview cards (spec 7.14): the associate list and what a card needs.

local helper = require('spec.helper')

describe('interviews service', function()
    local I

    before_each(function()
        I = helper.load({ 'server/modules/interviews/service' }).Modules.interviews
    end)

    it('takes no associates as an empty list', function()
        assert.are.same({}, I.associateIds(nil, 1))
    end)

    it('turns the ids into integers, deduplicated, without the subject', function()
        assert.are.same({ 3, 7 }, I.associateIds({ '3', '7', '3', '1' }, 1))
    end)

    it('refuses anything that is not a list of positive whole numbers', function()
        assert.is_nil(I.associateIds('3', 1))
        assert.is_nil(I.associateIds({ 'x' }, 1))
        assert.is_nil(I.associateIds({ '0' }, 1))
        local ids, why = I.associateIds({ '2.5' }, 1)
        assert.is_nil(ids)
        assert.are.equal('format', why)
    end)

    it('refuses more associates than a card holds', function()
        local many = {}
        for index = 1, I.MAX_ASSOCIATES + 1 do many[index] = tostring(index + 1) end

        local ids, why = I.associateIds(many, 1)
        assert.is_nil(ids)
        assert.are.equal('too_many', why)
    end)

    it('needs a person, a vehicle or something written', function()
        assert.is_true(I.hasSubject({ personId = 1 }))
        assert.is_true(I.hasSubject({ vehicleId = 1 }))
        assert.is_true(I.hasSubject({ narrative = 'Seen at the pier.' }))
        assert.is_false(I.hasSubject({ narrative = '   ' }))
        assert.is_false(I.hasSubject({}))
    end)
end)
