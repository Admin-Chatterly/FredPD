--- Input validation (spec 3.5, invariant 1).
---
--- The case that matters most is the last one: a field the schema does not
--- declare must never reach a handler, because that is how a client smuggles an
--- `officerId` into an input it does not own.

local helper = require('spec.helper')

describe('validate', function()
    local FredPD

    before_each(function()
        FredPD = helper.load({ 'shared/generated/schema', 'server/core/validate' })
    end)

    local function check(name, input)
        return FredPD.Core.validate.check(name, input)
    end

    it('accepts a well-formed input', function()
        local cleaned, fields = check('ChatSend', { body = 'suspect heading north on Alta' })

        assert.is_nil(fields)
        assert.are.equal('suspect heading north on Alta', cleaned.body)
    end)

    it('reports a missing required field', function()
        local cleaned, fields = check('ChatSend', {})

        assert.is_nil(cleaned)
        assert.are.equal('required', fields.body)
    end)

    it('rejects the wrong type rather than coercing it', function()
        -- A numeric string is a client that serialized badly, not a number.
        -- Coercing it would make the declared type meaningless.
        local cleaned, fields = check('PlacementDelete', { id = '7' })

        assert.is_nil(cleaned)
        assert.are.equal('type', fields.id)
    end)

    it('rejects a non-integer where an integer is declared', function()
        local cleaned, fields = check('PlacementDelete', { id = 7.5 })

        assert.is_nil(cleaned)
        assert.are.equal('not_integer', fields.id)
    end)

    it('rejects a value outside an enum', function()
        local cleaned, fields = check('PlacementCreate', {
            kind = 'armoury', interaction = 'zone', x = 1.0, y = 2.0, z = 3.0,
        })

        assert.is_nil(cleaned)
        assert.are.equal('not_allowed', fields.kind)
    end)

    it('enforces string length', function()
        local _, tooLong = check('ChatSend', { body = string.rep('x', 513) })
        assert.are.equal('too_long', tooLong.body)

        local _, tooShort = check('ChatSend', { body = '' })
        assert.are.equal('too_short', tooShort.body)
    end)

    it('enforces numeric bounds', function()
        -- A placement radius large enough to cover the city would defeat the
        -- access-point rule, so the schema caps it.
        local _, fields = check('PlacementCreate', {
            kind = 'motorpool', interaction = 'zone', x = 1.0, y = 2.0, z = 3.0, radius = 5000,
        })

        assert.are.equal('too_large', fields.radius)
    end)

    it('rejects NaN and infinity', function()
        local _, nan = check('PlacementDelete', { id = 0 / 0 })
        assert.are.equal('type', nan.id)

        local _, infinite = check('PlacementDelete', { id = math.huge })
        assert.are.equal('type', infinite.id)
    end)

    it('treats a missing body as empty when nothing is required', function()
        local cleaned, fields = check('PlacementList', nil)

        assert.is_nil(fields)
        assert.are.same({}, cleaned)
    end)

    it('drops keys the schema does not declare', function()
        -- The whole point: a handler must never see a field it did not ask for.
        local cleaned = check('ChatSend', {
            body = 'hello',
            agencyId = 'fib',
            officerId = 999,
            callsign = 'CHIEF',
        })

        assert.are.equal('hello', cleaned.body)
        assert.is_nil(cleaned.agencyId)
        assert.is_nil(cleaned.officerId)
        assert.is_nil(cleaned.callsign)
    end)

    it('refuses an unknown schema rather than passing input through', function()
        local cleaned, fields = check('NoSuchSchema', { anything = true })

        assert.is_nil(cleaned)
        assert.are.equal('unknown', fields._schema)
    end)

    it('refuses a non-table input', function()
        local cleaned, fields = check('ChatSend', 'just a string')

        assert.is_nil(cleaned)
        assert.are.equal('type', fields._input)
    end)
end)
