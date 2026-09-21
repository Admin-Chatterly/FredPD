--- Åtal och dom (spec 7.20).
---
--- **`sentenceWithinRange` is what this file is for.** It is what stands
--- between a domare's typed number and `Brott.gemensamStraffskala`'s answer,
--- and the failure mode of getting it wrong is a sentence with no statutory
--- basis on a record every officer with `court.referral.review` can read.

local helper = require('spec.helper')

describe('court', function()
    local court

    before_each(function()
        court = helper.load({ 'server/modules/court/service' }).Modules.court
    end)

    -- -------------------------------------------------------------------------
    describe('the capacity matrix', function()
        it('lets only the åklagare decide a referral', function()
            assert.is_true(court.mayDecide('aklagare'))
            assert.is_false(court.mayDecide('domare'))
            assert.is_false(court.mayDecide(nil))
        end)

        it('lets only the domare enter a disposition', function()
            -- The whole point of 0016's split: a domare who could also file
            -- the charge would be a domare who is also the prosecution.
            assert.is_true(court.mayDispose('domare'))
            assert.is_false(court.mayDispose('aklagare'))
            assert.is_false(court.mayDispose(nil))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('sentenceWithinRange', function()
        local skala = { boter = false, min = 6, max = 72 }

        it('accepts a sentence inside the range', function()
            assert.is_true(court.sentenceWithinRange(skala, 24, false))
        end)

        it('accepts the floor and the ceiling themselves', function()
            assert.is_true(court.sentenceWithinRange(skala, 6, false))
            assert.is_true(court.sentenceWithinRange(skala, 72, false))
        end)

        it('refuses below the floor', function()
            local ok, why = court.sentenceWithinRange(skala, 3, false)
            assert.is_false(ok)
            assert.are.equal('below_min', why)
        end)

        it('refuses above the ceiling', function()
            local ok, why = court.sentenceWithinRange(skala, 96, false)
            assert.is_false(ok)
            assert.are.equal('above_max', why)
        end)

        it('refuses livstid where the charges do not carry it', function()
            local ok, why = court.sentenceWithinRange(skala, nil, true)
            assert.is_false(ok)
            assert.are.equal('not_available', why)
        end)

        it('accepts livstid where the charges do carry it', function()
            -- `Brott.LIVSTID` is nil: a skala with no max means the offence
            -- carries livstid (0008).
            local livstidSkala = { boter = false, min = 120, max = nil }
            assert.is_true(court.sentenceWithinRange(livstidSkala, nil, true))
        end)

        it('refuses with no charges on the row at all', function()
            local ok, why = court.sentenceWithinRange(nil, 24, false)
            assert.is_false(ok)
            assert.are.equal('no_charges', why)
        end)

        it('refuses a missing number when livstid is not claimed', function()
            local ok, why = court.sentenceWithinRange(skala, nil, false)
            assert.is_false(ok)
            assert.are.equal('required', why)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('dispositionNeedsSentence', function()
        it('requires a sentence for a conviction or a plea', function()
            assert.is_true(court.dispositionNeedsSentence('guilty'))
            assert.is_true(court.dispositionNeedsSentence('plea'))
        end)

        it('takes no sentence for an acquittal or a dismissal', function()
            -- A sentence attached to either would read as a conviction that
            -- never happened.
            assert.is_false(court.dispositionNeedsSentence('not_guilty'))
            assert.is_false(court.dispositionNeedsSentence('dismissed'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validateReferral', function()
        local function referral(overrides)
            local base = { fuId = 12, beslut = 'atalad', brottIds = { 1, 2 } }

            for key, value in pairs(overrides or {}) do
                base[key] = value ~= helper.NONE and value or nil
            end

            return base
        end

        it('accepts a well-formed charge', function()
            assert.is_nil(court.validateReferral(referral()))
        end)

        it('accepts a well-formed decline', function()
            assert.is_nil(court.validateReferral(referral({
                beslut = 'ej_atal', brottIds = helper.NONE, beslutGrund = 'otillrackliga_bevis',
            })))
        end)

        it('refuses a decline with no ground', function()
            local err, fields = court.validateReferral(referral({
                beslut = 'ej_atal', brottIds = helper.NONE,
            }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.beslutGrund)
        end)

        it('refuses a ground that is not a locale key', function()
            local err, fields = court.validateReferral(referral({
                beslut = 'ej_atal', brottIds = helper.NONE, beslutGrund = 'because reasons',
            }))

            assert.are.equal('invalid', err)
            assert.are.equal('not_a_key', fields.beslutGrund)
        end)

        it('refuses a charge with no offences named', function()
            local err, fields = court.validateReferral(referral({ brottIds = {} }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.brottIds)
        end)

        it('refuses an unknown decision', function()
            local err, fields = court.validateReferral(referral({ beslut = 'maybe' }))

            assert.are.equal('invalid', err)
            assert.are.equal('unknown', fields.beslut)
        end)

        it('refuses a request naming no investigation', function()
            local err, fields = court.validateReferral(referral({ fuId = helper.NONE }))

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.fuId)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validateDisposition', function()
        it('accepts a conviction with a sentence', function()
            assert.is_nil(court.validateDisposition({ disposition = 'guilty', sentenceMonths = 24 }))
        end)

        it('accepts a conviction sentenced to livstid', function()
            assert.is_nil(court.validateDisposition({ disposition = 'guilty', sentenceLivstid = true }))
        end)

        it('accepts an acquittal with no sentence', function()
            assert.is_nil(court.validateDisposition({ disposition = 'not_guilty' }))
        end)

        it('refuses a conviction with no sentence at all', function()
            local err, fields = court.validateDisposition({ disposition = 'guilty' })

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.sentenceMonths)
        end)

        it('refuses a sentence attached to an acquittal', function()
            -- The case this rule exists for: a sentence on a `not_guilty` row
            -- would read as a conviction that never happened.
            local err, fields = court.validateDisposition({
                disposition = 'not_guilty', sentenceMonths = 12,
            })

            assert.are.equal('invalid', err)
            assert.are.equal('not_allowed', fields.sentenceMonths)
        end)

        it('refuses an unknown disposition', function()
            local err, fields = court.validateDisposition({ disposition = 'sort_of_guilty' })

            assert.are.equal('invalid', err)
            assert.are.equal('unknown', fields.disposition)
        end)
    end)
end)
