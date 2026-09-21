--- Ordningsbot (spec 7.11).
---
--- **`isVoidReason` is what stands between a client-sent key and `t()`
--- rendering it verbatim** -- the same defect class `court_spec.lua` and
--- `personnel_spec.lua` guard against for their own allowlists.

local helper = require('spec.helper')

describe('ordningsbot', function()
    local ordningsbot

    before_each(function()
        ordningsbot = helper.load({ 'server/modules/ordningsbot/service' }).Modules.ordningsbot
    end)

    -- -------------------------------------------------------------------------
    describe('isVoidReason', function()
        it('accepts every reason in the allowlist', function()
            assert.is_true(ordningsbot.isVoidReason('issued_in_error'))
            assert.is_true(ordningsbot.isVoidReason('identity_mistake'))
            assert.is_true(ordningsbot.isVoidReason('duplicate'))
            assert.is_true(ordningsbot.isVoidReason('other'))
        end)

        it('refuses a key that is not in the list', function()
            assert.is_false(ordningsbot.isVoidReason('because_i_felt_like_it'))
        end)

        it('refuses nil and non-string values', function()
            assert.is_false(ordningsbot.isVoidReason(nil))
            assert.is_false(ordningsbot.isVoidReason(42))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validateIssue', function()
        local function issue(overrides)
            local base = { tariffId = 1, personId = 4 }

            for key, value in pairs(overrides or {}) do
                base[key] = value ~= helper.NONE and value or nil
            end

            return base
        end

        it('accepts a citation against a person', function()
            assert.is_nil(ordningsbot.validateIssue(issue()))
        end)

        it('accepts a citation against a vehicle with no confirmed driver', function()
            assert.is_nil(ordningsbot.validateIssue(issue({ personId = helper.NONE, vehicleId = 9 })))
        end)

        it('accepts a citation carrying both', function()
            assert.is_nil(ordningsbot.validateIssue(issue({ vehicleId = 9 })))
        end)

        it('refuses a citation naming neither a person nor a vehicle', function()
            local err, fields = ordningsbot.validateIssue(issue({ personId = helper.NONE }))

            assert.are.equal('invalid', err)
            assert.are.equal('subject_required', fields._input)
        end)

        it('refuses a missing tariff', function()
            local err, fields = ordningsbot.validateIssue(issue({ tariffId = helper.NONE }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.tariffId)
        end)

        it('refuses a non-numeric tariff id', function()
            local err, fields = ordningsbot.validateIssue(issue({ tariffId = 'one' }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.tariffId)
        end)

        it('refuses a tariff id below 1', function()
            local err, fields = ordningsbot.validateIssue(issue({ tariffId = 0 }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.tariffId)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validateVoid', function()
        it('accepts a reason from the allowlist', function()
            assert.is_nil(ordningsbot.validateVoid({ voidReasonKey = 'duplicate' }))
        end)

        it('refuses a missing reason', function()
            local err, fields = ordningsbot.validateVoid({})

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.voidReasonKey)
        end)

        it('refuses an empty-string reason', function()
            local err, fields = ordningsbot.validateVoid({ voidReasonKey = '' })

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.voidReasonKey)
        end)

        it('refuses a reason that is not a locale key in the allowlist', function()
            -- The exact defect this check exists for: free text that would
            -- otherwise render verbatim through `t()`.
            local err, fields = ordningsbot.validateVoid({ voidReasonKey = 'because reasons' })

            assert.are.equal('invalid', err)
            assert.are.equal('not_a_key', fields.voidReasonKey)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('mayTransition', function()
        it('allows issued -> paid', function()
            assert.is_true(ordningsbot.mayTransition('issued', 'paid'))
        end)

        it('allows issued -> contested', function()
            assert.is_true(ordningsbot.mayTransition('issued', 'contested'))
        end)

        it('allows issued -> void', function()
            assert.is_true(ordningsbot.mayTransition('issued', 'void'))
        end)

        it('refuses paid -> void', function()
            -- A wrongly-paid fine is a refund process, not a status flip.
            assert.is_false(ordningsbot.mayTransition('paid', 'void'))
        end)

        it('refuses contested -> paid', function()
            -- Resolving a contest is 7.20's disposition, not a second
            -- verdict mechanism this module invents.
            assert.is_false(ordningsbot.mayTransition('contested', 'paid'))
        end)

        it('refuses void -> issued', function()
            assert.is_false(ordningsbot.mayTransition('void', 'issued'))
        end)

        it('refuses issued -> issued', function()
            assert.is_false(ordningsbot.mayTransition('issued', 'issued'))
        end)

        it('refuses an unknown starting status', function()
            assert.is_false(ordningsbot.mayTransition('overdue', 'paid'))
        end)
    end)
end)
