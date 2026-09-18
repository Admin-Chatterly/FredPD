--- Tvångsmedel och efterlysning (spec 7.12, 7.13).
---
--- **`isValid` and `authorisesEntry` are what this file is for.** Spec 14
--- exposes them to other resources as `HasSearchWarrant(targetType, targetId)`,
--- and `ox_doorlock` decides whether to open somebody's front door on the
--- answer. A door that opens when nothing authorises it is the worst failure
--- this module can have, and it is a silent one: nothing logs a door that
--- should not have opened.
---
--- So the cases below cover every way a measure can fail to be live, and --
--- more importantly -- the two ways it can look live and not authorise entry:
--- a kroppsvisitation is a decision about somebody's pockets, and a beslag is a
--- decision about an object. Neither is a decision to enter a flat, and a door
--- script asking the general question would open on both.

local helper = require('spec.helper')

describe('tvangsmedel', function()
    local tvang

    before_each(function()
        tvang = helper.load({ 'server/modules/tvangsmedel/service' }).Modules.tvangsmedel
    end)

    local NOW <const> = 1000000

    --- A live husrannsakan, varying one field at a time.
    local function measure(overrides)
        local base = {
            id = 1,
            kind = 'husrannsakan_reell',
            targetKind = 'address',
            targetId = 5,
            validFrom = NOW - 3600,
            validUntil = NOW + 3600,
        }

        for key, value in pairs(overrides or {}) do base[key] = value end
        return base
    end

    -- -------------------------------------------------------------------------
    describe('validity', function()
        it('is live inside its window', function()
            assert.is_true(tvang.isValid(measure(), NOW))
        end)

        it('is not live before it starts', function()
            local ok, why = tvang.isValid(measure({ validFrom = NOW + 60 }), NOW)

            assert.is_false(ok)
            assert.are.equal('not_yet', why)
        end)

        it('is not live after it expires', function()
            local ok, why = tvang.isValid(measure({ validUntil = NOW - 60 }), NOW)

            assert.is_false(ok)
            assert.are.equal('expired', why)
        end)

        it('stops being live the moment it is revoked, window or no window', function()
            local ok, why = tvang.isValid(measure({ upphavdAt = NOW - 1 }), NOW)

            assert.is_false(ok)
            assert.are.equal('upphavd', why)
        end)

        it('STAYS live after it has been carried out', function()
            -- RB allows a husrannsakan to be resumed. A door that refused the
            -- second entry because the first was logged would be enforcing a
            -- rule nobody wrote.
            assert.is_true(tvang.isValid(measure({
                verkstalldAt = NOW - 60, verkstalldBy = 'ofc1',
            }), NOW))
        end)

        it('refuses something that is not a measure', function()
            assert.is_false(tvang.isValid(nil, NOW))
            assert.is_false(tvang.isValid('W26-00001', NOW))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('firstValid', function()
        it('finds the live one among expired ones', function()
            local found = tvang.firstValid({
                measure({ id = 1, validUntil = NOW - 10 }),
                measure({ id = 2 }),
            }, NOW)

            assert.are.equal(2, found.id)
        end)

        it('returns the measure and not a boolean', function()
            -- So a door script can log which decision it opened on. One that
            -- logs "true" is not auditable.
            local found = tvang.firstValid({ measure({ id = 7 }) }, NOW)

            assert.are.equal(7, found.id)
            assert.are.equal('husrannsakan_reell', found.kind)
        end)

        it('finds nothing when every measure has lapsed', function()
            assert.is_nil(tvang.firstValid({
                measure({ validUntil = NOW - 10 }),
                measure({ upphavdAt = NOW - 5 }),
            }, NOW))
        end)

        it('finds nothing in an empty list', function()
            assert.is_nil(tvang.firstValid({}, NOW))
            assert.is_nil(tvang.firstValid(nil, NOW))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('authorisesEntry', function()
        it('is true for both kinds of husrannsakan', function()
            assert.is_true(tvang.authorisesEntry({ kind = 'husrannsakan_reell' }))
            assert.is_true(tvang.authorisesEntry({ kind = 'husrannsakan_personell' }))
        end)

        it('is FALSE for a kroppsvisitation', function()
            -- A decision about somebody's pockets is not a decision to enter
            -- their flat. This is the case that makes `HasSearchWarrant`
            -- unable to just ask whether any measure exists for the target.
            assert.is_false(tvang.authorisesEntry({ kind = 'kroppsvisitation' }))
            assert.is_false(tvang.authorisesEntry({ kind = 'kroppsbesiktning' }))
        end)

        it('is false for a beslag decision on its own', function()
            assert.is_false(tvang.authorisesEntry({ kind = 'beslag' }))
        end)

        it('is false for something that is not a measure', function()
            assert.is_false(tvang.authorisesEntry(nil))
            assert.is_false(tvang.authorisesEntry({}))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('who may decide what', function()
        it('lets a police FU-ledare decide an ordinary husrannsakan', function()
            assert.is_true(tvang.mayDecide('fu_ledare', 'husrannsakan_reell'))
            assert.is_true(tvang.mayDecide('fu_ledare', 'kroppsvisitation'))
        end)

        it('holds kroppsbesiktning back from a police FU-ledare', function()
            -- Stricter than RB on purpose, and recorded as such in the service:
            -- the measure that reaches inside somebody's body, and produces the
            -- reference sample the lab compares against, needs a prosecutor.
            assert.is_false(tvang.mayDecide('fu_ledare', 'kroppsbesiktning'))
            assert.is_true(tvang.mayDecide('aklagare', 'kroppsbesiktning'))
            assert.is_true(tvang.mayDecide('domare', 'kroppsbesiktning'))
        end)

        it('refuses a capacity that is not one', function()
            assert.is_false(tvang.mayDecide('polis', 'husrannsakan_reell'))
            assert.is_false(tvang.mayDecide(nil, 'husrannsakan_reell'))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('validate', function()
        it('accepts a well-formed husrannsakan', function()
            assert.is_nil(tvang.validate({
                kind = 'husrannsakan_reell', targetKind = 'address',
                targetId = 5, grund = 'tvang.grund.skalig_misstanke',
            }))
        end)

        it('refuses a husrannsakan pointed at a person', function()
            -- How a decision to search a flat ends up authorising a search of
            -- whoever happens to be standing in it.
            local code, fields = tvang.validate({
                kind = 'husrannsakan_reell', targetKind = 'person',
                targetId = 5, grund = 'g',
            })

            assert.are.equal('invalid', code)
            assert.are.equal('not_a_place', fields.targetKind)
        end)

        it('refuses a kroppsvisitation pointed at an address', function()
            local code, fields = tvang.validate({
                kind = 'kroppsvisitation', targetKind = 'address',
                targetId = 5, grund = 'g',
            })

            assert.are.equal('invalid', code)
            assert.are.equal('not_a_person', fields.targetKind)
        end)

        it('requires a ground', function()
            local _, fields = tvang.validate({
                kind = 'husrannsakan_reell', targetKind = 'address', targetId = 5,
            })

            assert.are.equal('required', fields.grund)
        end)

        it('refuses an unknown measure or target', function()
            assert.are.equal('invalid', tvang.validate({
                kind = 'search_warrant', targetKind = 'address', targetId = 1, grund = 'g',
            }))
            assert.are.equal('invalid', tvang.validate({
                kind = 'husrannsakan_reell', targetKind = 'building', targetId = 1, grund = 'g',
            }))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('efterlysning', function()
        local function wanted(overrides)
            local base = { id = 1, grund = 'anhallen_i_franvaro', priority = 2 }

            for key, value in pairs(overrides or {}) do base[key] = value end
            return base
        end

        it('is live with no expiry at all', function()
            -- An anhållen i sin frånvaro does not lapse because time passed.
            assert.is_true(tvang.isLive(wanted(), NOW))
        end)

        it('stops when cancelled', function()
            local ok, why = tvang.isLive(wanted({ cancelledAt = NOW - 1 }), NOW)

            assert.is_false(ok)
            assert.are.equal('cancelled', why)
        end)

        it('stops when it expires', function()
            local ok, why = tvang.isLive(wanted({ expiresAt = NOW - 1 }), NOW)

            assert.is_false(ok)
            assert.are.equal('expired', why)
        end)

        it('separates detain-on-sight from the rest', function()
            -- Somebody wanted to be served a document is not somebody to
            -- arrest, and a missing person is wanted for their own sake. One
            -- red banner for all three teaches an officer to treat them alike.
            assert.is_true(tvang.detainOnSight('anhallen_i_franvaro'))
            assert.is_true(tvang.detainOnSight('haktad_i_franvaro'))

            assert.is_false(tvang.detainOnSight('delgivning'))
            assert.is_false(tvang.detainOnSight('forsvunnen'))
        end)

        it('sorts detain-on-sight ahead of a higher-priority non-arrest one', function()
            -- The banner shows one line and it has to be the line that changes
            -- what the officer does.
            local sorted = tvang.liveSorted({
                wanted({ id = 1, grund = 'delgivning', priority = 1 }),
                wanted({ id = 2, grund = 'anhallen_i_franvaro', priority = 4 }),
            }, NOW)

            assert.are.equal(2, sorted[1].id)
        end)

        it('sorts by priority within the same kind', function()
            local sorted = tvang.liveSorted({
                wanted({ id = 1, priority = 3 }),
                wanted({ id = 2, priority = 1 }),
            }, NOW)

            assert.are.equal(2, sorted[1].id)
        end)

        it('breaks a tie stably, so two reads agree', function()
            local rows = {
                wanted({ id = 9, priority = 2 }),
                wanted({ id = 4, priority = 2 }),
            }

            assert.are.equal(4, tvang.liveSorted(rows, NOW)[1].id)
            assert.are.equal(4, tvang.liveSorted(rows, NOW)[1].id)
        end)

        it('drops the ones that are not live', function()
            local sorted = tvang.liveSorted({
                wanted({ id = 1, cancelledAt = NOW - 1 }),
                wanted({ id = 2 }),
            }, NOW)

            assert.are.equal(1, #sorted)
            assert.are.equal(2, sorted[1].id)
        end)
    end)
end)
