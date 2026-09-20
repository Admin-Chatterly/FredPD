--- Spaningsuppdrag (spec 7.13).
---
--- **`bannerFor` is what this file is for.** It decides how loudly an officer
--- is interrupted, and the failure mode is not a crash: it is an officer who
--- has been shown a red banner for "have a look for this silver van" three
--- times a shift, has learned that red banners are usually nothing, and misses
--- the one that was a person with a knife.
---
--- So the cases below pin the quiet direction as hard as the loud one, and pin
--- the thing a lookout must never be able to do -- look like an efterlysning,
--- which is a prosecutor's decision to detain somebody and is the only thing
--- that gets the detain-on-sight treatment.

local helper = require('spec.helper')

describe('spaning', function()
    local spaning

    before_each(function()
        spaning = helper.load({ 'server/modules/spaning/service' }).Modules.spaning
    end)

    local NOW <const> = 1000000

    local function lookout(overrides)
        local base = {
            id = 1,
            targetKind = 'vehicle',
            targetId = 3,
            priority = 3,
            issuedAt = NOW - 3600,
            expiresAt = NOW + 3600,
        }

        -- `helper.NONE` removes a field. `{ expiresAt = nil }` cannot: `pairs`
        -- never visits a nil value, so the override is silently ignored and the
        -- test asserts against the default.
        for key, value in pairs(overrides or {}) do
            base[key] = value ~= helper.NONE and value or nil
        end

        return base
    end

    -- -------------------------------------------------------------------------
    describe('bannerFor', function()
        it('gives priority 1 the full banner', function()
            assert.are.equal('alert', spaning.bannerFor(lookout({ priority = 1 })))
        end)

        it('gives the middle priorities a quiet notice, not a banner', function()
            -- The case that protects the banner's meaning.
            assert.are.equal('notice', spaning.bannerFor(lookout({ priority = 2 })))
            assert.are.equal('notice', spaning.bannerFor(lookout({ priority = 3 })))
        end)

        it('gives the lowest priority nothing at all', function()
            assert.are.equal('quiet', spaning.bannerFor(lookout({ priority = 4 })))
        end)

        it('treats an absent priority as the quietest', function()
            -- Fails quiet, not loud. A lookout with no priority set is not an
            -- emergency, and guessing that it might be is how the banner
            -- becomes noise.
            assert.are.equal('quiet', spaning.bannerFor({ id = 1 }))
            assert.are.equal('quiet', spaning.bannerFor(nil))
        end)

        it('never produces the detain-on-sight treatment', function()
            -- A lookout is not a prosecutor's decision. Whatever priority it
            -- carries, the loudest it reaches is `alert`.
            for priority = 1, 4 do
                local banner = spaning.bannerFor(lookout({ priority = priority }))

                assert.is_true(banner == 'alert' or banner == 'notice' or banner == 'quiet')
                assert.are_not.equal('detain', banner)
            end
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('needsConfirmation', function()
        it('asks for confirmation only where a banner interrupted somebody', function()
            assert.is_true(spaning.needsConfirmation(lookout({ priority = 1 })))

            -- A confirmation dialog on something nobody was shown is a dialog
            -- with no question in it.
            assert.is_false(spaning.needsConfirmation(lookout({ priority = 2 })))
            assert.is_false(spaning.needsConfirmation(lookout({ priority = 4 })))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('isLive', function()
        it('is live inside its window', function()
            assert.is_true(spaning.isLive(lookout(), NOW))
        end)

        it('stops when resolved', function()
            local ok, why = spaning.isLive(lookout({ resolvedAt = NOW - 1 }), NOW)

            assert.is_false(ok)
            assert.are.equal('resolved', why)
        end)

        it('stops when it expires', function()
            local ok, why = spaning.isLive(lookout({ expiresAt = NOW - 1 }), NOW)

            assert.is_false(ok)
            assert.are.equal('expired', why)
        end)

        it('fails closed on a row with no expiry at all', function()
            -- 0012 makes the column NOT NULL, so such a row was written around
            -- the schema. Treating it as eternal is the one reading that keeps
            -- a stale banner up forever.
            local ok, why = spaning.isLive(lookout({ expiresAt = helper.NONE }), NOW)

            assert.is_false(ok)
            assert.are.equal('no_expiry', why)
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('liveSorted', function()
        it('puts the most urgent first', function()
            local sorted = spaning.liveSorted({
                lookout({ id = 1, priority = 3 }),
                lookout({ id = 2, priority = 1 }),
            }, NOW)

            assert.are.equal(2, sorted[1].id)
        end)

        it('puts the newest first within a priority', function()
            -- The most recent sighting is the one worth acting on.
            local sorted = spaning.liveSorted({
                lookout({ id = 1, priority = 2, issuedAt = NOW - 7200 }),
                lookout({ id = 2, priority = 2, issuedAt = NOW - 60 }),
            }, NOW)

            assert.are.equal(2, sorted[1].id)
        end)

        it('breaks a full tie stably', function()
            local rows = {
                lookout({ id = 8, priority = 2, issuedAt = NOW - 60 }),
                lookout({ id = 3, priority = 2, issuedAt = NOW - 60 }),
            }

            assert.are.equal(3, spaning.liveSorted(rows, NOW)[1].id)
            assert.are.equal(3, spaning.liveSorted(rows, NOW)[1].id)
        end)

        it('drops the ones that are not live', function()
            local sorted = spaning.liveSorted({
                lookout({ id = 1, expiresAt = NOW - 1 }),
                lookout({ id = 2, resolvedAt = NOW - 1 }),
                lookout({ id = 3 }),
            }, NOW)

            assert.are.equal(1, #sorted)
            assert.are.equal(3, sorted[1].id)
        end)

        it('survives an empty list', function()
            assert.are.equal(0, #spaning.liveSorted({}, NOW))
            assert.are.equal(0, #spaning.liveSorted(nil, NOW))
        end)
    end)

    -- -------------------------------------------------------------------------
    describe('the grounds that are locale keys', function()
        -- `spaning.create` is a patrol permission — the lowest-privileged
        -- write in the module — so this is the easiest of the four grounds to
        -- reach from a route call, and the one most worth closing.

        it('accepts the reasons a lookout is raised for', function()
            for _, key in ipairs({
                'iakttagelse', 'efterlyst_fordon', 'stulet_fordon',
                'misstankt_fordon', 'eftersokt_person', 'annan',
            }) do
                assert.is_true(spaning.isGrund(key))
            end
        end)

        it('refuses prose', function()
            assert.is_false(spaning.isGrund('anything at all'))
            assert.is_false(spaning.isGrund('spaning.grund.iakttagelse'))
            assert.is_false(spaning.isGrund(nil))
        end)

        it('refuses prose as a reason for closing one', function()
            assert.is_true(spaning.isAvslutsgrund('omhandertaget'))
            assert.is_false(spaning.isAvslutsgrund('found it'))
        end)

        it('is what `validate` enforces', function()
            local err, fields = spaning.validate({
                targetKind = 'vehicle', targetId = 3, grund = 'arbitrary prose',
            })

            assert.are.equal('invalid', err)
            assert.are.equal('not_a_key', fields.grund)
        end)
    end)

    describe('validate', function()
        it('accepts a lookout on a registered vehicle', function()
            assert.is_nil(spaning.validate({
                targetKind = 'vehicle', targetId = 3, grund = 'efterlyst_fordon',
            }))
        end)

        it('accepts a description with no record behind it', function()
            -- The commonest lookout there is, and the case a foreign key
            -- cannot express.
            assert.is_nil(spaning.validate({
                targetKind = 'other',
                description = 'Silver estate, no plate seen, three occupants',
                grund = 'iakttagelse',
            }))
        end)

        it('refuses a lookout for nothing at all', function()
            local code, fields = spaning.validate({
                targetKind = 'vehicle', grund = 'iakttagelse',
            })

            assert.are.equal('invalid', code)
            assert.are.equal('required_without_target', fields.description)
        end)

        it('refuses an id alongside "other"', function()
            -- An id into nothing; the banner would try to open a record that
            -- does not exist.
            local code, fields = spaning.validate({
                targetKind = 'other', targetId = 5, description = 'x', grund = 'iakttagelse',
            })

            assert.are.equal('invalid', code)
            assert.are.equal('not_allowed', fields.targetId)
        end)

        it('refuses a priority outside 1-4', function()
            assert.are.equal('invalid', spaning.validate({
                targetKind = 'vehicle', targetId = 1, grund = 'iakttagelse', priority = 0,
            }))
            assert.are.equal('invalid', spaning.validate({
                targetKind = 'vehicle', targetId = 1, grund = 'iakttagelse', priority = 5,
            }))
        end)

        it('refuses a validity longer than the cap', function()
            local _, fields = spaning.validate({
                targetKind = 'vehicle', targetId = 1, grund = 'iakttagelse',
                validSeconds = spaning.MAX_VALIDITY + 1,
            })

            assert.are.equal('out_of_range', fields.validSeconds)
        end)

        it('requires a ground', function()
            local _, fields = spaning.validate({ targetKind = 'vehicle', targetId = 1 })

            assert.are.equal('required', fields.grund)
        end)

        it('refuses an unknown target kind', function()
            assert.are.equal('invalid', spaning.validate({
                targetKind = 'building', targetId = 1, grund = 'iakttagelse',
            }))
        end)
    end)
end)
