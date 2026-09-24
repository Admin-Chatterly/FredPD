--- Discord role actions (ADR-022): who may ask for a role change.

local helper = require('spec.helper')

describe('personnel role actions', function()
    local P, perms

    local HIRE <const> = '111111111111111111'
    local RANK <const> = '222222222222222222'

    local function set(list)
        local out = {}
        for _, key in ipairs(list) do out[key] = true end
        return out
    end

    local function ask(overrides)
        local args = {
            role = { id = RANK, kind = 'rank' },
            grant = true,
            actorDiscordId = '900000000000000001',
            targetDiscordId = '900000000000000002',
            actorPermissions = set({ 'personnel.promote', 'personnel.hire', 'patrol.view', 'supervisor.view' }),
            targetPermissions = set({ 'patrol.view' }),
            rolePermissions = set({ 'supervisor.view' }),
            satisfies = perms.satisfies,
            missing = perms.missing,
        }
        for key, value in pairs(overrides or {}) do args[key] = value end
        return P.roleChange(args)
    end

    before_each(function()
        local loaded = helper.load({ 'server/core/perms', 'server/modules/personnel/service' })
        P = loaded.Modules.personnel
        perms = loaded.Core.perms
    end)

    it('keeps only roles config names with a Discord id and a known kind', function()
        local roles = P.manageableRoles({
            { id = HIRE, kind = 'hire' },
            { id = RANK, kind = 'rank' },
            { id = '123', kind = 'rank' },
            { id = '333333333333333333', kind = 'admin' },
            { id = 333333333333333333, kind = 'rank' },
        })

        assert.are.same({ id = HIRE, kind = 'hire' }, roles[HIRE])
        assert.are.same({ id = RANK, kind = 'rank' }, roles[RANK])
        local count = 0
        for _ in pairs(roles) do count = count + 1 end
        assert.are.equal(2, count)
    end)

    it('lets a commander promote a patrol officer to a rank worth no more than their own', function()
        assert.is_true(ask())
    end)

    it('refuses a role config does not list', function()
        local ok, why = ask({ role = false })
        assert.is_false(ok)
        assert.are.equal('not_allowed', why)
    end)

    it('never lets an officer change their own roles', function()
        local ok, why = ask({ targetDiscordId = '900000000000000001' })
        assert.is_false(ok)
        assert.are.equal('self', why)
    end)

    it('asks for personnel.promote for a rank and personnel.hire for the hire role', function()
        local ok, why, detail = ask({ actorPermissions = set({ 'personnel.hire', 'supervisor.view', 'patrol.view' }) })
        assert.is_false(ok)
        assert.are.equal('needs_permission', why)
        assert.are.equal('personnel.promote', detail.permission)

        ok, why, detail = ask({
            role = { id = HIRE, kind = 'hire' },
            actorPermissions = set({ 'personnel.promote', 'supervisor.view', 'patrol.view' }),
        })
        assert.is_false(ok)
        assert.are.equal('needs_permission', why)
        assert.are.equal('personnel.hire', detail.permission)
    end)

    it('never grants a role worth more than the actor holds', function()
        local ok, why, detail = ask({ rolePermissions = set({ 'supervisor.view', 'admin.permissions.edit' }) })
        assert.is_false(ok)
        assert.are.equal('exceeds_own', why)
        assert.are.same({ 'admin.permissions.edit' }, detail.missing)
    end)

    it('lets a role be taken away even when it is worth more than the actor holds, but not from a superior', function()
        -- Removing: what the role is worth does not matter...
        assert.is_true(ask({ grant = false, rolePermissions = set({ 'admin.permissions.edit' }) }))

        -- ...who holds it does.
        local ok, why = ask({ grant = false, targetPermissions = set({ 'patrol.view', 'command.view' }) })
        assert.is_false(ok)
        assert.are.equal('outranks', why)
    end)

    it('lets a superuser past the worth checks, never past the self rule', function()
        assert.is_true(ask({
            superuser = true,
            actorPermissions = { ['*'] = true },
            targetPermissions = set({ 'command.view' }),
            rolePermissions = set({ 'admin.permissions.edit' }),
        }))

        local ok, why = ask({ superuser = true, actorPermissions = { ['*'] = true }, targetDiscordId = '900000000000000001' })
        assert.is_false(ok)
        assert.are.equal('self', why)
    end)
end)
