--- Booking: cell assignment and the property inventory (spec 7.9).
---
--- **`isReleaseReason` is what this file is for.** It is what stands between
--- a client-sent key and a column the NUI renders with `t()`, and the failure
--- mode of skipping it is a free string drawn as a label in both locales --
--- the defect this module's header names.

local helper = require('spec.helper')

describe('booking', function()
    local booking

    before_each(function()
        booking = helper.load({ 'server/modules/booking/service' }).Modules.booking
    end)

    -- -------------------------------------------------------------------------
    describe('isReleaseReason', function()
        it('accepts every key on the allowlist', function()
            assert.is_true(booking.isReleaseReason('bail'))
            assert.is_true(booking.isReleaseReason('released_no_charge'))
            assert.is_true(booking.isReleaseReason('transferred'))
            assert.is_true(booking.isReleaseReason('time_served'))
            assert.is_true(booking.isReleaseReason('other'))
        end)

        it('refuses a key not on the allowlist', function()
            assert.is_false(booking.isReleaseReason('escaped'))
        end)

        it('refuses prose masquerading as a key', function()
            -- The exact defect the module header names: a free sentence sent
            -- as if it were a key, which `t()` would print verbatim.
            assert.is_false(booking.isReleaseReason('Let go because the sergeant said so'))
        end)

        it('refuses nil and non-string values', function()
            assert.is_false(booking.isReleaseReason(nil))
            assert.is_false(booking.isReleaseReason(42))
            assert.is_false(booking.isReleaseReason({}))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validateBook', function()
        local function book(overrides)
            local base = { frihetId = 7 }

            for key, value in pairs(overrides or {}) do
                base[key] = value ~= helper.NONE and value or nil
            end

            return base
        end

        it('accepts a well-formed booking with no cell', function()
            assert.is_nil(booking.validateBook(book()))
        end)

        it('accepts a well-formed booking with a cell', function()
            assert.is_nil(booking.validateBook(book({ cell = 'A-4' })))
        end)

        it('refuses a missing frihetId', function()
            local err, fields = booking.validateBook(book({ frihetId = helper.NONE }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.frihetId)
        end)

        it('refuses a frihetId below 1', function()
            local err, fields = booking.validateBook(book({ frihetId = 0 }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.frihetId)
        end)

        it('refuses a non-string cell', function()
            local err, fields = booking.validateBook(book({ cell = 12 }))

            assert.are.equal('invalid', err)
            assert.are.equal('too_long', fields.cell)
        end)

        it('refuses a cell longer than 32 characters', function()
            local err, fields = booking.validateBook(book({ cell = ('A'):rep(33) }))

            assert.are.equal('invalid', err)
            assert.are.equal('too_long', fields.cell)
        end)

        it('refuses a non-table input', function()
            local err, fields = booking.validateBook('not a table')

            assert.are.equal('invalid', err)
            assert.are.equal('type', fields._input)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validatePropertyAdd', function()
        local function propertyAdd(overrides)
            local base = { bookingId = 3, itemLabel = 'black leather wallet' }

            for key, value in pairs(overrides or {}) do
                base[key] = value ~= helper.NONE and value or nil
            end

            return base
        end

        it('accepts a well-formed line with no quantity', function()
            assert.is_nil(booking.validatePropertyAdd(propertyAdd()))
        end)

        it('accepts an explicit quantity', function()
            assert.is_nil(booking.validatePropertyAdd(propertyAdd({ quantity = 3 })))
        end)

        it('refuses a missing bookingId', function()
            local err, fields = booking.validatePropertyAdd(propertyAdd({ bookingId = helper.NONE }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.bookingId)
        end)

        it('refuses an empty itemLabel', function()
            local err, fields = booking.validatePropertyAdd(propertyAdd({ itemLabel = '' }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.itemLabel)
        end)

        it('refuses a missing itemLabel', function()
            local err, fields = booking.validatePropertyAdd(propertyAdd({ itemLabel = helper.NONE }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.itemLabel)
        end)

        it('refuses an itemLabel longer than 191 characters', function()
            local err, fields = booking.validatePropertyAdd(propertyAdd({ itemLabel = ('x'):rep(192) }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.itemLabel)
        end)

        it('refuses a quantity below 1', function()
            local err, fields = booking.validatePropertyAdd(propertyAdd({ quantity = 0 }))

            assert.are.equal('invalid', err)
            assert.are.equal('invalid', fields.quantity)
        end)

        it('refuses a non-numeric quantity', function()
            local err, fields = booking.validatePropertyAdd(propertyAdd({ quantity = 'two' }))

            assert.are.equal('invalid', err)
            assert.are.equal('invalid', fields.quantity)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validateRelease', function()
        it('accepts a key on the allowlist', function()
            assert.is_nil(booking.validateRelease({ releaseReasonKey = 'bail' }))
        end)

        it('refuses a missing releaseReasonKey', function()
            local err, fields = booking.validateRelease({})

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.releaseReasonKey)
        end)

        it('refuses an empty releaseReasonKey', function()
            local err, fields = booking.validateRelease({ releaseReasonKey = '' })

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.releaseReasonKey)
        end)

        it('refuses a releaseReasonKey not on the allowlist', function()
            local err, fields = booking.validateRelease({ releaseReasonKey = 'because reasons' })

            assert.are.equal('invalid', err)
            assert.are.equal('not_a_key', fields.releaseReasonKey)
        end)
    end)
end)
