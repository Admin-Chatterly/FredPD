--- Personnel: roster detail, equipment, certifications and the disciplinary
--- file (spec 7.22-7.24).
---
--- The allowlist checks are what this file is for: equipment items and
--- certifications are locale keys rendered with `t()`, so a route that
--- skipped `isEquipmentItem`/`isCertification` would let a client render an
--- arbitrary string as a translation key -- the exact defect class four other
--- modules shipped before their own review caught it.

local helper = require('spec.helper')

describe('personnel', function()
    local personnel

    before_each(function()
        personnel = helper.load({ 'server/modules/personnel/service' }).Modules.personnel
    end)

    describe('isEquipmentItem', function()
        it('accepts every key on the list', function()
            assert.is_true(personnel.isEquipmentItem('sidearm'))
            assert.is_true(personnel.isEquipmentItem('taser'))
            assert.is_true(personnel.isEquipmentItem('vest'))
            assert.is_true(personnel.isEquipmentItem('other'))
        end)

        it('refuses anything not on the list', function()
            assert.is_false(personnel.isEquipmentItem('drone'))
            assert.is_false(personnel.isEquipmentItem(''))
            assert.is_false(personnel.isEquipmentItem(nil))
        end)
    end)

    describe('isCertification', function()
        it('accepts every key on the list', function()
            assert.is_true(personnel.isCertification('fto'))
            assert.is_true(personnel.isCertification('k9_handler'))
            assert.is_true(personnel.isCertification('breach'))
        end)

        it('refuses an unknown key', function()
            assert.is_false(personnel.isCertification('helicopter_pilot'))
            assert.is_false(personnel.isCertification(nil))
        end)
    end)

    describe('isDisciplineCategory / isDisciplineOutcome', function()
        it('accepts the closed lists', function()
            assert.is_true(personnel.isDisciplineCategory('conduct'))
            assert.is_true(personnel.isDisciplineCategory('use_of_force'))
            assert.is_true(personnel.isDisciplineOutcome('unfounded'))
            assert.is_true(personnel.isDisciplineOutcome('sustained_termination'))
        end)

        it('refuses free text', function()
            assert.is_false(personnel.isDisciplineCategory('made_up'))
            assert.is_false(personnel.isDisciplineOutcome('made_up'))
        end)
    end)

    describe('certificationIsActive', function()
        local NOW = 1700000000

        it('is active with no expiry and no revocation', function()
            assert.is_true(personnel.certificationIsActive({ expiresAt = nil, revokedAt = nil }, NOW))
        end)

        it('is inactive once revoked, regardless of expiry', function()
            assert.is_false(personnel.certificationIsActive({ expiresAt = NOW + 1000, revokedAt = NOW - 10 }, NOW))
        end)

        it('is inactive past its own expiry', function()
            assert.is_false(personnel.certificationIsActive({ expiresAt = NOW - 1, revokedAt = nil }, NOW))
        end)

        it('is active before its expiry', function()
            assert.is_true(personnel.certificationIsActive({ expiresAt = NOW + 1, revokedAt = nil }, NOW))
        end)
    end)

    describe('validateRosterUpdate', function()
        it('accepts empty optional fields', function()
            assert.is_nil(personnel.validateRosterUpdate({ id = 1 }))
        end)

        it('refuses a badge number over 16 characters', function()
            local err, fields = personnel.validateRosterUpdate({ badgeNumber = ('1'):rep(17) })
            assert.equal('invalid', err)
            assert.equal('too_long', fields.badgeNumber)
        end)

        it('refuses a division over 64 characters', function()
            local err, fields = personnel.validateRosterUpdate({ division = ('a'):rep(65) })
            assert.equal('invalid', err)
            assert.equal('too_long', fields.division)
        end)
    end)

    describe('validateEquipmentAssign', function()
        it('accepts a valid item key', function()
            assert.is_nil(personnel.validateEquipmentAssign({ itemKey = 'vest' }))
        end)

        it('refuses an item key that is not on the list', function()
            local err, fields = personnel.validateEquipmentAssign({ itemKey = 'drone' })
            assert.equal('invalid', err)
            assert.equal('not_a_key', fields.itemKey)
        end)
    end)

    describe('validateCertificationIssue', function()
        it('accepts a valid certification key', function()
            assert.is_nil(personnel.validateCertificationIssue({ certKey = 'fto' }))
        end)

        it('refuses an unknown certification key', function()
            local err, fields = personnel.validateCertificationIssue({ certKey = 'pilot' })
            assert.equal('invalid', err)
            assert.equal('not_a_key', fields.certKey)
        end)

        it('refuses a non-numeric expiresAt', function()
            local err, fields = personnel.validateCertificationIssue({ certKey = 'fto', expiresAt = 'soon' })
            assert.equal('invalid', err)
            assert.equal('type', fields.expiresAt)
        end)
    end)

    describe('validateDisciplineOpen', function()
        it('accepts a valid category and summary', function()
            assert.is_nil(personnel.validateDisciplineOpen({ category = 'conduct', summary = 'x' }))
        end)

        it('refuses an unknown category', function()
            local err, fields = personnel.validateDisciplineOpen({ category = 'made_up', summary = 'x' })
            assert.equal('invalid', err)
            assert.equal('not_a_key', fields.category)
        end)

        it('refuses an empty summary', function()
            local err, fields = personnel.validateDisciplineOpen({ category = 'conduct', summary = '' })
            assert.equal('invalid', err)
            assert.equal('required', fields.summary)
        end)
    end)

    describe('validateDisciplineClose', function()
        it('accepts a valid outcome', function()
            assert.is_nil(personnel.validateDisciplineClose({ outcomeKey = 'unfounded' }))
        end)

        it('refuses an unknown outcome', function()
            local err, fields = personnel.validateDisciplineClose({ outcomeKey = 'made_up' })
            assert.equal('invalid', err)
            assert.equal('not_a_key', fields.outcomeKey)
        end)
    end)

    describe('validateLoadoutCreate', function()
        it('accepts a name and a valid item list', function()
            assert.is_nil(personnel.validateLoadoutCreate({ name = 'Patrol Basic', itemKeys = { 'vest', 'radio' } }))
        end)

        it('refuses a blank name', function()
            local err, fields = personnel.validateLoadoutCreate({ name = '   ', itemKeys = { 'vest' } })
            assert.equal('invalid', err)
            assert.equal('required', fields.name)
        end)

        it('refuses no items at all', function()
            local err, fields = personnel.validateLoadoutCreate({ name = 'Empty', itemKeys = {} })
            assert.equal('invalid', err)
            assert.equal('required', fields.itemKeys)
        end)

        it('refuses an item key that is not on the list', function()
            local err, fields = personnel.validateLoadoutCreate({ name = 'Drone Unit', itemKeys = { 'drone' } })
            assert.equal('invalid', err)
            assert.equal('not_a_key', fields.itemKeys)
        end)

        it('refuses a duplicated item key', function()
            local err, fields = personnel.validateLoadoutCreate({ name = 'X', itemKeys = { 'vest', 'vest' } })
            assert.equal('invalid', err)
            assert.equal('duplicate', fields.itemKeys)
        end)
    end)

    describe('validateSetLoadout', function()
        it('accepts an officer id with no loadout (unassign)', function()
            assert.is_nil(personnel.validateSetLoadout({ officerId = 1 }))
        end)

        it('accepts an officer id with a loadout id', function()
            assert.is_nil(personnel.validateSetLoadout({ officerId = 1, loadoutId = 2 }))
        end)

        it('refuses a missing officer id', function()
            local err, fields = personnel.validateSetLoadout({})
            assert.equal('invalid', err)
            assert.equal('required', fields.officerId)
        end)

        it('refuses a non-numeric loadout id', function()
            local err, fields = personnel.validateSetLoadout({ officerId = 1, loadoutId = 'x' })
            assert.equal('invalid', err)
            assert.equal('invalid', fields.loadoutId)
        end)
    end)

    describe('itemsToIssue', function()
        it('issues everything when nothing is already open', function()
            local toIssue = personnel.itemsToIssue({ 'vest', 'radio' }, {})
            assert.same({ 'vest', 'radio' }, toIssue)
        end)

        it('skips an item already open on the officer', function()
            local toIssue = personnel.itemsToIssue({ 'vest', 'radio' }, { 'radio' })
            assert.same({ 'vest' }, toIssue)
        end)

        it('issues nothing when everything is already open', function()
            local toIssue = personnel.itemsToIssue({ 'vest', 'radio' }, { 'vest', 'radio', 'taser' })
            assert.same({}, toIssue)
        end)
    end)
end)
