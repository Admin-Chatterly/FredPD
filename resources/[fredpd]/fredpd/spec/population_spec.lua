--- The population register (search shows citizens and cars not yet on file).
---
--- "Search does not find my own name": the MDT searched FredPD's registers
--- only, and a character nobody had run a check on had no record there. These
--- pin what a search offers, to whom, and that opening one takes only what
--- the server offered and never discloses a record the reader may not see
--- (ADR-026).

local helper = require('spec.helper')

describe('population', function()
    local routes, population, created, audit, session, service
    local characters, owned, onFileIds, onFilePlates, personsById, readable, registered, createReturns

    before_each(function()
        routes, created, audit, registered = {}, {}, {}, {}
        characters, owned, onFileIds, onFilePlates, personsById = {}, {}, {}, {}, {}
        readable = {}
        createReturns = nil

        local FredPD = helper.load({
            'shared/generated/schema',
            'server/modules/registry/service',
            'server/modules/field/service',
            'server/modules/population/service',
        })
        service = FredPD.Modules.population

        FredPD.Core = {
            route = {
                define = function(definition) routes[definition.name] = definition end,
                refuse = function(code, fields) return { __err = code, fields = fields } end,
            },
            audit = { write = function(entry) audit[#audit + 1] = entry end },
            perms = { satisfies = function(effective, required) return effective[required] == true end },
        }
        FredPD.Repo = {
            population = {
                identifiersOnFile = function(_, ids)
                    local set = {}
                    for _, id in ipairs(ids) do if onFileIds[id] then set[id] = true end end
                    return set
                end,
                platesOnFile = function(_, plates)
                    local set = {}
                    for _, plate in ipairs(plates) do if onFilePlates[plate] then set[plate] = true end end
                    return set
                end,
            },
            persons = {
                byIdentifier = function(_, identifier) return personsById[identifier] end,
                createPerson = function(_, fields)
                    created[#created + 1] = fields
                    personsById[fields.identifier] = personsById[fields.identifier] or (900 + #created)
                    return createReturns or personsById[fields.identifier]
                end,
                readPerson = function(_, id)
                    if readable[id] == false then return nil, 'hidden' end
                    return { id = id }, 'full'
                end,
            },
            registry = {
                findVehicle = function() return nil end,
                registerVehicle = function(_, input)
                    registered[#registered + 1] = input
                    return { id = 77, plate = input.plate }
                end,
            },
            access = { read = function(_, _, row) return row end },
        }
        FredPD.Bridge = {
            framework = {
                searchCharacters = function() return characters end,
                searchOwnedVehicles = function() return owned end,
                ownedVehicleByPlate = function(drawn)
                    for _, row in ipairs(owned) do
                        if row.plate == drawn then return row end
                    end
                    return nil
                end,
                characterByIdentifier = function(identifier)
                    for _, row in ipairs(characters) do
                        if row.identifier == identifier then return row end
                    end
                    return nil
                end,
            },
        }

        assert(loadfile('resources/[fredpd]/fredpd/server/modules/population/routes.lua'))()
        population = FredPD.Modules.populationSearch
        session = helper.session({ permissions = { ['population.search'] = true } })
    end)

    local function open(ref)
        return routes['person.fromCharacter'].handler(session, { ref = ref })
    end

    describe('search', function()
        it('offers a character with no record, by full name, and never its identifier', function()
            characters = {
                { identifier = 'char1:me', firstName = 'Anna', lastName = 'Berg', dateOfBirth = '1990-01-02', phone = '555' },
            }

            local found = population.characters(session, 'Anna Berg')

            assert.are.equal(1, #found)
            assert.are.equal('Berg', found[1].lastName)
            assert.is_string(found[1].ref)
            assert.is_nil(found[1].identifier)
            assert.is_nil(found[1].phone)
        end)

        it('offers nothing to a session without population.search', function()
            characters = { { identifier = 'char1:me', firstName = 'Anna', lastName = 'Berg' } }
            session.permissions = { ['rms.person.view'] = true }

            assert.are.same({}, population.characters(session, 'Anna'))
            assert.are.same({}, population.vehicles(session, 'ABC'))
        end)

        it('never offers a character that already has a record, whoever may read it', function()
            characters = { { identifier = 'char1:hidden', firstName = 'Anna', lastName = 'Berg' } }
            onFileIds['char1:hidden'] = true

            assert.are.same({}, population.characters(session, 'Anna'))
        end)

        it('does not search the framework for a term too short, or made only of wildcards', function()
            characters = { { identifier = 'char1:me', firstName = 'Anna', lastName = 'Berg' } }

            assert.are.same({}, population.characters(session, 'A'))
            assert.are.same({}, population.characters(session, '__'))
            assert.are.same({}, population.vehicles(session, '%%'))
            assert.are.equal('ab', service.term('a_b%'):gsub('%s', ''))
        end)

        it('offers an owned car with no record, by its normalised plate, and nothing of its owner', function()
            owned = { { plate = 'abc 123', owner = 'char1:me' }, { plate = 'XYZ999', owner = 'char1:x' } }
            onFilePlates.XYZ999 = true

            local found = population.vehicles(session, 'abc')

            assert.are.equal(1, #found)
            assert.are.equal('ABC123', found[1].plate)
            assert.is_nil(found[1].owner)
        end)
    end)

    describe('person.fromCharacter', function()
        it('opens only what the server offered this officer', function()
            characters = { { identifier = 'char1:me', firstName = 'Anna', lastName = 'Berg' } }
            local ref = population.characters(session, 'Anna')[1].ref

            -- Another officer holding the same reference opens nothing.
            local other = session
            session = helper.session({ discordId = '200000000000000002', permissions = other.permissions })
            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, open(ref).__err)
            assert.are.equal(0, #created)

            session = other
            assert.is_true(open(ref).created)
        end)

        it('refuses a reference it never offered, and takes no identifier', function()
            characters = { { identifier = 'char1:me', firstName = 'Anna', lastName = 'Berg' } }

            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, open('p999').__err)
            assert.are.equal(FredPD.ErrorCode.NOT_FOUND,
                routes['person.fromCharacter'].handler(session, { identifier = 'char1:me' }).__err)
            assert.are.equal(0, #created)
        end)

        it('creates the record from the framework and audits it', function()
            characters = { { identifier = 'char1:me', firstName = ' Anna ', lastName = 'Berg', dateOfBirth = '02/01/1990' } }
            local ref = population.characters(session, 'Anna')[1].ref

            local result = open(ref)

            assert.are.equal(901, result.id)
            assert.is_true(result.created)
            assert.are.equal('Anna', created[1].firstName)
            assert.are.equal('person.created', audit[1].action)
            assert.are.equal('population_register', audit[1].detail.source)
        end)

        it('does not claim a record another open created a moment before', function()
            characters = { { identifier = 'char1:me', firstName = 'Anna', lastName = 'Berg' } }
            local ref = population.characters(session, 'Anna')[1].ref
            -- The unique key refused this insert; the read-back finds theirs.
            createReturns = 555

            local result = open(ref)

            assert.is_false(result.created)
            assert.are.equal(0, #audit)
        end)

        it('is on duty, a few at a time, on its own permission', function()
            local definition = routes['person.fromCharacter']
            assert.are.equal('population.search', definition.perm)
            assert.is_true(definition.context.onDuty)
            assert.is_true(definition.limit.per <= 5)
            assert.are.equal('population.search', routes['vehicle.fromOwned'].perm)
            assert.is_true(routes['vehicle.fromOwned'].context.onDuty)
        end)
    end)

    describe('vehicle.fromOwned', function()
        it('does not link a keeper whose record this officer may not read', function()
            owned = { { plate = 'ABC123', owner = 'char1:hidden' } }
            personsById['char1:hidden'] = 7
            readable[7] = false
            local ref = population.vehicles(session, 'ABC')[1].ref

            local result = routes['vehicle.fromOwned'].handler(session, { ref = ref })

            assert.are.equal(77, result.id)
            assert.is_nil(registered[1].ownerPersonId)
        end)
    end)

    describe('references', function()
        it('expire, and the oldest go when an officer holds too many', function()
            local store = {}
            local first = service.remember(store, 'a', 'person', 'char1:x', 0)

            assert.are.equal('char1:x', service.recall(store, 'a', 'person', first, service.REF_TTL))
            assert.is_nil(service.recall(store, 'a', 'person', first, service.REF_TTL + 1))
            assert.is_nil(service.recall(store, 'a', 'vehicle', first, 0))

            for index = 1, service.REF_CAP do service.remember(store, 'a', 'person', 'k' .. index, 0) end
            assert.is_nil(service.recall(store, 'a', 'person', first, 0))
        end)
    end)
end)
