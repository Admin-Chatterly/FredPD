--- Permissions (spec 4.3, invariant 2, ADR-004).
---
--- This is the code that decides what an officer can do, so the cases worth
--- testing are the ones where getting it wrong grants access: inheritance
--- chains, wildcards, and a role that is mapped in one agency but not another.

local helper = require('spec.helper')

describe('perms', function()
    local perms

    before_each(function()
        perms = helper.load({ 'server/core/perms' }).Core.perms
    end)

    describe('expandGroup', function()
        local groups = {
            patrol_basic = { permissions = { 'page.records', 'comms.pdchat.view' } },
            patrol = { inherits = 'patrol_basic', permissions = { 'garage.vehicle.draw' } },
            supervisor = { inherits = 'patrol', permissions = { 'comms.pdchat.all' } },
            lonely = { permissions = { 'stats.view' } },
        }

        it('returns a group\'s own permissions', function()
            local result = perms.expandGroup('lonely', groups)

            assert.is_true(result['stats.view'])
        end)

        it('includes everything inherited, through the whole chain', function()
            local result = perms.expandGroup('supervisor', groups)

            assert.is_true(result['comms.pdchat.all'])  -- its own
            assert.is_true(result['garage.vehicle.draw']) -- from patrol
            assert.is_true(result['page.records'])        -- from patrol_basic
        end)

        it('does not leak permissions downward', function()
            -- patrol_basic must not gain what patrol adds.
            local result = perms.expandGroup('patrol_basic', groups)

            assert.is_nil(result['garage.vehicle.draw'])
        end)

        it('survives a cycle instead of recursing forever', function()
            local cyclic = {
                a = { inherits = 'b', permissions = { 'one' } },
                b = { inherits = 'a', permissions = { 'two' } },
            }

            local result = perms.expandGroup('a', cyclic)

            assert.is_true(result.one)
            assert.is_true(result.two)
        end)

        it('returns nothing for an unknown group', function()
            assert.are.same({}, perms.expandGroup('ghost', groups))
        end)
    end)

    describe('computeEffective', function()
        local groupPermissions = {
            patrol = { ['page.records'] = true, ['garage.vehicle.draw'] = true },
            dispatch = { ['page.dispatch'] = true },
        }

        it('unions the groups from every role held', function()
            local effective = perms.computeEffective(
                { 'role_a', 'role_b' },
                { role_a = { 'patrol' }, role_b = { 'dispatch' } },
                groupPermissions
            )

            assert.is_true(effective['page.records'])
            assert.is_true(effective['page.dispatch'])
        end)

        it('grants nothing for a role that is not mapped', function()
            local effective = perms.computeEffective(
                { 'unmapped_role' }, { role_a = { 'patrol' } }, groupPermissions
            )

            assert.are.same({}, effective)
        end)

        it('grants nothing when the member holds no roles', function()
            -- The default state of a fresh install: nobody has access until an
            -- administrator maps a role.
            assert.are.same({}, perms.computeEffective({}, { role_a = { 'patrol' } }, groupPermissions))
        end)

        it('ignores a mapping to a group that no longer exists', function()
            local effective = perms.computeEffective(
                { 'role_a' }, { role_a = { 'deleted_group' } }, groupPermissions
            )

            assert.are.same({}, effective)
        end)
    end)

    describe('satisfies', function()
        it('matches an exact permission', function()
            assert.is_true(perms.satisfies({ ['page.records'] = true }, 'page.records'))
        end)

        it('refuses when the permission is absent', function()
            assert.is_false(perms.satisfies({ ['page.records'] = true }, 'page.admin'))
        end)

        it('refuses against an empty permission set', function()
            assert.is_false(perms.satisfies({}, 'page.records'))
        end)

        it('honours a wildcard grant at any level', function()
            local granted = { ['rms.person.*'] = true }

            assert.is_true(perms.satisfies(granted, 'rms.person.view'))
            assert.is_true(perms.satisfies(granted, 'rms.person.edit'))
            assert.is_false(perms.satisfies(granted, 'rms.vehicle.view'))
        end)

        it('honours a wildcard higher up the key', function()
            assert.is_true(perms.satisfies({ ['rms.*'] = true }, 'rms.person.view'))
        end)

        it('does not treat a wildcard in the requirement as a match', function()
            -- A route asks for exactly one permission. Honouring a wildcard in
            -- the requirement would make reading a route stop telling you what
            -- it actually needs.
            assert.is_false(perms.satisfies({ ['rms.person.view'] = true }, 'rms.person.*'))
        end)
    end)
end)
