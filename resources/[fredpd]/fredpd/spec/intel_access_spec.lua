--- The intelligence register's access control (4.5, invariant 4), end to end.
---
--- The register's permission opens the screen; it is not clearance for every
--- record on it. This runs the whole path -- the access service and
--- repository, the intel repository and its route handlers -- over a database
--- stub that answers the statements they send, because each claim here is
--- about the SQL, the filter and the shaping together:
---
---   * a record in a hidden compartment is answered as one that does not exist;
---   * two rows naming one hidden record are both hidden (the duplicate-id
---     case that once let a vehicle search through);
---   * a filtered list never carries a stub, and a tag filter or a count only
---     ever reaches notes the reader may read;
---   * counting writes no audit row for records nobody opened.

local helper = require('spec.helper')

describe('intel access', function()
    local routes, db, audit, session

    local function loadModule(path)
        assert(loadfile(('resources/[fredpd]/fredpd/%s.lua'):format(path)))()
    end

    local function copyAll(rows)
        local out = {}
        for index, row in ipairs(rows) do
            local copy = {}
            for key, value in pairs(row) do copy[key] = value end
            out[index] = copy
        end
        return out
    end

    --- Answers the statements the intel and access repositories send.
    local function makeDb()
        local fake = {
            statements = {},
            persons = {},
            notes = {},
            tagged = {},
            tagUses = {},
            notesUnder = {},
            searchRows = {},
            -- compartments[recordType][id] = { names }
            compartments = {},
        }

        local function compartmentRows(values)
            local byId = fake.compartments[values[1]] or {}
            local out = {}
            for index = 2, #values do
                for _, name in ipairs(byId[values[index]] or {}) do
                    out[#out + 1] = { recordId = values[index], compartment = name }
                end
            end
            return out
        end

        local function answer(sql, values)
            if sql:find('fpd_record_compartments', 1, true) then return compartmentRows(values) end
            if sql:find('fpd_record_seals', 1, true) then return {} end
            if sql:find('fpd_record_grants', 1, true) then return {} end
            if sql:find('fpd_breakglass', 1, true) then return {} end
            if sql:find('UNION ALL', 1, true) then return copyAll(fake.searchRows) end
            if sql:find('SELECT t.tag, n.id', 1, true) then return copyAll(fake.tagUses) end
            if sql:find('AS parentId, n.classification', 1, true) then return copyAll(fake.tagged) end
            if sql:find('AS parentId, classification, created_at', 1, true) then return copyAll(fake.notesUnder) end
            if sql:find('FROM fpd_intel_note_tags WHERE note_id IN', 1, true) then return {} end
            if sql:find('FROM fpd_intel_notes n', 1, true) then return copyAll(fake.notes) end
            if sql:find('p.master_person_id = ?', 1, true) then
                return fake.byMaster and copyAll({ fake.byMaster }) or {}
            end
            if sql:find('AND p.id = ?', 1, true) then
                for _, person in ipairs(fake.persons) do
                    if person.id == values[2] then return copyAll({ person }) end
                end
                return {}
            end
            if sql:find('FROM fpd_intel_persons p', 1, true) then return copyAll(fake.persons) end

            return {}
        end

        function fake.query(sql, values)
            fake.statements[#fake.statements + 1] = { sql = sql, values = values }
            return answer(sql, values or {})
        end

        function fake.single(sql, values) return fake.query(sql, values)[1] end
        function fake.execute() return 1 end
        function fake.insert() return 1 end
        function fake.transaction() return true end

        return fake
    end

    local function sent(fragment)
        for _, statement in ipairs(db.statements) do
            if statement.sql:find(fragment, 1, true) then return true end
        end
        return false
    end

    local function person(id, fields)
        local row = { id = id, name = 'Person ' .. id, status = 'active', classification = 'internal', version = 1 }
        for key, value in pairs(fields or {}) do row[key] = value end
        return row
    end

    before_each(function()
        _G.FredPD = {}

        db = makeDb()
        audit = {}

        FredPD.Core = {
            db = db,
            audit = { write = function(entry) audit[#audit + 1] = entry end },
            perms = {
                satisfies = function(effective, required) return effective[required] == true end,
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
        loadModule('server/modules/intel/service')
        loadModule('server/modules/intel/repo')
        loadModule('server/modules/intel/routes')

        -- The shipped policy: `sources` is hidden, `narcotics` is stubbed.
        FredPD.Modules.access.resetConfiguration()

        session = helper.session({
            permissions = {
                ['intel.person.view'] = true,
                ['intel.report.view'] = true,
                ['clearance.internal'] = true,
            },
        })
    end)

    local function call(name, input)
        return routes[name].handler(session, input or {})
    end

    describe('a single read', function()
        before_each(function()
            db.persons = { person(7), person(8), person(9) }
            db.compartments.intel_person = { [7] = { 'sources' }, [9] = { 'narcotics' } }
        end)

        it('answers a record in a hidden compartment exactly as one that does not exist', function()
            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, call('intel.person.get', { id = 7 }).__err)
            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, call('intel.person.get', { id = 404 }).__err)
        end)

        it('says a record in a stubbed compartment is restricted', function()
            assert.are.equal(FredPD.ErrorCode.RESTRICTED, call('intel.person.get', { id = 9 }).__err)
        end)

        it('refuses a write to a hidden record as not found, before touching it', function()
            local result = call('intel.person.delete', { id = 7 })

            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, result.__err)
            assert.is_false(sent('DELETE FROM fpd_intel_persons'))
        end)

        it('audits the refused read (invariant 11)', function()
            call('intel.person.get', { id = 7 })

            local refused = false
            for _, entry in ipairs(audit) do
                if entry.action == 'access.read' and entry.outcome == 'denied' then refused = true end
            end
            assert.is_true(refused)
        end)
    end)

    describe('linking a master person', function()
        before_each(function()
            session.permissions['intel.person.edit'] = true
            db.persons = { person(8, { version = 3 }) }
            FredPD.Repo.persons = {
                readPerson = function() return { id = 500 }, 'full' end,
            }
        end)

        it('never says a hidden intelligence file is already linked to the person', function()
            -- Subject 7, in `sources`, is already linked to master person 500.
            db.byMaster = person(7, { masterPersonId = 500 })
            db.compartments.intel_person = { [7] = { 'sources' } }

            local result = call('intel.person.linkMaster', { id = 8, version = 3, masterPersonId = 500 })

            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, result.__err)
            assert.are.equal('unknown', result.fields.masterPersonId)
            assert.is_false(sent('UPDATE fpd_intel_persons'))
        end)

        it('says so when the reader may read the file already linked', function()
            db.byMaster = person(7, { masterPersonId = 500 })

            local result = call('intel.person.linkMaster', { id = 8, version = 3, masterPersonId = 500 })

            assert.are.equal(FredPD.ErrorCode.CONFLICT, result.__err)
            assert.are.equal('already_linked', result.fields.masterPersonId)
        end)

        it('answers a hidden master person as an unknown one', function()
            FredPD.Repo.persons.readPerson = function() return nil, 'hidden' end

            local result = call('intel.person.linkMaster', { id = 8, version = 3, masterPersonId = 500 })

            assert.are.equal(FredPD.ErrorCode.NOT_FOUND, result.__err)
            assert.are.equal('unknown', result.fields.masterPersonId)
        end)
    end)

    describe('search', function()
        it('hides every vehicle on a hidden person, however many match', function()
            db.compartments.intel_person = { [7] = { 'sources' } }
            db.searchRows = {
                { kind = 'vehicle', id = 1, title = 'ABC123', ownerId = 7, classification = 'internal' },
                { kind = 'vehicle', id = 2, title = 'ABC124', ownerId = 7, classification = 'internal' },
                { kind = 'vehicle', id = 3, title = 'ABC125', ownerId = 8, classification = 'internal' },
            }

            local results = call('intel.search', { term = 'abc' }).results

            assert.are.equal(1, #results)
            assert.are.equal('ABC125', results[1].title)
            -- What the filter needed stays on the server.
            assert.is_nil(results[1].ownerId)
            assert.is_nil(results[1].classification)
        end)
    end)

    describe('the access layer', function()
        it('gives every row naming one record its compartments, not only the last', function()
            db.compartments.intel_person = { [7] = { 'sources' } }
            local rows = FredPD.Repo.access.filterSearch(session, 'intel_person', {
                { id = 7, classification = 'internal' },
                { id = 7, classification = 'internal' },
            })

            assert.are.equal(0, #rows)
        end)

        it('answers a count without an audit row', function()
            db.compartments.intel_note = { [2] = { 'narcotics' } }
            local ids = FredPD.Repo.access.readableIds(session, 'intel_note', {
                { id = 1, classification = 'internal' },
                { id = 2, classification = 'internal' },
            })

            assert.is_true(ids[1])
            assert.is_nil(ids[2])
            assert.are.equal(0, #audit)
        end)
    end)

    describe('the log', function()
        before_each(function()
            db.notes = {
                { id = 60, body = 'Black van', source = 'patrol', confidence = 'medium', classification = 'internal' },
                { id = 61, body = 'Handler meeting', source = 'patrol', confidence = 'high', classification = 'internal' },
            }
            db.compartments.intel_note = { [61] = { 'narcotics' } }
        end)

        it('stubs a note the reader may not open in the unfiltered log', function()
            local notes = call('intel.note.list').notes

            assert.are.equal(2, #notes)
            assert.is_true(notes[2].restricted)
            assert.is_nil(notes[2].body)
        end)

        it('never carries a stub in a filtered log', function()
            for _, filter in ipairs({ { tag = 'weapons' }, { search = 'handler' }, { confidence = 'high' } }) do
                local notes = call('intel.note.list', filter).notes
                assert.are.equal(1, #notes)
                assert.are.equal(60, notes[1].id)
            end
        end)

        it('refuses to filter by a protected source for a reader who may not see sources', function()
            local result = call('intel.note.list', { source = 'informant' })

            assert.are.equal(FredPD.ErrorCode.FORBIDDEN, result.__err)
            assert.are.equal('not_allowed', result.fields.source)
        end)
    end)

    describe('tags', function()
        it('counts only notes the reader may read, and audits no read', function()
            db.tagUses = {
                { tag = 'weapons', id = 60, classification = 'internal' },
                { tag = 'operation-x', id = 61, classification = 'internal' },
            }
            db.compartments.intel_note = { [61] = { 'narcotics' } }

            local tags = call('intel.tags').tags

            assert.are.same({ { tag = 'weapons', uses = 1 } }, tags)
            assert.are.equal(0, #audit)
        end)
    end)

    describe('a list filtered by tag', function()
        it('finds nobody through a tag used only on notes the reader may not read', function()
            db.persons = { person(8) }
            db.tagged = { { id = 61, parentId = 8, classification = 'secret' } }

            local result = call('intel.person.list', { tag = 'operation-x' })

            assert.are.same({}, result.persons)
            -- The people list itself was never asked.
            assert.is_false(sent('GROUP_CONCAT'))
        end)
    end)

    describe('counts on a list', function()
        it('counts only the notes the reader may read', function()
            db.persons = { person(8) }
            db.notesUnder = {
                { id = 60, parentId = 8, classification = 'internal', createdAt = 100 },
                { id = 61, parentId = 8, classification = 'internal', createdAt = 200 },
            }
            db.compartments.intel_note = { [61] = { 'sources' } }

            local persons = call('intel.person.list').persons

            assert.are.equal(1, persons[1].noteCount)
            -- The latest note is the latest the reader may read, not the hidden one.
            assert.are.equal(100, persons[1].lastNoteAt)
        end)

        it('never decorates a stub', function()
            db.persons = { person(9) }
            db.compartments.intel_person = { [9] = { 'narcotics' } }

            local persons = call('intel.person.list').persons

            assert.is_true(persons[1].restricted)
            assert.is_nil(persons[1].noteCount)
        end)
    end)
end)
