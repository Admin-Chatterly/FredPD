--- Keyset pagination's cursor codec (spec 12.2).

local helper = require('spec.helper')

describe('pagination', function()
    local pagination

    before_each(function()
        pagination = helper.load({ 'server/core/pagination' }).Core.pagination
    end)

    describe('encode/decode round-trip', function()
        it('round-trips a single value', function()
            assert.same({ 42 }, pagination.decode(pagination.encode({ 42 }), 1))
        end)

        it('round-trips several values', function()
            local values = { 1700000000, 7, 123 }
            assert.same(values, pagination.decode(pagination.encode(values), 3))
        end)

        it('floors a non-integer before encoding', function()
            assert.equal('7', pagination.encode({ 7.9 }))
        end)
    end)

    describe('decode', function()
        it('returns nil for nil', function()
            assert.is_nil(pagination.decode(nil, 2))
        end)

        it('returns nil for an empty string', function()
            assert.is_nil(pagination.decode('', 2))
        end)

        it('returns nil when the count does not match', function()
            assert.is_nil(pagination.decode('1:2:3', 2))
        end)

        it('returns nil for a non-numeric component', function()
            assert.is_nil(pagination.decode('1:abc', 2))
        end)

        it('returns nil for a non-string cursor', function()
            assert.is_nil(pagination.decode(42, 1))
        end)

        it('accepts a negative number', function()
            assert.same({ -5, 10 }, pagination.decode('-5:10', 2))
        end)

        it('refuses SQL injection attempts disguised as a cursor', function()
            assert.is_nil(pagination.decode("1; DROP TABLE fpd_spaning;--", 1))
            assert.is_nil(pagination.decode('1 OR 1=1', 1))
        end)
    end)
end)
