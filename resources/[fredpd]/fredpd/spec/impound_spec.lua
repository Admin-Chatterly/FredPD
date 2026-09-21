--- Vehicle impound (spec 7.15).
---
--- **`feeOwed` is the function that matters.** The cases below pin it against
--- fixed instants -- a same-day release, exactly one day, exactly two and a
--- half days rounding up to three -- the same style `frihet_spec.lua` uses to
--- pin RB 24:12 and 24:13, and for the same reason: this arithmetic decides
--- what somebody is actually billed, and a day miscounted is not a typo to
--- shrug off.

local helper = require('spec.helper')

describe('impound', function()
    local impound

    before_each(function()
        impound = helper.load({ 'server/modules/impound/service' }).Modules.impound
    end)

    -- -------------------------------------------------------------------------
    describe('held reasons', function()
        it('knows its six and nothing else', function()
            for _, key in ipairs({
                'investigative', 'evidence', 'abandoned', 'dui', 'unregistered', 'other',
            }) do
                assert.is_true(impound.isHeldReason(key))
            end

            assert.is_false(impound.isHeldReason('stolen'))
            assert.is_false(impound.isHeldReason('Investigative'))
            assert.is_false(impound.isHeldReason(nil))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('needsAuthorization', function()
        it('requires it for an investigative or evidence hold', function()
            assert.is_true(impound.needsAuthorization('investigative'))
            assert.is_true(impound.needsAuthorization('evidence'))
        end)

        it('requires nothing for every other reason', function()
            for _, key in ipairs({ 'abandoned', 'dui', 'unregistered', 'other' }) do
                assert.is_false(impound.needsAuthorization(key))
            end
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('feeOwed', function()
        local DAY <const> = 86400
        local impoundedAt <const> = 1700000000 -- an arbitrary fixed instant

        it('charges one full day even for a same-day release', function()
            local row = { impoundedAt = impoundedAt, feePerDay = 50 }

            -- Released ten minutes after impound: still a whole day's fee.
            assert.are.equal(50, impound.feeOwed(row, impoundedAt + 600))
        end)

        it('charges exactly one day at exactly one day', function()
            local row = { impoundedAt = impoundedAt, feePerDay = 50 }

            assert.are.equal(50, impound.feeOwed(row, impoundedAt + DAY))
        end)

        it('rounds two and a half days up to three', function()
            local row = { impoundedAt = impoundedAt, feePerDay = 50 }

            assert.are.equal(150, impound.feeOwed(row, impoundedAt + math.floor(2.5 * DAY)))
        end)

        it('charges nothing over zero days at a zero rate', function()
            local row = { impoundedAt = impoundedAt, feePerDay = 0 }

            assert.are.equal(0, impound.feeOwed(row, impoundedAt + 5 * DAY))
        end)

        it('uses releasedAt once the vehicle has been released, not `now`', function()
            local row = { impoundedAt = impoundedAt, releasedAt = impoundedAt + DAY, feePerDay = 50 }

            -- `now` has moved on well past release; the bill does not keep growing.
            assert.are.equal(50, impound.feeOwed(row, impoundedAt + 30 * DAY))
        end)

        it('never charges for negative elapsed time', function()
            local row = { impoundedAt = impoundedAt, feePerDay = 50 }

            assert.are.equal(50, impound.feeOwed(row, impoundedAt - 3600))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('mayRelease', function()
        it('refuses an unpaid fee before anything else', function()
            local ok, why = impound.mayRelease({ heldReasonKey = 'abandoned' }, false)

            assert.is_false(ok)
            assert.are.equal('fee_unpaid', why)
        end)

        it('refuses an unauthorized investigative hold even once the fee is paid', function()
            local ok, why = impound.mayRelease(
                { heldReasonKey = 'investigative', holdAuthorizedAt = nil }, true)

            assert.is_false(ok)
            assert.are.equal('not_authorized', why)
        end)

        it('refuses an unauthorized evidence hold the same way', function()
            local ok, why = impound.mayRelease(
                { heldReasonKey = 'evidence', holdAuthorizedAt = nil }, true)

            assert.is_false(ok)
            assert.are.equal('not_authorized', why)
        end)

        it('allows a paid, authorized investigative hold to release', function()
            assert.is_true(impound.mayRelease(
                { heldReasonKey = 'investigative', holdAuthorizedAt = 1700000000 }, true))
        end)

        it('allows a paid non-investigative hold to release without any authorization', function()
            assert.is_true(impound.mayRelease({ heldReasonKey = 'dui', holdAuthorizedAt = nil }, true))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validation', function()
        it('requires a plate and a known hold reason to create', function()
            local err, fields = impound.validateCreate({ heldReasonKey = 'dui' })
            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.plate)

            err, fields = impound.validateCreate({ plate = 'ABC123', heldReasonKey = 'made_up' })
            assert.are.equal('invalid', err)
            assert.are.equal('not_a_key', fields.heldReasonKey)

            assert.is_nil(impound.validateCreate({ plate = 'ABC123', heldReasonKey = 'dui' }))
        end)

        it('rejects a negative or fractional fee', function()
            local err = impound.validateCreate({ plate = 'ABC123', heldReasonKey = 'dui', feePerDay = -1 })
            assert.are.equal('invalid', err)

            err = impound.validateCreate({ plate = 'ABC123', heldReasonKey = 'dui', feePerDay = 1.5 })
            assert.are.equal('invalid', err)

            assert.is_nil(impound.validateCreate({ plate = 'ABC123', heldReasonKey = 'dui', feePerDay = 100 }))
        end)

        it('requires an id to authorize', function()
            local err, fields = impound.validateAuthorize({})
            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.id)
        end)

        it('requires an id and a version to release', function()
            local err, fields = impound.validateRelease({ id = 1 })
            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.version)

            assert.is_nil(impound.validateRelease({ id = 1, version = 1 }))
        end)
    end)
end)
