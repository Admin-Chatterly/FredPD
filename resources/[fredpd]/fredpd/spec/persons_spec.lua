--- The master name index (spec 7.2, 7.3) -- and the two access controls on it.
---
--- The persons module is the first consumer of `server/modules/access`, so this
--- spec runs the whole path rather than the pure half of it: the access service,
--- the access repository, the persons repository and the route handlers, over a
--- database stub that answers the statements they actually send. That is what
--- makes the interesting assertions possible -- "a restricted person leaves no
--- trace in a search result" is a claim about the SQL, the filtering and the
--- shaping together, and each of them in isolation looks fine.
---
--- The two controls under test are different things and are tested apart:
---
---   * **Record-level** (4.5): a person in a compartment the reader is not in is
---     absent from the result set. Not hidden in the interface, not returned as
---     an id with the fields blanked -- absent. This is the acceptance criterion
---     for M2 and it is asserted by walking the entire answer for any mention of
---     the record, keys included.
---   * **Field-level** (4.5): a reader without `fields.mental_health.view` sees
---     the person and does not see that a mental-health caution is on the file.

local helper = require('spec.helper')

describe('persons', function()
    local routes, db, audit, session

    --- Loads one file into the current global namespace.
    local function loadModule(path)
        assert(loadfile(('resources/[fredpd]/fredpd/%s.lua'):format(path)))()
    end

    --- A shallow copy, so a handler that mutates a row cannot change the
    --- fixture the next assertion reads.
    local function copy(row)
        local out = {}
        for key, value in pairs(row) do out[key] = value end

        return out
    end

    local function copyAll(rows)
        local out = {}
        for index = 1, #rows do out[index] = copy(rows[index]) end

        return out
    end

    --- The database stub.
    ---
    --- Answers by matching a distinctive fragment of each statement, in order,
    --- and records every statement it was sent -- which is how the
    --- parameterization assertion below can check that no search term ever
    --- reached the SQL text itself.
    local function makeDb()
        local fake = {
            statements = {},
            persons = {},
            cautions = {},
            compartments = {},
            inserts = {},
        }

        local function answer(sql)
            if sql:find('fpd_record_compartments', 1, true) then return fake.compartments end
            if sql:find('fpd_record_seals', 1, true) then return {} end
            if sql:find('fpd_record_grants', 1, true) then return {} end
            if sql:find('fpd_breakglass', 1, true) then return {} end
            if sql:find('FROM fpd_person_cautions', 1, true) then return copyAll(fake.cautions) end
            if sql:find('a.agency_id = ? AND a.person_id = ?', 1, true) then return {} end
            if sql:find('FROM fpd_person_descriptors', 1, true) then return {} end
            if sql:find('FROM fpd_person_photos', 1, true) then return {} end
            if sql:find('FROM fpd_person_biometrics_index', 1, true) then return {} end
            if sql:find('FROM fpd_vehicles', 1, true) then return {} end
            if sql:find('FROM fpd_firearms', 1, true) then return {} end
            if sql:find('FROM fpd_persons p', 1, true) then return copyAll(fake.persons) end

            return {}
        end

        function fake.query(sql, values)
            fake.statements[#fake.statements + 1] = { sql = sql, values = values }

            return answer(sql)
        end

        function fake.single(sql, values)
            return fake.query(sql, values)[1]
        end

        function fake.scalar(sql, values)
            fake.query(sql, values)

            return nil
        end

        function fake.execute(sql, values)
            fake.statements[#fake.statements + 1] = { sql = sql, values = values }

            return 1
        end

        function fake.insert(sql, values)
            fake.statements[#fake.statements + 1] = { sql = sql, values = values }
            fake.inserts[#fake.inserts + 1] = { sql = sql, values = values }

            return 7001
        end

        function fake.transaction()
            return true
        end

        return fake
    end

    --- The statement whose SQL contains `fragment`, or nil.
    local function statementWith(fragment)
        for index = 1, #db.statements do
            if db.statements[index].sql:find(fragment, 1, true) then return db.statements[index] end
        end

        return nil
    end

    --- Is `needle` anywhere in `value` -- as a value, as a key, at any depth?
    ---
    --- The same walk `access_spec` uses. Checking the three fields somebody
    --- remembered to check is not the assertion that matters; "nothing of this
    --- record is anywhere in the answer" is.
    local function mentions(value, needle)
        if value == needle then return true end
        if type(value) == 'string' then return value:find(tostring(needle), 1, true) ~= nil end
        if type(value) ~= 'table' then return false end

        for key, entry in pairs(value) do
            if type(key) ~= 'number' and mentions(key, needle) then return true end
            if mentions(entry, needle) then return true end
        end

        return false
    end

    --- A person row as `fpd_persons` hands one over.
    local function personRow(fields)
        local row = {
            id = 1,
            agencyId = 'lspd',
            personNumber = 'P-000431',
            firstName = 'Karl',
            lastName = 'Johansson',
            dateOfBirth = '1989-04-02',
            sex = 'male',
            phone = '555-0134',
            address = 'Vinewood Boulevard 14',
            classification = 'internal',
            version = 1,
        }

        for key, value in pairs(fields or {}) do
            row[key] = value ~= helper.NONE and value or nil
        end

        return row
    end

    before_each(function()
        _G.FredPD = {}

        db = makeDb()
        audit = {}

        FredPD.Core = {
            db = db,

            audit = {
                write = function(entry) audit[#audit + 1] = entry end,
                denied = function() end,
            },

            perms = {
                -- Exact keys only. The real implementation also honours a
                -- wildcard in the grant; nothing here needs one, and a spec that
                -- quietly grants more than it says would be worse than useless.
                satisfies = function(effective, required)
                    return effective[required] == true
                end,
                memberRoles = function() return {} end,
            },

            route = {
                define = function(definition) routes[definition.name] = definition end,
                refuse = function(code, fields) return { __err = code, fields = fields } end,
            },
        }

        routes = {}

        loadModule('shared/generated/schema')
        loadModule('server/modules/access/service')
        loadModule('server/modules/access/repo')
        loadModule('server/modules/persons/repo')
        loadModule('server/modules/persons/routes')

        FredPD.Modules.access.resetConfiguration()

        -- The population register reads the framework's own tables, which
        -- this spec does not fake: it answers nothing here, and
        -- `population_spec` covers it.
        FredPD.Modules.populationSearch = {
            characters = function() return {} end,
            vehicles = function() return {} end,
        }

        -- An ordinary patrol officer from Appendix C: the records permission and
        -- internal clearance, which is the floor for a record that carries no
        -- classification of its own.
        session = helper.session({
            permissions = { ['rms.person.view'] = true, ['clearance.internal'] = true },
        })
    end)

    --- Runs a route's handler as the route layer would, after validation.
    local function call(name, input)
        return routes[name].handler(session, input or {})
    end

    -- =========================================================================
    -- The search itself (7.2)
    -- =========================================================================

    describe('search', function()
        it('finds nothing worth searching for in a one-character term', function()
            local result = call('person.search', { term = 'k' })

            assert.equals(FredPD.ErrorCode.INVALID, result.__err)
        end)

        it('never puts the term in the SQL text, only in the values', function()
            db.persons = { personRow() }

            call('person.search', { term = 'johansson' })

            local search = statementWith('FROM fpd_persons p')
            assert.is_not_nil(search)
            assert.is_nil(search.sql:find('johansson', 1, true))

            local found = false
            for index = 1, #search.values do
                if search.values[index] == 'johansson' then found = true end
            end

            assert.is_true(found)
        end)

        it('strips LIKE wildcards rather than escaping them', function()
            -- `%` would otherwise match every person on file, and an `ESCAPE`
            -- clause is refused outright by a server running with
            -- NO_BACKSLASH_ESCAPES -- a setting FredPD does not control.
            local terms = FredPD.Repo.persons.parseTerm('jo%ha_nsson')

            assert.equals('jo ha nsson', terms.full)
        end)

        it('searches phonetically and partially, both ways round', function()
            db.persons = { personRow() }

            call('person.search', { term = 'karl johansson' })

            local sql = statementWith('FROM fpd_persons p').sql

            assert.is_not_nil(sql:find('SOUNDEX', 1, true))
            assert.is_not_nil(sql:find('p.name_normalized LIKE ?', 1, true))
            assert.is_not_nil(sql:find('alias_soundex', 1, true))
            assert.is_not_nil(sql:find('ORDER BY matchScore DESC', 1, true))
        end)

        it('logs every query, including one that found nothing', function()
            local result = call('person.search', { term = 'nobody here' })

            assert.equals(0, #result.persons)

            local logged = statementWith('INSERT INTO fpd_query_log')
            assert.is_not_nil(logged)
            assert.equals('person', logged.values[5])
            assert.equals('nobody here', logged.values[6])
        end)
    end)

    -- =========================================================================
    -- Record-level access on the result set (invariant 4, the M2 criterion)
    -- =========================================================================

    describe('access filtering', function()
        it('leaves no trace of a person in a compartment the reader is not in', function()
            db.persons = {
                personRow(),
                personRow({ id = 512, firstName = 'Marko', lastName = 'Petrov', personNumber = 'P-000512' }),
            }

            -- `sources` is configured hidden rather than stubbed: for that
            -- compartment the *existence* of the record is the sensitive part.
            db.compartments = { { recordId = 512, compartment = 'sources' } }

            local result = call('person.search', { term = 'petrov' })

            -- The id is deliberately one no other value in the answer contains
            -- as a substring: the walk below compares numbers against strings
            -- too, and an id of 2 would match the 2 in a date of birth and
            -- assert nothing.
            assert.is_false(mentions(result, 'Petrov'))
            assert.is_false(mentions(result, 'P-000512'))
            assert.is_false(mentions(result, 512))
        end)

        it('shows a stub, with no id and no name, for a stubbed compartment', function()
            db.persons = { personRow({ id = 512, firstName = 'Marko', lastName = 'Petrov' }) }
            db.compartments = { { recordId = 512, compartment = 'narcotics' } }

            local result = call('person.search', { term = 'petrov' })

            assert.equals(1, #result.persons)
            assert.is_true(result.persons[1].restricted)
            assert.equals('narcotics', result.persons[1].contact)
            assert.is_nil(result.persons[1].id)
            assert.is_false(mentions(result, 'Petrov'))
        end)

        it('withholds a restricted record from a cleared reader who gave no reason', function()
            db.persons = { personRow({ classification = 'restricted' }) }
            session.permissions['clearance.restricted'] = true

            local result = call('person.search', { term = 'johansson' })

            assert.equals(0, #result.persons)
            assert.is_true(result.restrictedWithheld)
        end)

        it('includes it once a case number is given, and marks the query log', function()
            db.persons = { personRow({ classification = 'restricted' }) }
            session.permissions['clearance.restricted'] = true

            local result = call('person.search', { term = 'johansson', caseNumber = 'LSPD-C26-00045' })

            assert.equals(1, #result.persons)
            assert.is_false(result.restrictedWithheld)

            local logged = statementWith('INSERT INTO fpd_query_log')
            assert.equals(1, logged.values[8])
            assert.equals('LSPD-C26-00045', logged.values[10])
        end)

        it('audits the read of a restricted record, allowed or refused', function()
            -- `secret` rather than `confidential`: the shipped policy stubs
            -- everything below secret, and a stub is an answer rather than a
            -- refusal. This test is about the refusal.
            db.persons = { personRow({ classification = 'secret' }) }

            local result = call('person.get', { id = 1 })

            assert.equals(FredPD.ErrorCode.NOT_FOUND, result.__err)

            local read = nil
            for index = 1, #audit do
                if audit[index].action == 'access.read' then read = audit[index] end
            end

            assert.is_not_nil(read)
            assert.equals('denied', read.outcome)
            assert.equals('person', read.subjectType)
        end)
    end)

    -- =========================================================================
    -- Field-level access (4.5)
    -- =========================================================================

    describe('field-level redaction', function()
        before_each(function()
            db.persons = { personRow() }
            db.cautions = {
                { id = 11, personId = 1, kind = 'officer_safety', classification = 'internal' },
                {
                    id = 12, personId = 1, kind = 'mental_health', fieldKey = 'mental_health',
                    detail = 'Crisis team requested in March', classification = 'internal',
                },
            }
        end)

        --- The kinds of caution a result carries, in order.
        local function kinds(list)
            local out = {}
            for index = 1, #list do out[index] = list[index].kind end

            return out
        end

        it('hides the mental-health caution entirely from a reader without the field', function()
            local result = call('person.get', { id = 1 })

            assert.same({ 'officer_safety' }, kinds(result.cautions))
            assert.is_false(mentions(result, 'mental_health'))
            assert.is_false(mentions(result, 'Crisis team requested in March'))
        end)

        it('shows it to a reader who holds fields.mental_health.view', function()
            session.permissions['fields.mental_health.view'] = true

            local result = call('person.get', { id = 1 })

            assert.same({ 'officer_safety', 'mental_health' }, kinds(result.cautions))
        end)

        it('hides it in search results too, where a list is easiest to leak from', function()
            local result = call('person.search', { term = 'johansson' })

            assert.same({ 'officer_safety' }, kinds(result.persons[1].cautions))
            assert.is_false(mentions(result, 'mental_health'))
        end)

        it('withholds a caution classified above the reader', function()
            db.cautions = {
                { id = 13, personId = 1, kind = 'gang', classification = 'confidential' },
            }

            local result = call('person.get', { id = 1 })

            assert.equals(0, #result.cautions)
        end)

        it('withholds the address without fields.victim_address.view', function()
            local result = call('person.get', { id = 1 })

            assert.is_nil(result.person.address)
            assert.is_true(result.person.addressRestricted)
        end)

        it('sends the address to a reader who holds the field', function()
            session.permissions['fields.victim_address.view'] = true

            local result = call('person.get', { id = 1 })

            assert.equals('Vinewood Boulevard 14', result.person.address)
        end)
    end)

    -- =========================================================================
    -- Writes
    -- =========================================================================

    describe('editing', function()
        before_each(function()
            db.persons = { personRow() }
            session.permissions['rms.person.edit'] = true
            session.permissions['rms.person.caution.edit'] = true
        end)

        it('refuses an address written by somebody who may not read it', function()
            local result = call('person.update', { id = 1, version = 1, address = 'Grove Street 12' })

            assert.equals(FredPD.ErrorCode.FORBIDDEN, result.__err)
            assert.equals('field_forbidden', result.fields.address)
        end)

        it('refuses to classify a record above the editor\'s own clearance', function()
            local result = call('person.update', { id = 1, version = 1, classification = 'secret' })

            assert.equals(FredPD.ErrorCode.FORBIDDEN, result.__err)
        end)

        it('never lets a column name arrive from input', function()
            call('person.update', { id = 1, version = 1, lastName = 'Johanson' })

            local update = statementWith('UPDATE fpd_persons')
            assert.is_not_nil(update)
            assert.is_not_nil(update.sql:find('`last_name`', 1, true))
            assert.is_not_nil(update.sql:find('AND version = ?', 1, true))
        end)

        it('refuses a mental-health caution from somebody who could not read it', function()
            local result = call('person.caution.set', { personId = 1, kind = 'mental_health' })

            assert.equals(FredPD.ErrorCode.FORBIDDEN, result.__err)
        end)

        it('sets the field key itself, from the kind', function()
            session.permissions['fields.mental_health.view'] = true

            call('person.caution.set', {
                personId = 1, kind = 'mental_health', detail = 'Crisis plan on file', expiresInDays = 90,
            })

            local insert = statementWith('INSERT INTO fpd_person_cautions')
            assert.is_not_nil(insert)
            assert.equals('mental_health', insert.values[3])
            assert.equals('mental_health', insert.values[5])
            assert.equals(90, insert.values[8])
        end)

        it('lets the database decide when a caution expires, not the client', function()
            call('person.caution.set', { personId = 1, kind = 'armed', expiresInDays = 30 })

            local insert = statementWith('INSERT INTO fpd_person_cautions')
            assert.is_not_nil(insert.sql:find('DATE_ADD(NOW(3), INTERVAL ? DAY)', 1, true))
        end)
    end)
end)
