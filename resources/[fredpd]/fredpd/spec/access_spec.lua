--- Record-level access (spec 4.5, invariant 4).
---
--- This is the module every read in the suite passes through, so this file is
--- deliberately the most exhaustive spec in the repository. The clearance
--- comparison is tested as a full matrix rather than at a few points, because
--- an off-by-one there is silent: everything keeps working and one level too
--- many can read everything.
---
--- The last block is the acceptance criterion for M2. A search that reveals a
--- restricted record *exists* is a leak even when it hides the contents, so
--- those tests do not check fields one by one -- they walk the entire returned
--- value, keys included, and assert that nothing of a hidden record is anywhere
--- in it.

local helper = require('spec.helper')

describe('access', function()
    local access

    before_each(function()
        access = helper.load({ 'server/modules/access/service' }).Modules.access
        access.resetConfiguration()
    end)

    --- A reader built the way the server builds one: from a session whose
    --- permissions came from Discord.
    local function officer(permissions, extra)
        return access.reader(helper.session({ permissions = permissions or {} }), extra)
    end

    --- A record in the reader's own agency unless told otherwise.
    local function record(fields)
        local row = {
            id = 42,
            recordType = 'person',
            agencyId = 'lspd',
            classification = 'internal',
            name = 'Marko Petrov',
        }

        for key, value in pairs(fields or {}) do
            row[key] = value ~= helper.NONE and value or nil
        end

        return row
    end

    --- Is `needle` anywhere in `value` -- as a value, as a key, at any depth?
    ---
    --- Used to prove a hidden record left no trace at all, rather than proving
    --- that the three fields somebody remembered to check are absent.
    local function mentions(value, needle)
        if value == needle then return true end
        if type(value) == 'string' then return value:find(tostring(needle), 1, true) ~= nil end
        if type(value) ~= 'table' then return false end

        for key, entry in pairs(value) do
            -- A numeric key is a list position rather than data, so it is
            -- walked but not itself compared; every other key is a field name
            -- and a field name can leak just as well as a value.
            if type(key) ~= 'number' and mentions(key, needle) then return true end
            if mentions(entry, needle) then return true end
        end

        return false
    end

    -- -------------------------------------------------------------------------
    -- The scale
    -- -------------------------------------------------------------------------

    describe('clearanceRank', function()
        it('orders the five levels', function()
            local levels = { 'open', 'internal', 'restricted', 'confidential', 'secret' }

            for index = 2, #levels do
                assert.is_true(access.clearanceRank(levels[index]) > access.clearanceRank(levels[index - 1]))
            end
        end)

        it('has no rank for anything that is not a level', function()
            -- nil is a real answer, and every caller treats it as "refuse". A
            -- level nobody recognises is a typo or one an administrator
            -- removed while records still carry it.
            assert.is_nil(access.clearanceRank('topsecret'))
            assert.is_nil(access.clearanceRank('Secret'))
            assert.is_nil(access.clearanceRank(''))
            assert.is_nil(access.clearanceRank(nil))
            assert.is_nil(access.clearanceRank(3))
            assert.is_nil(access.clearanceRank({ 'secret' }))
        end)

        it('agrees with isLevel', function()
            assert.is_true(access.isLevel('restricted'))
            assert.is_false(access.isLevel('restrictd'))
        end)
    end)

    describe('clearanceOf', function()
        it('is open when no clearance is held', function()
            -- The floor of the scale, not an absence of one: open records are
            -- open, and nothing else is.
            assert.are.equal('open', access.clearanceOf({}))
            assert.are.equal('open', access.clearanceOf(nil))
        end)

        it('takes the highest level held', function()
            assert.are.equal('confidential', access.clearanceOf({
                ['clearance.internal'] = true,
                ['clearance.confidential'] = true,
                ['clearance.restricted'] = true,
            }))
        end)

        it('ignores a level the permission set denies', function()
            assert.are.equal('open', access.clearanceOf({ ['clearance.secret'] = false }))
        end)

        it('is never granted by a wildcard', function()
            -- `Perms.satisfies` honours `rms.person.*`, and that is right
            -- there. Here it would make one careless `*` equal to secret
            -- clearance for everyone holding it.
            assert.are.equal('open', access.clearanceOf({ ['clearance.*'] = true }))
            assert.are.equal('open', access.clearanceOf({ ['*'] = true }))
        end)
    end)

    describe('compartmentsOf', function()
        it('reads membership off the permission set', function()
            local held = access.compartmentsOf({
                ['compartment.narcotics'] = true,
                ['compartment.sources'] = true,
                ['rms.person.view'] = true,
            })

            assert.is_true(held.narcotics)
            assert.is_true(held.sources)
            assert.is_nil(held['rms.person.view'])
        end)

        it('ignores a malformed key rather than inventing a compartment', function()
            local held = access.compartmentsOf({
                ['compartment.Narcotics'] = true,
                ['compartment.'] = true,
                ['compartment.a b'] = true,
            })

            assert.are.same({}, held)
        end)

        it('is never granted by a wildcard', function()
            assert.are.same({}, access.compartmentsOf({ ['compartment.*'] = true }))
        end)
    end)

    describe('reader', function()
        it('derives clearance and compartments from the session', function()
            local reader = officer({ ['clearance.restricted'] = true, ['compartment.homicide'] = true })

            assert.are.equal('restricted', reader.clearance)
            assert.is_true(reader.compartments.homicide)
            assert.are.equal('lspd', reader.agencyId)
            assert.are.equal('100000000000000001', reader.discordId)
        end)

        it('prefers what the session already carries (spec 4.6)', function()
            local session = helper.session({
                permissions = { ['clearance.open'] = true },
                clearance = 'secret',
                compartments = { 'sources' },
            })
            local reader = access.reader(session)

            assert.are.equal('secret', reader.clearance)
            assert.is_true(reader.compartments.sources)
        end)

        it('carries the seal-break permission and nothing else as authority', function()
            assert.is_false(officer({}).sealBreak)
            assert.is_true(officer({ [access.SEAL_PERMISSION] = true }).sealBreak)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- The read rule
    -- -------------------------------------------------------------------------

    describe('canRead', function()
        local LEVELS = { 'open', 'internal', 'restricted', 'confidential', 'secret' }

        it('allows a read exactly when clearance reaches the classification', function()
            -- The whole matrix, not three points on it. The boundary case --
            -- equal clearance and classification -- is allowed, and is the one
            -- an off-by-one breaks in either direction.
            for held = 1, #LEVELS do
                local reader = officer({ ['clearance.' .. LEVELS[held]] = true })

                for required = 1, #LEVELS do
                    local row = record({ classification = LEVELS[required] })
                    local expected = held >= required

                    assert.are.equal(expected, access.canRead(reader, row),
                        ('%s reading %s'):format(LEVELS[held], LEVELS[required]))
                end
            end
        end)

        it('refuses a classification nobody recognises, at any clearance', function()
            local reader = officer({ ['clearance.secret'] = true })

            assert.is_false(access.canRead(reader, record({ classification = 'cosmic' })))
            assert.is_false(access.canRead(reader, record({ classification = 'Secret' })))
            assert.is_false(access.canRead(reader, record({ classification = 42 })))
        end)

        it('treats a record with no classification as internal', function()
            local row = record({ classification = helper.NONE })

            assert.is_false(access.canRead(officer({}), row))
            assert.is_true(access.canRead(officer({ ['clearance.internal'] = true }), row))
        end)

        it('reads a record with no compartments at all on clearance alone', function()
            local reader = officer({ ['clearance.restricted'] = true })

            assert.is_true(access.canRead(reader, record({ classification = 'restricted' })))
            assert.is_true(access.canRead(reader, record({ classification = 'restricted', compartments = {} })))
        end)

        describe('compartments', function()
            local three = { 'homicide', 'narcotics', 'sources' }

            local function readerIn(names)
                local permissions = { ['clearance.secret'] = true }
                for index = 1, #names do permissions['compartment.' .. names[index]] = true end

                return officer(permissions)
            end

            it('allows a reader who is in every one of them', function()
                assert.is_true(access.canRead(readerIn(three), record({ compartments = three })))
            end)

            it('refuses a reader missing any single one of the three', function()
                -- Compartments are ANDed, so each of the three is tested as the
                -- one that is missing. Clearance is deliberately secret here:
                -- the only thing that can refuse is the compartment.
                for index = 1, #three do
                    local held = {}
                    for other = 1, #three do
                        if other ~= index then held[#held + 1] = three[other] end
                    end

                    assert.is_false(access.canRead(readerIn(held), record({ compartments = three })),
                        'missing ' .. three[index])
                    assert.are.same({ three[index] },
                        access.missingCompartments(readerIn(held), record({ compartments = three })))
                end
            end)

            it('refuses a reader in none of them', function()
                assert.is_false(access.canRead(readerIn({}), record({ compartments = three })))
            end)

            it('does not mind a reader in compartments the record is not in', function()
                assert.is_true(access.canRead(readerIn(three), record({ compartments = { 'narcotics' } })))
            end)

            it('accepts compartments as a list, a set or join rows', function()
                local reader = readerIn({ 'narcotics' })

                assert.is_true(access.canRead(reader, record({ compartments = { 'narcotics' } })))
                assert.is_true(access.canRead(reader, record({ compartments = { narcotics = true } })))
                assert.is_true(access.canRead(reader, record({
                    compartments = { { compartment = 'narcotics' } },
                })))
            end)
        end)

        describe('grants', function()
            local locked = { classification = 'secret', compartments = { 'sources' } }

            local function grant(fields)
                local row = record(locked)
                row.grants = { fields }

                return row
            end

            it('overrides insufficient clearance and a missing compartment', function()
                -- 4.5: "... or an explicit grant". A grant is the documented
                -- override of both halves of the rule, which is exactly why it
                -- has an expiry.
                local reader = officer({}, { now = 1000 })
                local row = grant({ subjectType = 'user', subjectId = '100000000000000001', expiresAt = 2000 })

                assert.is_false(access.canRead(reader, record(locked)))
                assert.is_true(access.canRead(reader, row))
            end)

            it('refuses an expired grant', function()
                local reader = officer({}, { now = 3000 })

                assert.is_false(access.canRead(reader,
                    grant({ subjectType = 'user', subjectId = '100000000000000001', expiresAt = 2999 })))
            end)

            it('refuses a grant expiring this very second', function()
                local reader = officer({}, { now = 3000 })

                assert.is_false(access.canRead(reader,
                    grant({ subjectType = 'user', subjectId = '100000000000000001', expiresAt = 3000 })))
            end)

            it('accepts a grant with no expiry', function()
                local reader = officer({}, { now = 3000 })

                assert.is_true(access.canRead(reader,
                    grant({ subjectType = 'user', subjectId = '100000000000000001' })))
            end)

            it('refuses a grant written for somebody else', function()
                local reader = officer({}, { now = 1000 })

                assert.is_false(access.canRead(reader,
                    grant({ subjectType = 'user', subjectId = '999999999999999999', expiresAt = 2000 })))
            end)

            it('accepts a grant to a Discord role the reader holds', function()
                local reader = officer({}, { now = 1000, roleIds = { '4001', 4002 } })

                assert.is_true(access.canRead(reader,
                    grant({ subjectType = 'role', subjectId = '4002', expiresAt = 2000 })))
                assert.is_false(access.canRead(reader,
                    grant({ subjectType = 'role', subjectId = '4003', expiresAt = 2000 })))
            end)

            it('never matches an anonymous grant', function()
                -- A grant with no subject would otherwise be a grant to
                -- everybody, and a reader with no Discord id would match it.
                local reader = access.reader({ agencyId = 'lspd', permissions = {} }, { now = 1000 })

                assert.is_false(access.canRead(reader, grant({ subjectType = 'user', expiresAt = 2000 })))
                assert.is_false(access.canRead(officer({}, { now = 1000 }),
                    grant({ subjectType = 'user', expiresAt = 2000 })))
            end)

            it('ignores a grant of an unknown subject type', function()
                local reader = officer({}, { now = 1000 })

                assert.is_false(access.canRead(reader,
                    grant({ subjectType = 'everyone', subjectId = '100000000000000001', expiresAt = 2000 })))
            end)

            it('reads a break-glass entry as a grant to the officer who took it', function()
                local reader = officer({}, { now = 1000 })

                assert.is_true(access.canRead(reader,
                    grant({ subjectType = 'breakglass', subjectId = '100000000000000001', expiresAt = 2000 })))
                assert.is_false(access.canRead(reader,
                    grant({ subjectType = 'breakglass', subjectId = '100000000000000001', expiresAt = 999 })))
            end)
        end)

        describe('a sealed record', function()
            local function sealed(extra)
                local row = record({ classification = 'open', sealed = true })
                for key, value in pairs(extra or {}) do row[key] = value end

                return row
            end

            it('is refused to the highest clearance in the agency', function()
                local reader = officer({
                    ['clearance.secret'] = true,
                    ['compartment.sources'] = true,
                    ['compartment.homicide'] = true,
                })

                assert.is_false(access.canRead(reader, sealed()))
            end)

            it('is refused even to a live grant', function()
                -- A court order not to disclose is not overcome by a grant
                -- somebody wrote before the court sealed the file.
                local reader = officer({}, { now = 1000 })

                assert.is_false(access.canRead(reader, sealed({
                    grants = { { subjectType = 'user', subjectId = '100000000000000001', expiresAt = 2000 } },
                })))
            end)

            it('opens only to the seal-break permission', function()
                assert.is_true(access.canRead(officer({ [access.SEAL_PERMISSION] = true }), sealed()))
            end)

            it('counts the several shapes a database says true in', function()
                assert.is_false(access.canRead(officer({}), record({ sealed = 1, classification = 'open' })))
                assert.is_false(access.canRead(officer({}), record({ is_sealed = true, classification = 'open' })))
                assert.is_true(access.canRead(officer({}), record({ sealed = 0, classification = 'open' })))
            end)
        end)

        describe('the owning agency', function()
            it('refuses another agency\'s record', function()
                assert.is_false(access.canRead(officer({ ['clearance.secret'] = true }),
                    record({ agencyId = 'bcso', classification = 'open' })))
            end)

            it('allows one the reader\'s agency has been shared', function()
                local reader = officer({}, { sharedAgencies = { 'bcso' } })

                assert.is_true(access.canRead(reader, record({ agencyId = 'bcso', classification = 'open' })))
            end)

            it('allows a record that belongs to no agency', function()
                assert.is_true(access.canRead(officer({}),
                    record({ agencyId = helper.NONE, classification = 'open' })))
            end)
        end)

        it('refuses when either side is missing', function()
            assert.is_false(access.canRead(nil, record()))
            assert.is_false(access.canRead(officer({}), nil))
            assert.is_false(access.canRead(officer({}), 'person 42'))
        end)
    end)

    describe('isRestricted', function()
        it('is false for the everyday levels', function()
            assert.is_false(access.isRestricted(record({ classification = 'open' })))
            assert.is_false(access.isRestricted(record({ classification = 'internal' })))
        end)

        it('is true for anything audited: restricted and above, compartmented, sealed', function()
            assert.is_true(access.isRestricted(record({ classification = 'restricted' })))
            assert.is_true(access.isRestricted(record({ classification = 'secret' })))
            assert.is_true(access.isRestricted(record({ compartments = { 'narcotics' } })))
            assert.is_true(access.isRestricted(record({ sealed = true })))
            assert.is_true(access.isRestricted(record({ classification = 'cosmic' })))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- What a refused reader is shown
    -- -------------------------------------------------------------------------

    describe('visibility', function()
        it('is full when the record can be read', function()
            assert.are.equal('full', access.visibility(officer({ ['clearance.internal'] = true }), record()))
        end)

        it('is a stub when the blocking compartment is configured to stub', function()
            local row = record({ classification = 'open', compartments = { 'narcotics' } })

            assert.are.equal('stub', access.visibility(officer({}), row))
        end)

        it('is hidden when the blocking compartment is configured to hide', function()
            local row = record({ classification = 'open', compartments = { 'sources' } })

            assert.are.equal('hidden', access.visibility(officer({}), row))
        end)

        it('lets the strictest compartment win', function()
            -- The reader who sees a stub learns the record exists, and
            -- `sources` is configured precisely so that nobody learns that.
            local row = record({ classification = 'open', compartments = { 'narcotics', 'sources' } })

            assert.are.equal('hidden', access.visibility(officer({}), row))
        end)

        it('hides a compartment nobody has configured', function()
            local row = record({ classification = 'open', compartments = { 'invented_by_hand' } })

            assert.are.equal('hidden', access.visibility(officer({}), row))
        end)

        it('stubs a record refused on its classification alone', function()
            assert.are.equal('stub', access.visibility(officer({}), record({ classification = 'restricted' })))
        end)

        it('hides a secret record rather than announcing it', function()
            assert.are.equal('hidden', access.visibility(officer({}), record({ classification = 'secret' })))
        end)

        it('hides a sealed record, unless the agency configures otherwise', function()
            local row = record({ classification = 'open', sealed = true })

            assert.are.equal('hidden', access.visibility(officer({}), row))

            access.configure({ sealedStub = true })
            assert.are.equal('stub', access.visibility(officer({}), row))
        end)

        it('hides another agency\'s record entirely', function()
            local row = record({ agencyId = 'bcso', classification = 'open' })

            assert.are.equal('hidden', access.visibility(officer({}), row))
        end)

        it('follows a reconfigured compartment policy', function()
            access.configure({ compartments = { sources = { stub = true, contact = 'rue' } } })

            local row = record({ classification = 'open', compartments = { 'sources' } })
            assert.are.equal('stub', access.visibility(officer({}), row))
            assert.are.equal('rue', access.stub(row, { 'sources' }).contact)
        end)

        it('hides anything it cannot judge', function()
            assert.are.equal('hidden', access.visibility(nil, record()))
            assert.are.equal('hidden', access.visibility(officer({}), nil))
        end)
    end)

    describe('stub', function()
        local row = record({
            classification = 'secret',
            compartments = { 'narcotics' },
            grants = { { subjectType = 'user', subjectId = '1' } },
        })

        it('carries three fields and no more', function()
            local stub = access.stub(row, { 'narcotics' })
            local keys = {}
            for key in pairs(stub) do keys[#keys + 1] = key end
            table.sort(keys)

            assert.are.same({ 'contact', 'recordType', 'restricted' }, keys)
        end)

        it('never carries anything that identifies the record', function()
            -- A reader who can pair a stub with an id can count records,
            -- correlate two searches and confirm a hunch about who is in a file.
            local stub = access.stub(row, { 'narcotics' })

            assert.is_nil(stub.id)
            assert.is_nil(stub.name)
            assert.is_nil(stub.agencyId)
            assert.is_nil(stub.classification)
            assert.is_nil(stub.compartments)
            assert.is_nil(stub.grants)
            assert.is_false(mentions(stub, 42))
            assert.is_false(mentions(stub, 'Marko Petrov'))
            assert.is_false(mentions(stub, 'secret'))
        end)

        it('names the unit that can actually help', function()
            assert.are.equal('narcotics', access.stub(row, { 'narcotics' }).contact)
            assert.are.equal('internal_affairs',
                access.stub(record({ compartments = { 'internal_affairs' } })).contact)
        end)

        it('falls back to the records unit', function()
            -- A compartment with no contact configured, and a record with no
            -- compartments at all, both send the reader to records rather than
            -- naming a unit that would itself be a disclosure.
            assert.are.equal('records', access.stub(record({ compartments = { 'intelligence' } })).contact)
            assert.are.equal('records', access.stub(record({ classification = 'restricted' })).contact)
        end)

        it('carries the record type only when it is a string', function()
            assert.are.equal('person', access.stub(record()).recordType)
            assert.is_nil(access.stub(record({ recordType = helper.NONE })).recordType)
            assert.is_nil(access.stub(record({ recordType = 7 })).recordType)
        end)

        it('is a contact key, never a sentence (invariant 6)', function()
            local contact = access.stub(row, { 'narcotics' }).contact

            assert.is_truthy(contact:match('^[a-z][a-z0-9_]*$'))
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Search: the acceptance criterion for M2 (invariant 4)
    -- -------------------------------------------------------------------------

    describe('filterSearchResults', function()
        local function rows()
            return {
                record({ id = 1, name = 'Anna Berg', classification = 'internal' }),
                record({ id = 2, name = 'Boris Karlsson', classification = 'open',
                         compartments = { 'narcotics' } }),
                record({ id = 3, name = 'Cecilia Dahl', classification = 'open',
                         compartments = { 'sources' } }),
                record({ id = 4, name = 'David Ek', classification = 'secret' }),
                record({ id = 5, name = 'Elsa Frid', agencyId = 'bcso', classification = 'open' }),
            }
        end

        local function readerAtInternal()
            return officer({ ['clearance.internal'] = true })
        end

        it('returns the rows the reader may read', function()
            local out = access.filterSearchResults(readerAtInternal(), rows())

            assert.are.equal('Anna Berg', out[1].name)
            assert.are.equal(1, out[1].id)
        end)

        it('returns a stub where the compartment says to stub', function()
            local out = access.filterSearchResults(readerAtInternal(), rows())

            assert.is_true(out[2].restricted)
            assert.are.equal('narcotics', out[2].contact)
        end)

        it('drops a hidden row without leaving a gap', function()
            -- Three of the five are hidden: the `sources` record, the secret
            -- one and the other agency's.
            local out = access.filterSearchResults(readerAtInternal(), rows())

            assert.are.equal(2, #out)
        end)

        it('never returns a field from a hidden record -- not an id, not a name', function()
            -- The acceptance criterion for M2. This walks the entire answer,
            -- keys included, at any depth: a leak added later as a nested field
            -- or a map keyed by id fails here, which is the point of not
            -- checking three fields by name.
            local out = access.filterSearchResults(readerAtInternal(), rows())

            for _, hidden in ipairs({ 'Cecilia Dahl', 'David Ek', 'Elsa Frid' }) do
                assert.is_false(mentions(out, hidden), hidden .. ' leaked into the results')
            end

            for _, id in ipairs({ 3, 4, 5 }) do
                assert.is_false(mentions(out, id), ('record %d leaked into the results'):format(id))
            end

            assert.is_false(mentions(out, 'bcso'))
            assert.is_false(mentions(out, 'sources'))
        end)

        it('never returns a count of what it dropped', function()
            -- A number meaning "there is something here you are not allowed to
            -- know about" is the same leak in a smaller package, so this
            -- function returns exactly one value, and that value is a list
            -- whose length is what came back.
            local returned = select('#', access.filterSearchResults(readerAtInternal(), rows()))

            assert.are.equal(1, returned)
        end)

        it('gives a reader with no clearance at all nothing but stubs', function()
            local out = access.filterSearchResults(officer({}), rows())

            -- Two survive and both are stubs: the internal record, refused on
            -- its classification, and the narcotics one, refused on its
            -- compartment. Neither carries a name, and the other three are
            -- gone entirely.
            assert.are.equal(2, #out)
            assert.is_true(out[1].restricted)
            assert.are.equal('records', out[1].contact)
            assert.is_true(out[2].restricted)
            assert.are.equal('narcotics', out[2].contact)

            assert.is_false(mentions(out, 'Anna Berg'))
            assert.is_false(mentions(out, 'Boris Karlsson'))
            assert.is_false(mentions(out, 1))
        end)

        it('opens a compartmented record to a reader inside the compartment', function()
            local reader = officer({
                ['clearance.internal'] = true,
                ['compartment.narcotics'] = true,
                ['compartment.sources'] = true,
            })
            local out = access.filterSearchResults(reader, rows())

            assert.are.equal(3, #out)
            assert.are.equal('Boris Karlsson', out[2].name)
            assert.are.equal('Cecilia Dahl', out[3].name)
        end)

        it('strips the grant list from a row it returns', function()
            -- A reader cleared for the record is not thereby cleared for the
            -- list of who else has been let into it.
            local row = record({ classification = 'open' })
            row.grants = { { subjectType = 'user', subjectId = '999999999999999999' } }

            local out = access.filterSearchResults(officer({}), { row })

            assert.are.equal(1, #out)
            assert.is_nil(out[1].grants)
            assert.is_false(mentions(out, '999999999999999999'))
            -- Stripped by copying, so the caller's row is untouched.
            assert.are.equal(1, #row.grants)
        end)

        it('does not mutate the rows it was given', function()
            local given = rows()
            access.filterSearchResults(readerAtInternal(), given)

            assert.are.equal(5, #given)
            assert.are.equal('Cecilia Dahl', given[3].name)
        end)

        it('answers an empty list for nothing to filter', function()
            assert.are.same({}, access.filterSearchResults(readerAtInternal(), {}))
            assert.are.same({}, access.filterSearchResults(readerAtInternal(), nil))
            assert.are.same({}, access.filterSearchResults(nil, rows()))
        end)

        it('hides every row when the reader is not a reader', function()
            assert.are.equal(0, #access.filterSearchResults({}, rows()))
        end)
    end)
end)
