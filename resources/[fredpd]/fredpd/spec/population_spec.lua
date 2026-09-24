--- The population register (search shows citizens and cars not yet on file).
---
--- "Search does not find my own name": the MDT searched FredPD's registers
--- only, and a character nobody had run a check on had no record there. These
--- pin what a search now offers, and that opening one never discloses a
--- record the reader may not see.

local helper = require('spec.helper')

describe('population', function()
    local routes, population, created, audit, session
    local characters, owned, onFileIds, onFilePlates, personsById, readVisibility

    before_each(function()
        routes, created, audit = {}, {}, {}
        characters, owned, onFileIds, onFilePlates, personsById = {}, {}, {}, {}, {}
        readVisibility = 'full'

        local FredPD = helper.load({
            'shared/generated/schema',
            'server/modules/registry/service',
            'server/modules/field/service',
            'server/modules/population/service',
        })

        FredPD.Core = {
            route = {
                define = function(definition) routes[definition.name] = definition end,
                refuse = function(code, fields) return { __err = code, fields = fields } end,
            },
            audit = { write = function(entry) audit[#audit + 1] = entry end },
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
                    personsById[fields.identifier] = 900 + #created
                end,
                readPerson = function(_, id)
                    if readVisibility == 'full' then return { id = id }, 'full' end
                    return nil, readVisibility
                end,
            },
            registry = { findVehicle = function() return nil end },
        }
        FredPD.Bridge = {
            framework = {
                searchCharacters = function() return characters end,
                searchOwnedVehicles = function() return owned end,
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
        session = helper.session()
    end)

    describe('search', function()
        it('offers a character with no record, by full name', function()
            characters = {
                { identifier = 'char1:me', firstName = 'Anna', lastName = 'Berg', dateOfBirth = '1990-01-02', phone = '555' },
            }

            local found = population.characters(session, 'Anna Berg')

            assert.are.equal(1, #found)
            assert.are.equal('char1:me', found[1].identifier)
            assert.are.equal('Berg', found[1].lastName)
            -- The phone number stays in the framework until the record is opened.
            assert.is_nil(found[1].phone)
        end)

        it('never offers a character that already has a record, whoever may read it', function()
            characters = { { identifier = 'char1:hidden', firstName = 'Anna', lastName = 'Berg' } }
            onFileIds['char1:hidden'] = true

            assert.are.same({}, population.characters(session, 'Anna'))
        end)

        it('does not search the framework for a term too short to mean anything', function()
            characters = { { identifier = 'char1:me', firstName = 'Anna', lastName = 'Berg' } }

            assert.are.same({}, population.characters(session, 'A'))
            assert.are.same({}, population.characters(session, nil))
        end)

        it('offers an owned car with no record, by its normalised plate, and nothing of its owner', function()
            owned = { { plate = 'abc 123', owner = 'char1:me' }, { plate = 'XYZ999', owner = 'char1:x' } }
            onFilePlates.XYZ999 = true

            local found = population.vehicles(session, 'abc')

            assert.are.same({ { plate = 'ABC123' } }, found)
        end)
    end)

    describe('person.fromCharacter', function()
        local function open(identifier)
            return routes['person.fromCharacter'].handler(session, { identifier = identifier })
        end

        it('creates the record from the framework and audits it', function()
            characters = { { identifier = 'char1:me', firstName = ' Anna ', lastName = 'Berg', dateOfBirth = '02/01/1990' } }

            local result = open('char1:me')

            assert.are.equal(901, result.id)
            assert.is_true(result.created)
            assert.are.equal('Anna', created[1].firstName)
            assert.are.equal('person.created', audit[1].action)
            assert.are.equal('population_register', audit[1].detail.source)
        end)

        it('opens the existing record rather than creating a second', function()
            personsById['char1:me'] = 42

            local result = open('char1:me')

            assert.are.equal(42, result.id)
            assert.is_false(result.created)
            assert.are.equal(0, #created)
        end)

        it('answers a hidden record exactly as a missing citizen', function()
            personsById['char1:hidden'] = 7
            readVisibility = 'hidden'

            local hidden = open('char1:hidden')
            local missing = open('char1:nobody')

            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, hidden.__err)
            assert.are.same(missing.fields, hidden.fields)
            assert.are.equal(missing.__err, hidden.__err)
        end)

        it('creates nothing for an identifier the framework does not know', function()
            local result = open('char1:made-up')

            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, result.__err)
            assert.are.equal(0, #created)
        end)
    end)
end)
