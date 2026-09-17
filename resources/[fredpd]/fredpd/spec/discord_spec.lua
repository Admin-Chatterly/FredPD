--- Discord role sync and first-run setup (spec 4.2, 16, ADR-010).
---
--- These are the parts that decide who gets access on a fresh install, so the
--- things worth proving are that a snowflake survives intact, that the
--- pagination walk terminates, and that setup writes what it claims to.

local helper = require('spec.helper')

describe('discord', function()
    local discord

    before_each(function()
        discord = helper.load({ 'server/core/discord' }).Core.discord
    end)

    describe('rolesFromMember', function()
        it('reads the role list off a member payload', function()
            local roles = discord.rolesFromMember({ roles = { '111', '222' } })
            assert.are.same({ '111', '222' }, roles)
        end)

        it('keeps role ids as strings', function()
            -- A snowflake is a 64-bit integer. Lua numbers are doubles, so
            -- turning one into a number rounds the low bits off and quietly
            -- matches the wrong role -- or no role at all.
            local roles = discord.rolesFromMember({ roles = { '1420070400000000007' } })

            assert.are.equal('string', type(roles[1]))
            assert.are.equal('1420070400000000007', roles[1])
        end)

        it('is empty for a member with no roles', function()
            assert.are.same({}, discord.rolesFromMember({ roles = {} }))
        end)

        it('survives a payload that is not shaped like a member', function()
            assert.are.same({}, discord.rolesFromMember(nil))
            assert.are.same({}, discord.rolesFromMember({}))
            assert.are.same({}, discord.rolesFromMember({ roles = 'nope' }))
            assert.are.same({}, discord.rolesFromMember('nope'))
        end)

        it('drops entries that are not usable role ids', function()
            local roles = discord.rolesFromMember({ roles = { '111', '', 42, false, '222' } })
            assert.are.same({ '111', '222' }, roles)
        end)
    end)

    describe('userIdFromMember', function()
        it('reads the user id', function()
            assert.are.equal('900', discord.userIdFromMember({ user = { id = '900' } }))
        end)

        it('is nil when Discord omitted the user object', function()
            -- Happens on some payload shapes. A row keyed on nil would be worse
            -- than a member skipped.
            assert.is_nil(discord.userIdFromMember({ roles = { '1' } }))
            assert.is_nil(discord.userIdFromMember({ user = {} }))
            assert.is_nil(discord.userIdFromMember(nil))
        end)
    end)

    describe('cursorFrom', function()
        it('is the highest user id on the page', function()
            local cursor = discord.cursorFrom({
                { user = { id = '100' } },
                { user = { id = '300' } },
                { user = { id = '200' } },
            })

            assert.are.equal('300', cursor)
        end)

        it('compares by length before comparing lexically', function()
            -- Plain string comparison puts '99' after '100', which would send
            -- the same `after` cursor forever and walk the guild in circles.
            local cursor = discord.cursorFrom({
                { user = { id = '99' } },
                { user = { id = '100' } },
            })

            assert.are.equal('100', cursor)
        end)

        it('orders snowflakes of equal length lexically', function()
            local cursor = discord.cursorFrom({
                { user = { id = '1420070400000000007' } },
                { user = { id = '1420070400000000012' } },
            })

            assert.are.equal('1420070400000000012', cursor)
        end)

        it('is nil for an empty page, which ends the walk', function()
            assert.is_nil(discord.cursorFrom({}))
        end)

        it('is nil when no member on the page carries a user id', function()
            -- The refresh loop treats this as the end. Without it, a page it
            -- cannot derive a cursor from would be requested again forever.
            assert.is_nil(discord.cursorFrom({ { roles = { '1' } }, { roles = { '2' } } }))
        end)
    end)

    describe('rowsFrom', function()
        it('pairs each member with their roles', function()
            local rows = discord.rowsFrom({
                { user = { id = '900' }, roles = { '111' } },
                { user = { id = '901' }, roles = {} },
            })

            assert.are.same({
                { discordId = '900', roles = { '111' } },
                { discordId = '901', roles = {} },
            }, rows)
        end)

        it('skips members with no user id rather than writing a nil key', function()
            local rows = discord.rowsFrom({
                { user = { id = '900' }, roles = { '111' } },
                { roles = { '222' } },
            })

            assert.are.equal(1, #rows)
            assert.are.equal('900', rows[1].discordId)
        end)
    end)

    describe('isConfigured', function()
        it('needs both a token and a guild id', function()
            assert.is_true(discord.isConfigured({ token = 'x', guildId = 'y' }))
        end)

        it('is false when either is missing or blank', function()
            assert.is_false(discord.isConfigured({ token = '', guildId = 'y' }))
            assert.is_false(discord.isConfigured({ token = 'x', guildId = '' }))
            assert.is_false(discord.isConfigured({ token = 'x' }))
            assert.is_false(discord.isConfigured(nil))
        end)
    end)
end)

describe('setup', function()
    local admin

    before_each(function()
        admin = helper.load({ 'server/modules/admin/service' }).Modules.admin
    end)

    describe('generateSetupCode', function()
        it('is six characters', function()
            assert.are.equal(6, #admin.generateSetupCode())
        end)

        it('avoids the characters people misread off a console', function()
            -- 0/O and 1/I. The code is read in one window and typed in another.
            for _ = 1, 200 do
                local code = admin.generateSetupCode()
                assert.is_nil(code:find('[01OI]'), 'ambiguous character in ' .. code)
            end
        end)

        it('draws every character from the alphabet', function()
            local code = admin.generateSetupCode(function() return 1 end)
            assert.are.equal('222222', code)
        end)
    end)

    describe('codeMatches', function()
        it('accepts the right code in any case', function()
            assert.is_true(admin.codeMatches('ABC234', 'ABC234'))
            assert.is_true(admin.codeMatches('abc234', 'ABC234'))
        end)

        it('rejects the wrong code', function()
            assert.is_false(admin.codeMatches('ABC235', 'ABC234'))
        end)

        it('never matches once setup has run and the code is cleared', function()
            -- `expected` is nil from that point on. Matching here would reopen
            -- the one path that can create an administrator.
            assert.is_false(admin.codeMatches('ABC234', nil))
            assert.is_false(admin.codeMatches('', nil))
            assert.is_false(admin.codeMatches('', ''))
            assert.is_false(admin.codeMatches(nil, 'ABC234'))
        end)
    end)

    describe('bootstrapStatements', function()
        local agency = { id = 'lspd', name = 'Los Santos PD', shortName = 'LSPD' }
        local officer = { discordId = '900', callsign = nil, name = 'A. Lindqvist' }

        it('creates the agency, the officer, and one mapping per role', function()
            local statements = admin.bootstrapStatements(agency, officer, { '111', '222' })

            assert.are.equal(4, #statements)
            assert.is_truthy(statements[1].query:find('fpd_agencies'))
            assert.is_truthy(statements[2].query:find('fpd_officers'))
            assert.is_truthy(statements[3].query:find('fpd_role_map'))
            assert.is_truthy(statements[4].query:find('fpd_role_map'))
        end)

        it('maps every role the officer holds, not just the first', function()
            -- FredPD cannot see Discord's role hierarchy, so "their highest
            -- role" is not a thing it can pick. Mapping all of them is what
            -- makes setup work whatever the roles are called.
            local statements = admin.bootstrapStatements(agency, officer, { '111', '222', '333' })

            assert.are.equal('111', statements[3].values[1])
            assert.are.equal('222', statements[4].values[1])
            assert.are.equal('333', statements[5].values[1])
        end)

        it('binds the officer to the configured agency', function()
            local statements = admin.bootstrapStatements(agency, officer, { '111' })

            assert.are.same({ '900', 'lspd', nil, 'A. Lindqvist' }, statements[2].values)
        end)

        it('is parameterized throughout', function()
            -- Invariant 8. The only literal in these statements is the group
            -- key 'admin', which is a constant and never comes from input.
            local statements = admin.bootstrapStatements(agency, officer, { '111' })

            for index = 1, #statements do
                assert.is_nil(statements[index].query:find('900'), 'value inlined into SQL')
                assert.is_nil(statements[index].query:find('lspd'), 'value inlined into SQL')
                assert.is_table(statements[index].values)
            end
        end)

        it('writes no mappings when the officer holds no roles', function()
            local statements = admin.bootstrapStatements(agency, officer, {})
            assert.are.equal(2, #statements)
        end)
    end)
end)
