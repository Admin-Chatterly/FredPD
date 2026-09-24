--- Field actions (spec 7.2, 7.4): the rules applied to the person or vehicle
--- an officer is standing next to.

local helper = require('spec.helper')

describe('field', function()
    local field

    before_each(function()
        field = helper.load({ 'server/modules/field/service' }).Modules.field
    end)

    describe('withinRange', function()
        it('accepts arm\'s length', function()
            assert.is_true(field.withinRange({ x = 0, y = 0, z = 0 }, { x = 3, y = 0, z = 0 }, 5))
        end)

        it('refuses across the street', function()
            assert.is_false(field.withinRange({ x = 0, y = 0, z = 0 }, { x = 30, y = 0, z = 0 }, 5))
        end)

        it('refuses a missing position', function()
            assert.is_false(field.withinRange(nil, { x = 0, y = 0, z = 0 }, 5))
        end)
    end)

    describe('normalizeDob', function()
        it('keeps an ISO date', function()
            assert.are.equal('1990-04-07', field.normalizeDob('1990-04-07'))
        end)

        it('reads esx_identity\'s DD/MM/YYYY', function()
            assert.are.equal('1990-04-07', field.normalizeDob('07/04/1990'))
            assert.are.equal('1990-04-07', field.normalizeDob('7.4.1990'))
        end)

        it('drops what is not a calendar date', function()
            assert.is_nil(field.normalizeDob('31/02/1990'))
            assert.is_nil(field.normalizeDob('29/02/1990'))
            assert.is_nil(field.normalizeDob('not a date'))
            assert.is_nil(field.normalizeDob(19900407))
        end)

        it('accepts the 29th of February in a leap year', function()
            assert.are.equal('1992-02-29', field.normalizeDob('29/02/1992'))
        end)
    end)

    describe('personFields', function()
        it('takes what the ID card says', function()
            local fields = field.personFields({
                identifier = 'char1:abc', firstName = ' Karl ', lastName = 'Johansson',
                dateOfBirth = '07/04/1990', sex = 'm',
            })

            assert.are.same({
                identifier = 'char1:abc', firstName = 'Karl', lastName = 'Johansson',
                dateOfBirth = '1990-04-07', sex = 'male',
            }, fields)
        end)

        it('refuses a character with no identifier', function()
            assert.is_nil(field.personFields({ firstName = 'Karl', lastName = 'Johansson' }))
        end)

        it('refuses a character with no name at all', function()
            assert.is_nil(field.personFields({ identifier = 'char1:abc', firstName = '', lastName = ' ' }))
        end)
    end)
end)

-- -----------------------------------------------------------------------------
-- The routes, against fakes: who may be identified, and what a refusal says
-- -----------------------------------------------------------------------------

