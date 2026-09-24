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

describe('court sentence served in the game', function()
    local court
    local JAIL <const> = { minutesPerMonth = 1, minMinutes = 5, maxMinutes = 120 }

    before_each(function()
        court = helper.load({ 'server/modules/court/service' }).Modules.court
    end)

    it('serves a month as a minute, by default', function()
        assert.are.equal(18, court.jailMinutes('guilty', 18, false, JAIL))
        assert.are.equal(18, court.jailMinutes('plea', 18, false, JAIL))
    end)

    it('clamps to the jail the server allows', function()
        assert.are.equal(5, court.jailMinutes('guilty', 1, false, JAIL))
        assert.are.equal(120, court.jailMinutes('guilty', 216, false, JAIL))
        assert.are.equal(120, court.jailMinutes('guilty', nil, true, JAIL))
    end)

    it('sends nobody anywhere for an acquittal, a dismissal or a fine', function()
        assert.is_nil(court.jailMinutes('not_guilty', 18, false, JAIL))
        assert.is_nil(court.jailMinutes('dismissed', 18, false, JAIL))
        assert.is_nil(court.jailMinutes('guilty', 0, false, JAIL))
        assert.is_nil(court.jailMinutes('guilty', nil, false, JAIL))
    end)
end)

describe('jail bridge', function()
    local PoliceJob, calls, started, answer

    before_each(function()
        calls, started, answer = {}, true, nil
        _G.GetResourceState = function() return started and 'started' or 'missing' end
        _G.exports = setmetatable({}, {
            __index = function(_, resource)
                return setmetatable({}, {
                    __index = function(_, name)
                        return function(_, jailer, data)
                            if name ~= 'JailPlayer' then error('No such export ' .. name .. ' in ' .. resource) end
                            calls[#calls + 1] = { resource = resource, jailer = jailer, data = data }
                            return answer
                        end
                    end,
                })
            end,
        })
        local ns = helper.load({ 'server/bridges/policejob' })
        ns.Config = { server = { jail = { enabled = true, resource = 'p_policejob', export = 'JailPlayer' } } }
        PoliceJob = ns.Bridge.policejob
    end)

    it('hands the prisoner to p_policejob in the shape its export documents', function()
        assert.is_true(PoliceJob.jail(7, 18, 'Dömd, mål A26-00011', 3))

        assert.are.equal('p_policejob', calls[1].resource)
        assert.are.equal(3, calls[1].jailer)
        assert.are.same({ player = 7, jail = 18, fine = 0, reason = 'Dömd, mål A26-00011' }, calls[1].data)
    end)

    it('uses the prisoner as the source when no officer is present', function()
        PoliceJob.jail(7, 18, 'x', nil)

        assert.are.equal(7, calls[1].jailer)
    end)

    it('says there is no jail, rather than failing, when the resource is not running', function()
        started = false

        assert.is_nil(PoliceJob.jail(7, 18, 'x'))
        assert.are.equal(0, #calls)
    end)

    it('counts a jail that answers false as not jailed', function()
        answer = false

        assert.is_false(PoliceJob.jail(7, 18, 'x', 3))
    end)

    it('says there is no jail when it is switched off', function()
        FredPD.Config.server.jail.enabled = false

        assert.is_false(PoliceJob.jailAvailable())
        assert.is_nil(PoliceJob.jail(7, 18, 'x'))
    end)

    it('reports a failed call, so the sentence is not lost', function()
        FredPD.Config.server.jail.export = 'NotAnExport'

        assert.is_false(PoliceJob.jail(7, 18, 'x'))
    end)
end)
