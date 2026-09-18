--- The unified query and hot-file logic (spec 7.2).
---
--- Three things here are worth testing more than the rest, because the route is
--- a thin shell over them and a mistake in any of the three is silent:
---
---   * **type derivation**, because it decides which registers are read and
---     which permission each read needs. A term derived as the wrong kind
---     answers the wrong question and logs the wrong thing against the officer;
---   * **ranking**, because three registers are merged into one page and
---     `table.sort` is not stable -- a comparator that is not a total order
---     gives two different pages for the same search, which is unusable at a
---     roadside and looks like a database problem;
---   * **the hot file and the confirmation rules**, because they decide what
---     goes behind a red banner and what an officer is allowed to record having
---     been told. `hitIsLive` is the one that matters most: it is what stops a
---     cleared flag being confirmed after the fact.
---
--- The registry service is loaded alongside, because the query service asks it
--- for the VIN test and the two hot-file allowlists rather than keeping copies
--- that would drift (7.2, 7.4, 7.5).

local helper = require('spec.helper')

describe('query', function()
    local query

    before_each(function()
        query = helper.load({
            'server/modules/registry/service',
            'server/modules/query/service',
        }).Modules.query
    end)

    --- A VIN whose check digit agrees: the worked example from ISO 3779.
    local VIN <const> = '1M8GDM9AXKP042788'

    -- -------------------------------------------------------------------------
    describe('the six names', function()
        it('accepts the names migration 0005 stores', function()
            assert.are.equal('person', query.canonicalType('person'))
            assert.are.equal('plate', query.canonicalType('PLATE'))
            assert.are.equal('vin', query.canonicalType('vin'))
            assert.are.equal('firearm', query.canonicalType('firearm'))
            assert.are.equal('phone', query.canonicalType('phone'))
            assert.are.equal('address', query.canonicalType('address'))
        end)

        it('takes `serial`, which is what 7.2 calls a firearm query', function()
            -- The column stores `firearm` (`ck_fpd_query_log_type`, shipped), so
            -- the alias resolves rather than becoming a seventh value that would
            -- split every misuse search in half.
            assert.are.equal('firearm', query.canonicalType('serial'))
        end)

        it('refuses anything else', function()
            assert.is_nil(query.canonicalType('everything'))
            assert.is_nil(query.canonicalType(''))
            assert.is_nil(query.canonicalType(42))
            assert.is_nil(query.canonicalType(nil))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('the term', function()
        it('trims and collapses the whitespace inside', function()
            assert.are.equal('karl johansson', query.normalizeTerm('  karl   johansson '))
        end)

        it('removes the LIKE wildcards rather than escaping them', function()
            -- An `ESCAPE` clause fails outright on a server running
            -- NO_BACKSLASH_ESCAPES, and a search for `%` that matched every
            -- record is the failure this avoids.
            assert.are.equal('ab c', query.normalizeTerm('ab%_c'))
        end)

        it('refuses a term of one character', function()
            assert.is_nil(query.normalizeTerm('a'))
            assert.is_nil(query.normalizeTerm('  '))
            assert.is_nil(query.normalizeTerm(nil))
            assert.are.equal('ab', query.normalizeTerm(' ab '))
        end)

        it('pulls the digits out for the phone branch', function()
            assert.are.equal('5550134', query.digits('555-0134'))
            assert.are.equal('', query.digits('johansson'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('deriving the type', function()
        it('calls a valid VIN a VIN', function()
            assert.are.equal('vin', query.deriveType(VIN))
        end)

        it('does not call a seventeen-character typo a VIN', function()
            -- One character off fails the check digit, so it is read as the
            -- ambiguous alphanumeric case rather than opening somebody else's
            -- car by arithmetic nobody checked.
            assert.are.equal('plate', query.deriveType('1M8GDM9AXKP042789'))
        end)

        it('calls a run of digits a phone number', function()
            assert.are.equal('phone', query.deriveType('5550134'))
        end)

        it('calls a leading house number an address', function()
            assert.are.equal('address', query.deriveType('12 Alta Street'))
        end)

        it('calls two words, or one with no digit in it, a person', function()
            assert.are.equal('person', query.deriveType('karl johansson'))
            assert.are.equal('person', query.deriveType('johansson'))
        end)

        it('calls a single alphanumeric word a plate', function()
            assert.are.equal('plate', query.deriveType('ABC123'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('which registers a query reads', function()
        it('narrows to one when the officer says which', function()
            local queryType, sources, derived = query.plan('ABC123', 'plate')

            assert.are.equal('plate', queryType)
            assert.is_true(sources.vehicle)
            assert.is_nil(sources.person)
            assert.is_nil(sources.firearm)
            assert.is_false(derived)
        end)

        it('reads all three when the term is the ambiguous kind', function()
            -- `GLK178842` is a plate or a firearm serial and nothing tells them
            -- apart, so a derived query reads both -- and the name index too,
            -- because a person number looks the same.
            local queryType, sources, derived = query.plan('GLK178842', nil)

            assert.are.equal('plate', queryType)
            assert.is_true(sources.person)
            assert.is_true(sources.vehicle)
            assert.is_true(sources.firearm)
            assert.is_true(derived)
        end)

        it('keeps a VIN to the vehicle register', function()
            local _, sources = query.plan(VIN, nil)

            assert.is_true(sources.vehicle)
            assert.is_nil(sources.person)
        end)

        it('reads the name index and the plates for a phone number', function()
            local _, sources = query.plan('5550134', nil)

            assert.is_true(sources.person)
            assert.is_true(sources.vehicle)
            assert.is_nil(sources.firearm)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('permissions', function()
        it('gives a phone and an address their own keys', function()
            -- 7.2 lists five `query.<thing>.run` permissions and these two are
            -- separate on purpose: "who lives here" is a different question
            -- from "who is this person".
            assert.are.equal('query.phone.run', query.permissionFor('phone', 'person'))
            assert.are.equal('query.address.run', query.permissionFor('address', 'person'))
        end)

        it('otherwise follows the register being read', function()
            assert.are.equal('query.person.run', query.permissionFor('person', 'person'))
            assert.are.equal('query.vehicle.run', query.permissionFor('plate', 'vehicle'))
            assert.are.equal('query.vehicle.run', query.permissionFor('vin', 'vehicle'))
            assert.are.equal('query.firearm.run', query.permissionFor('firearm', 'firearm'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('ranking', function()
        local function context(term, queryType)
            return query.context(term, queryType or query.deriveType(term))
        end

        it('puts an exact identifier above a prefix', function()
            local exact = query.score(context('ABC123'), { kind = 'vehicle', id = 1, plate = 'ABC123' })
            local prefix = query.score(context('ABC123'), { kind = 'vehicle', id = 2, plate = 'ABC1234' })

            assert.is_true(exact > prefix)
        end)

        it('puts a VIN above the plate it is on', function()
            local vin = query.score(context(VIN), { kind = 'vehicle', id = 1, vin = VIN })
            local plate = query.score(context('ABC123'), { kind = 'vehicle', id = 1, plate = 'ABC123' })

            assert.is_true(vin > plate)
        end)

        it('ranks a person by number, then phone, then name', function()
            local term = context('karl johansson')

            local number = query.score(context('P-000431'), { kind = 'person', id = 1, personNumber = 'P-000431' })
            local phone = query.score(context('5550134'), { kind = 'person', id = 1, phone = '555-0134' })
            local exact = query.score(term, { kind = 'person', id = 1, firstName = 'Karl', lastName = 'Johansson' })
            local partial = query.score(term, {
                kind = 'person', id = 2, firstName = 'Karl', middleName = 'Erik', lastName = 'Johansson',
            })

            assert.is_true(number > phone)
            assert.is_true(phone > exact)
            assert.is_true(exact > partial)
        end)

        it('scores a stub as a stub', function()
            -- A stub has no fields to compare and still has to appear: it is
            -- the "restricted record -- contact <unit>" line of 4.5.
            assert.are.equal(
                query.STUB_SCORE,
                query.score(context('ABC123'), { kind = 'vehicle', restricted = true, contact = 'narcotics' })
            )
        end)

        it('merges the registers into one page, highest first', function()
            local rows = {
                { kind = 'firearm', id = 7, serial = 'GLK178842', score = 30 },
                { kind = 'vehicle', id = 3, plate = 'ABC123', score = 95 },
                { kind = 'person', id = 9, lastName = 'Johansson', score = 60 },
            }

            local page = query.rank(rows, 10)

            assert.are.equal(3, #page)
            assert.are.equal('vehicle', page[1].kind)
            assert.are.equal('person', page[2].kind)
            assert.are.equal('firearm', page[3].kind)
        end)

        it('orders a tie the same way every time', function()
            -- `table.sort` is not stable, so a comparator that stopped at the
            -- score would give two different pages for one search.
            local function page()
                return query.rank({
                    { kind = 'vehicle', id = 2, plate = 'BBB222', score = 70 },
                    { kind = 'vehicle', id = 1, plate = 'AAA111', score = 70 },
                    { kind = 'firearm', id = 5, serial = 'AAA111', score = 70 },
                }, 10)
            end

            local first, second = page(), page()

            for index = 1, #first do
                assert.are.equal(first[index].kind, second[index].kind)
                assert.are.equal(first[index].id, second[index].id)
            end

            -- The register breaks the tie first, then the label.
            assert.are.equal('firearm', first[1].kind)
            assert.are.equal('AAA111', first[2].plate)
            assert.are.equal('BBB222', first[3].plate)
        end)

        it('cuts the page to what was asked for', function()
            local rows = {}
            for index = 1, 10 do
                rows[index] = { kind = 'vehicle', id = index, plate = 'P' .. index, score = index }
            end

            assert.are.equal(3, #query.rank(rows, 3))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('hot-file hits', function()
        it('raises a hit only for the flags the register calls hot', function()
            local hits = query.vehicleHits({
                { id = 11, kind = 'stolen' },
                { id = 12, kind = 'impounded' },
                { id = 13, kind = 'bolo' },
            }, 3)

            assert.are.equal(2, #hits)
            assert.are.equal('stolen', hits[1].kind)
            assert.are.equal('vehicle_flag', hits[1].hitType)
            assert.are.equal(11, hits[1].hitId)
            assert.are.equal('vehicle', hits[1].recordType)
            assert.are.equal(3, hits[1].recordId)
            assert.are.equal('bolo', hits[2].kind)
        end)

        it('raises a hit on a lost or stolen firearm and on nothing else', function()
            assert.are.equal(1, #query.firearmHits({ id = 7, status = 'stolen' }))
            assert.are.equal(0, #query.firearmHits({ id = 7, status = 'registered' }))
            assert.are.equal(0, #query.firearmHits({ id = 7, status = 'agency_issued' }))
        end)

        it('points a firearm hit at the weapon, which is what the officer holds', function()
            local hits = query.firearmHits({ id = 7, status = 'lost' })

            assert.are.equal('firearm', hits[1].hitType)
            assert.are.equal(7, hits[1].hitId)
            assert.are.equal(7, hits[1].recordId)
        end)

        it('raises a hit on an officer-safety caution and not on the others', function()
            local hits = query.personHits({
                { id = 21, kind = 'armed' },
                { id = 22, kind = 'gang' },
                { id = 23, kind = 'mental_health' },
                { id = 24, kind = 'violent' },
            }, 9)

            -- `gang` is intelligence and `mental_health` is care information an
            -- officer without the field permission is not shown at all. Putting
            -- either behind a red banner would turn a caution into a reason to
            -- treat somebody as a threat.
            assert.are.equal(2, #hits)
            assert.are.equal('armed', hits[1].kind)
            assert.are.equal('violent', hits[2].kind)
            assert.are.equal('person_caution', hits[1].hitType)
        end)

        it('comes back unconfirmed, every time', function()
            -- The whole of 7.2's hit-confirmation rule, in one assertion: a hit
            -- is a lead until somebody confirms it on the record.
            assert.is_false(query.vehicleHits({ { id = 11, kind = 'stolen' } }, 3)[1].confirmed)
            assert.is_false(query.firearmHits({ id = 7, status = 'stolen' })[1].confirmed)
            assert.is_false(query.personHits({ { id = 21, kind = 'armed' } }, 9)[1].confirmed)
        end)

        it('counts the rows carrying a hit, not the hits', function()
            local count = query.countHits({
                { hits = { {}, {} } },
                { hits = {} },
                { restricted = true },
                { hits = { {} } },
            })

            assert.are.equal(2, count)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('confirming a hit', function()
        local function confirmation(overrides)
            local input = {
                hitType = 'vehicle_flag',
                hitId = 11,
                outcome = 'confirmed',
                caseNumber = 'LSPD-2026-000123',
            }

            for key, value in pairs(overrides or {}) do
                input[key] = value ~= helper.NONE and value or nil
            end

            return input
        end

        it('accepts a confirmation that points at something', function()
            assert.is_nil(query.validateConfirm(confirmation()))
        end)

        it('refuses a hit type it does not know', function()
            local err, fields = query.validateConfirm(confirmation({ hitType = 'warrant' }))

            assert.are.equal('invalid', err)
            assert.are.equal('not_allowed', fields.hitType)
        end)

        it('refuses an outcome it does not know', function()
            local err, fields = query.validateConfirm(confirmation({ outcome = 'maybe' }))

            assert.are.equal('invalid', err)
            assert.are.equal('not_allowed', fields.outcome)
        end)

        it('keeps all three real answers', function()
            assert.is_nil(query.validateConfirm(confirmation({ outcome = 'not_confirmed' })))
            -- `unable` is not `not_confirmed`: nobody answered, which is the
            -- fact an officer is asked about afterwards.
            assert.is_nil(query.validateConfirm(confirmation({ outcome = 'unable' })))
        end)

        it('asks what a confirmation was confirmed against', function()
            local err, fields = query.validateConfirm(
                confirmation({ caseNumber = helper.NONE })
            )

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.caseNumber)

            -- A written detail does instead: not every confirmation has a case
            -- number yet.
            assert.is_nil(query.validateConfirm(
                confirmation({ caseNumber = helper.NONE, detail = 'Confirmed with Sandy PD dispatch' })
            ))
        end)

        it('does not ask a negative answer to cite a case', function()
            assert.is_nil(query.validateConfirm(
                confirmation({ outcome = 'not_confirmed', caseNumber = helper.NONE })
            ))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('a lead that has gone away', function()
        it('refuses a flag that was cleared between the query and the stop', function()
            assert.is_true(query.hitIsLive('vehicle_flag', { kind = 'stolen' }))
            assert.is_false(query.hitIsLive('vehicle_flag', { kind = 'stolen', clearedAt = '2026-09-18' }))
        end)

        it('refuses a flag the database says has expired', function()
            -- `expired` is computed in SQL, never compared here: the clock that
            -- decides is the database's (invariant 1).
            assert.is_false(query.hitIsLive('vehicle_flag', { kind = 'stolen', expired = 1 }))
            assert.is_false(query.hitIsLive('person_caution', { kind = 'armed', expired = true }))
        end)

        it('refuses a flag kind that is not a hot file at all', function()
            assert.is_false(query.hitIsLive('vehicle_flag', { kind = 'impounded' }))
        end)

        it('refuses a firearm that has been recovered', function()
            assert.is_true(query.hitIsLive('firearm', { status = 'stolen' }))
            assert.is_false(query.hitIsLive('firearm', { status = 'registered' }))
        end)

        it('refuses a caution that was cancelled', function()
            assert.is_true(query.hitIsLive('person_caution', { kind = 'violent' }))
            assert.is_false(query.hitIsLive('person_caution', { kind = 'violent', cancelledAt = '2026-09-18' }))
            assert.is_false(query.hitIsLive('person_caution', { kind = 'gang' }))
        end)
    end)
end)