describe('field routes', function()
    local routes, state

    local function loadInto(path)
        assert(loadfile(('resources/[fredpd]/fredpd/%s.lua'):format(path)))()
    end

    local function call(name, session, input)
        return routes[name].handler(session, input)
    end

    before_each(function()
        state = {
            peds = { [1] = 101, [2] = 102 },
            coords = { [101] = { x = 0, y = 0, z = 0 }, [102] = { x = 2, y = 0, z = 0 } },
            identity = {
                identifier = 'char1:target', firstName = 'Karl', lastName = 'Johansson',
                dateOfBirth = '07/04/1990', sex = 'm',
            },
            byIdentifier = {},
            created = {},
            asked = 0,
            answer = true,
            custody = {},
            visibility = 'full',
            audits = {},
            pending = {},
        }

        local FredPD = helper.load({
            'shared/generated/schema',
            'server/modules/field/service',
        })

        routes = {}

        FredPD.Config = { server = { field = { range = 5.0 } } }
        FredPD.Core = {
            route = {
                define = function(definition) routes[definition.name] = definition end,
                public = function(definition) routes[definition.name] = definition end,
                refuse = function(code, fields) return { __err = code, fields = fields } end,
            },
            audit = { write = function(entry) state.audits[#state.audits + 1] = entry end },
        }
        FredPD.Field = {
            consent = {
                ask = function()
                    state.asked = state.asked + 1
                    return state.answer
                end,
            },
        }
        FredPD.Modules.registry = { normalizePlate = function(value) return value end }
        FredPD.Modules.frihet = { isOpen = function(chain) return chain.open end }
        FredPD.Modules.access = { visibility = function() return state.visibility end }
        FredPD.Repo = {
            persons = {
                byIdentifier = function(_agencyId, identifier) return state.byIdentifier[identifier] end,
                createPerson = function(_agencyId, fields)
                    local id = 500 + #state.created
                    state.created[#state.created + 1] = fields
                    if fields.identifier then state.byIdentifier[fields.identifier] = id end
                    return id
                end,
                readPerson = function(_session, id)
                    if state.visibility ~= 'full' then return nil, state.visibility end
                    local fields = state.created[id - 499] or {}
                    return { id = id, personNumber = 'P-' .. id, firstName = fields.firstName, lastName = fields.lastName }
                end,
                setPendingIdentity = function(_agencyId, personId, identifier)
                    if state.pending[personId] then return 0 end
                    state.pending[personId] = identifier
                    return 1
                end,
            },
            registry = {},
            access = {},
            frihet = { list = function() return state.custody end },
        }
        FredPD.Bridge = { framework = { getIdentity = function() return state.identity end } }

        _G.GetPlayerPed = function(src) return state.peds[src] or 0 end
        _G.GetEntityCoords = function(ped) return state.coords[ped] end

        loadInto('server/modules/field/routes')
    end)

    after_each(function()
        _G.GetPlayerPed, _G.GetEntityCoords = nil, nil
    end)

    local function officer() return helper.session({ src = 1 }) end

    it('refuses checking your own ID', function()
        local result = call('field.person.resolve', officer(), { targetId = 1 })
        assert.are.equal('not_allowed', result.fields.targetId)
    end)

    it('refuses somebody out of reach', function()
        state.coords[102] = { x = 40, y = 0, z = 0 }

        local result = call('field.person.resolve', officer(), { targetId = 2 })
        assert.are.equal('out_of_range', result.fields.targetId)
    end)

    it('asks the person, and a refusal writes nothing and names nobody', function()
        state.answer = false

        local result = call('field.person.resolve', officer(), { targetId = 2 })

        assert.are.equal(1, state.asked)
        assert.are.equal('refused', result.fields.targetId)
        assert.are.equal(0, #state.created)
        assert.is_nil(result.personNumber)
    end)

    it('registers somebody who shows an ID the agency has never seen, and audits it', function()
        local result = call('field.person.resolve', officer(), { targetId = 2 })

        assert.is_true(result.registered)
        assert.are.equal('char1:target', state.created[1].identifier)
        assert.are.equal('1990-04-07', state.created[1].dateOfBirth)
        assert.are.equal('person.created', state.audits[1].action)
    end)

    it('does not ask a person already held in custody', function()
        state.byIdentifier['char1:target'] = 7
        state.custody = { { open = true } }

        local result = call('field.person.resolve', officer(), { targetId = 2 })

        assert.are.equal(0, state.asked)
        assert.are.equal(7, result.id)
    end)

    it('answers a hidden record exactly as an unknown person', function()
        state.byIdentifier['char1:target'] = 7
        state.visibility = 'hidden'

        local result = call('field.person.resolve', officer(), { targetId = 2 })

        assert.are.equal('not_found', result.__err)
        assert.are.equal('unreachable', result.fields.targetId)
    end)

    it('registers an arrestee who will not show ID as an unknown person', function()
        local result = call('field.person.unidentified', officer(), { targetId = 2 })

        assert.are.same({}, state.created[1])
        assert.are.equal(0, state.asked)
        assert.is_not_nil(result.personNumber)
        -- Who they are is recorded out of sight, for booking to check against.
        assert.are.equal('char1:target', state.pending[result.id])
        assert.is_nil(result.identifier)
    end)

    it('takes the consent answer only through the route, with the token', function()
        local answered = {}
        FredPD.Field.consent.answer = function(src, token, shown)
            answered[#answered + 1] = { src = src, token = token, shown = shown }
            return true
        end

        local result = routes['field.person.consent'].handler(2, { token = ('a'):rep(32), shown = true })

        assert.is_true(result.accepted)
        assert.are.equal(2, answered[1].src)
    end)
end)

describe('field consent', function()
    local consent, sent, duringWait, dropped

    before_each(function()
        sent, duringWait, dropped = {}, nil, nil

        _G.TriggerClientEvent = function(_event, target, payload) sent[#sent + 1] = { target = target, payload = payload } end
        _G.SetTimeout = function() end
        _G.AddEventHandler = function(_name, handler) dropped = handler end
        _G.promise = {
            new = function()
                local p = {}
                function p:resolve(value) self.value = value end
                return p
            end,
        }
        -- The wait is where the player answers: run whatever the test wants
        -- to happen "meanwhile", then hand back what was resolved (nil =
        -- still waiting, which the real timer turns into false).
        _G.Citizen = {
            Await = function(p)
                if duringWait then duringWait() end
                return p.value == true
            end,
        }

        consent = helper.load({ 'server/modules/field/consent' }).Field.consent
    end)

    after_each(function()
        _G.TriggerClientEvent, _G.SetTimeout, _G.AddEventHandler = nil, nil, nil
        _G.promise, _G.Citizen = nil, nil
    end)

    it('accepts the asked player\'s own answer with the token they were sent', function()
        duringWait = function() consent.answer(2, sent[1].payload.token, true) end

        assert.is_true(consent.ask(2, '12-40'))
        assert.are.equal(2, sent[1].target)
    end)

    it('ignores an answer from anybody else, or with any other token', function()
        duringWait = function()
            assert.is_false(consent.answer(3, sent[1].payload.token, true))
            assert.is_false(consent.answer(2, ('0'):rep(32), true))
        end

        assert.is_false(consent.ask(2, '12-40'))
    end)

    it('does not ask again within a minute of a refusal', function()
        duringWait = function() consent.answer(2, sent[#sent].payload.token, false) end
        assert.is_false(consent.ask(2, '12-40'))

        duringWait = nil
        assert.is_false(consent.ask(2, '12-40'))
        assert.are.equal(1, #sent)
    end)

    it('asks one question per player at a time', function()
        duringWait = function()
            duringWait = nil
            assert.is_false(consent.ask(2, '12-40'))
        end

        consent.ask(2, '12-40')
        assert.are.equal(1, #sent)
    end)

    it('treats a player leaving as a refusal', function()
        duringWait = function()
            _G.source = 2
            dropped()
            _G.source = nil
        end

        assert.is_false(consent.ask(2, '12-40'))
    end)
end)
