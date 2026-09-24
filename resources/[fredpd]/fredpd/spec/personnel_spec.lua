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

        it('refuses a callsign with characters the board cannot print', function()
            local err, fields = personnel.validateRosterUpdate({ callsign = '1-ADAM<b>' })
            assert.equal('invalid', err)
            assert.equal('callsign_format', fields.callsign)
        end)

        it('accepts an ordinary callsign', function()
            assert.is_nil(personnel.validateRosterUpdate({ id = 1, callsign = '1-ADAM-12' }))
        end)
    end)

    describe('callsigns', function()
        it('refuses blank, padded and over-long callsigns', function()
            assert.is_false(personnel.isCallsign(''))
            assert.is_false(personnel.isCallsign('  '))
            assert.is_false(personnel.isCallsign(' LSPD-1'))
            assert.is_false(personnel.isCallsign(('A'):rep(17)))
            assert.is_false(personnel.isCallsign(12))
            assert.is_true(personnel.isCallsign('LSPD 101'))
        end)

        it('fills the format', function()
            assert.equal('LSPD-101', personnel.formatCallsign('{prefix}-{n}', 'LSPD', 101))
            assert.equal('1-ADAM-7', personnel.formatCallsign('1-ADAM-{n}', nil, 7))
        end)

        it('treats a percent sign in the prefix as text', function()
            assert.equal('A%1-5', personnel.formatCallsign('{prefix}-{n}', 'A%1', 5))
        end)

        it('skips callsigns already taken, case-insensitively', function()
            local taken = { ['LSPD-101'] = true, ['lspd-102'] = true }
            assert.equal('LSPD-103', personnel.nextCallsign('{prefix}-{n}', 'LSPD', 101, taken))
        end)

        it('starts at the configured number', function()
            assert.equal('LSPD-200', personnel.nextCallsign('{prefix}-{n}', 'LSPD', 200, {}))
        end)

        it('returns nil for a format that can never be valid', function()
            assert.is_nil(personnel.nextCallsign('{prefix}<{n}>', 'LSPD', 1, {}))
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

    describe('isIssueKind', function()
        it('accepts equipment and certification', function()
            assert.is_true(personnel.isIssueKind('equipment'))
            assert.is_true(personnel.isIssueKind('certification'))
        end)

        it('refuses anything else', function()
            assert.is_false(personnel.isIssueKind('firearm'))
            assert.is_false(personnel.isIssueKind(nil))
        end)
    end)

    describe('isGroupKey / isDiscordRoleId', function()
        it('accepts a lower_snake group key', function()
            assert.is_true(personnel.isGroupKey('swat'))
            assert.is_true(personnel.isGroupKey('air_unit'))
        end)

        it('refuses a group key that is not lower_snake', function()
            assert.is_false(personnel.isGroupKey('SWAT'))
            assert.is_false(personnel.isGroupKey('1swat'))
            assert.is_false(personnel.isGroupKey(nil))
        end)

        it('accepts a snowflake', function()
            assert.is_true(personnel.isDiscordRoleId('123456789012345678'))
        end)

        it('refuses anything that is not all digits', function()
            assert.is_false(personnel.isDiscordRoleId('swat-role'))
            assert.is_false(personnel.isDiscordRoleId(nil))
        end)
    end)

    describe('validateIssueGateSet', function()
        it('accepts a certification gated by a Discord role', function()
            assert.is_nil(personnel.validateIssueGateSet(
                { kind = 'certification', itemKey = 'swat', requiredDiscordRole = '123456789012345678' }))
        end)

        it('accepts an equipment item gated by a group', function()
            assert.is_nil(personnel.validateIssueGateSet(
                { kind = 'equipment', itemKey = 'less_lethal', requiredGroup = 'swat' }))
        end)

        it('refuses an unknown kind', function()
            local err, fields = personnel.validateIssueGateSet(
                { kind = 'firearm', itemKey = 'sidearm', requiredGroup = 'swat' })
            assert.equal('invalid', err)
            assert.equal('not_a_key', fields.kind)
        end)

        it('refuses a certification key checked against the equipment list, and vice versa', function()
            local err, fields = personnel.validateIssueGateSet(
                { kind = 'certification', itemKey = 'vest', requiredGroup = 'swat' })
            assert.equal('invalid', err)
            assert.equal('not_a_key', fields.itemKey)
        end)

        it('refuses neither requiredGroup nor requiredDiscordRole', function()
            local err, fields = personnel.validateIssueGateSet({ kind = 'equipment', itemKey = 'vest' })
            assert.equal('invalid', err)
            assert.equal('gate_required', fields._input)
        end)

        it('refuses a malformed group key', function()
            local err, fields = personnel.validateIssueGateSet(
                { kind = 'equipment', itemKey = 'vest', requiredGroup = 'SWAT!' })
            assert.equal('invalid', err)
            assert.equal('not_group_key', fields.requiredGroup)
        end)

        it('refuses a malformed Discord role id', function()
            local err, fields = personnel.validateIssueGateSet(
                { kind = 'equipment', itemKey = 'vest', requiredDiscordRole = 'not-a-snowflake' })
            assert.equal('invalid', err)
            assert.equal('not_snowflake', fields.requiredDiscordRole)
        end)
    end)

    describe('gatingSatisfied', function()
        local function holds(held)
            return function(roleId) return held[roleId] == true end
        end

        it('is satisfied with no gate at all', function()
            assert.is_true(personnel.gatingSatisfied(nil, holds({}), holds({})))
        end)

        it('is satisfied by holding the required Discord role', function()
            local gate = { requiredDiscordRole = 'r1' }
            assert.is_true(personnel.gatingSatisfied(gate, holds({ r1 = true }), holds({})))
        end)

        it('is satisfied by being in the required group', function()
            local gate = { requiredGroup = 'swat' }
            assert.is_true(personnel.gatingSatisfied(gate, holds({}), holds({ swat = true })))
        end)

        it('refuses when neither predicate is satisfied', function()
            local gate = { requiredDiscordRole = 'r1', requiredGroup = 'swat' }
            assert.is_false(personnel.gatingSatisfied(gate, holds({}), holds({})))
        end)

        it('fails closed on an unknown group', function()
            local gate = { requiredGroup = 'made_up' }
            assert.is_false(personnel.gatingSatisfied(gate, holds({}), holds({})))
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
