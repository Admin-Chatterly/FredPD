--- The police job bridge's duty answer (spec 3.11, ADR-025).
---
--- "Nobody can go on duty" was this: the bridge asked p_policejob for an
--- `isOnDuty` it does not export, then fell back to a flag nothing sets, so
--- every officer read as off duty. pScripts keeps duty in its job core. These
--- pin the order duty is read in, and that "cannot say" never reads as on.

local helper = require('spec.helper')

describe('policejob bridge: duty', function()
    local PoliceJob, started, exported, character, calls

    before_each(function()
        started, exported, calls = {}, {}, {}
        character = { identifier = 'char1:abc', jobOnDuty = nil, onDuty = false }

        _G.GetResourceState = function(name) return started[name] and 'started' or 'missing' end
        _G.exports = setmetatable({}, {
            __index = function(_, resource)
                return setmetatable({}, {
                    __index = function(_, name)
                        local fn = exported[resource .. '.' .. name]
                        if not fn then error('no such export: ' .. resource .. '.' .. name) end
                        return function(_self, ...)
                            calls[#calls + 1] = { resource = resource, name = name, args = { ... } }
                            return fn(...)
                        end
                    end,
                })
            end,
        })

        local FredPD = helper.load({ 'server/bridges/policejob' })
        FredPD.Bridge.framework = { getCharacter = function() return character end }
        FredPD.Config = { server = {} }
        PoliceJob = FredPD.Bridge.policejob
    end)

    after_each(function()
        _G.GetResourceState, _G.exports = nil, nil
    end)

    it('asks the job core first, by the character identifier', function()
        started.piotreq_jobcore = true
        exported['piotreq_jobcore.isPlayerOnDuty'] = function(identifier) return identifier == 'char1:abc' end
        character.jobOnDuty = false

        local onDuty, source = PoliceJob.isOnDuty(7)

        assert.is_true(onDuty)
        assert.are.equal('piotreq_jobcore', source)
        assert.are.equal('char1:abc', calls[1].args[1])
    end)

    it('reads a numeric answer as on or off', function()
        started.piotreq_jobcore = true
        exported['piotreq_jobcore.isPlayerOnDuty'] = function() return 1 end

        assert.is_true((PoliceJob.isOnDuty(7)))
    end)

    it('falls through to ESX job.onDuty when the job core is not running', function()
        character.jobOnDuty = true

        local onDuty, source = PoliceJob.isOnDuty(7)

        assert.is_true(onDuty)
        assert.are.equal('esx_job', source)
    end)

    it('falls through when an export errors, rather than failing the route', function()
        started.piotreq_jobcore = true
        exported['piotreq_jobcore.isPlayerOnDuty'] = function() error('boom') end
        character.jobOnDuty = true

        assert.is_true((PoliceJob.isOnDuty(7)))
    end)

    it('uses the resource and export config names', function()
        started.my_duty = true
        exported['my_duty.onDuty'] = function() return true end
        FredPD.Config.server.duty = { resource = 'my_duty', export = 'onDuty' }

        local onDuty, source = PoliceJob.isOnDuty(7)

        assert.is_true(onDuty)
        assert.are.equal('my_duty', source)
    end)

    it('counts nobody on duty when no source can say', function()
        character.onDuty = nil

        local onDuty, source = PoliceJob.isOnDuty(7)

        assert.is_false(onDuty)
        assert.is_nil(source)
    end)

    it('lists what every source said, for the console diagnostic', function()
        started.piotreq_jobcore = true
        exported['piotreq_jobcore.isPlayerOnDuty'] = function() return false end
        character.jobOnDuty = true

        local answers = PoliceJob.dutySources(7)

        assert.are.same({ 'piotreq_jobcore', 'p_policejob', 'esx_job', 'fredpd' },
            { answers[1].source, answers[2].source, answers[3].source, answers[4].source })
        assert.is_false(answers[1].onDuty)
        assert.is_nil(answers[2].onDuty)
        assert.is_true(answers[3].onDuty)
    end)
end)
