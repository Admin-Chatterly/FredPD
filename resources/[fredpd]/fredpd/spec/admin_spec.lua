--- The permission group editor (spec 7.30, 4.3) and the route layer's response
--- envelope (spec 3.5).
---
--- These are the two places where a mistake is not a bug in a page: locking
--- everybody out of the permission editor has no way back through the game, and
--- a silent overwrite between two administrators leaves no trace of the grants
--- it dropped. Both are worth a harness.
---
--- `routes.lua` is not pure the way a `service.lua` is, so it is loaded against
--- a fake `route` registry and an in-memory database rather than a real one.
--- That is the route contract harness spec 11.5 asks for: the handler runs, the
--- rows it would write are visible, and nothing needs a game server.

local helper = require('spec.helper')

--- Loads a resource file into whatever namespace `helper.load` just built.
local function loadInto(path)
    assert(loadfile(('resources/[fredpd]/fredpd/%s.lua'):format(path)))()
end

-- -----------------------------------------------------------------------------
-- A database, in a table
-- -----------------------------------------------------------------------------

--- The rows the group editor touches, and the handful of statements it writes
--- them with. Queries are matched on the distinctive part of their text, so a
--- statement the handlers change shape of shows up as a test that stops seeing
--- the write rather than one that quietly passes.
local function fakeDb(state)
    local db = {}

    local function has(query, fragment)
        return query:find(fragment, 1, true) ~= nil
    end

    --- UPDATE fpd_permission_groups ... WHERE `key` = ? AND `version` = ?
    local function updateGroup(query, values)
        local key = values[#values - 1]
        local expected = values[#values]
        local group = state.groups[key]

        if not group or group.version ~= expected then return 0 end

        local index = 1

        if has(query, '`name` = ?') then
            group.name = values[index]
            index = index + 1
        end

        if has(query, "`inherits` = NULLIF(?, '')") then
            group.inherits = values[index] ~= '' and values[index] or nil
            index = index + 1
        end

        if has(query, "`description` = NULLIF(?, '')") then
            group.description = values[index] ~= '' and values[index] or nil
        end

        group.version = group.version + 1
        state.writes[#state.writes + 1] = { query = query, values = values }

        return 1
    end

    function db.query(query, values)
        local rows = {}

        if has(query, 'SELECT `key`, `inherits`, `version` FROM fpd_permission_groups') then
            for _, group in pairs(state.groups) do
                rows[#rows + 1] = { key = group.key, inherits = group.inherits, version = group.version }
            end

            -- The window the whole lock exists for: another administrator
            -- commits between this read and the write that was judged against it.
            local interleave = state.afterModelRead
            state.afterModelRead = nil
            if interleave then interleave() end

            return rows
        end

        if has(query, 'SELECT `group_key`, `permission` FROM fpd_group_permissions') then
            for key, permissions in pairs(state.permissions) do
                for index = 1, #permissions do
                    rows[#rows + 1] = { group_key = key, permission = permissions[index] }
                end
            end

            return rows
        end

        if has(query, 'SELECT `permission` FROM fpd_group_permissions WHERE group_key = ?') then
            local permissions = state.permissions[values[1]] or {}
            for index = 1, #permissions do rows[index] = { permission = permissions[index] } end
            table.sort(rows, function(left, right) return left.permission < right.permission end)

            return rows
        end

        if has(query, 'FROM fpd_permission_groups g') then
            for _, group in pairs(state.groups) do
                rows[#rows + 1] = {
                    key = group.key,
                    name = group.name,
                    inherits = group.inherits,
                    description = group.description,
                    version = group.version,
                    childCount = 0,
                    roleMapCount = 0,
                    agencyRoleMapCount = 0,
                }
            end

            table.sort(rows, function(left, right) return left.key < right.key end)

            return rows
        end

        return rows
    end

    function db.single(query, values)
        if has(query, 'FROM fpd_permission_groups WHERE `key` = ?') then
            local group = state.groups[values[1]]
            if not group then return nil end

            return {
                key = group.key,
                name = group.name,
                inherits = group.inherits,
                description = group.description,
                version = group.version,
            }
        end

        return nil
    end

    function db.scalar(query, values)
        if has(query, 'COUNT(*) FROM fpd_permission_groups WHERE inherits = ?') then
            local count = 0
            for _, group in pairs(state.groups) do
                if group.inherits == values[1] then count = count + 1 end
            end

            return count
        end

        if has(query, 'COUNT(*) FROM fpd_role_map WHERE group_key = ?') then
            return state.mappings[values[1]] or 0
        end

        if has(query, 'COUNT(*) FROM fpd_permission_groups WHERE `key` = ?') then
            return state.groups[values[1]] and 1 or 0
        end

        return 0
    end

    function db.execute(query, values)
        if has(query, 'UPDATE fpd_permission_groups SET') then
            return updateGroup(query, values)
        end

        if has(query, 'DELETE FROM fpd_permission_groups WHERE `key` = ?') then
            if not state.groups[values[1]] then return 0 end

            state.groups[values[1]] = nil
            state.permissions[values[1]] = nil

            return 1
        end

        return 0
    end

    function db.insert() return 1 end

    function db.transaction(statements)
        for index = 1, #statements do
            local statement = statements[index]
            local values = statement.values

            if has(statement.query, 'INSERT INTO fpd_permission_groups') then
                state.groups[values[1]] = {
                    key = values[1],
                    name = values[2],
                    inherits = values[3] ~= '' and values[3] or nil,
                    description = values[4] ~= '' and values[4] or nil,
                    version = 1,
                }
                state.permissions[values[1]] = state.permissions[values[1]] or {}
            elseif has(statement.query, 'DELETE FROM fpd_group_permissions') then
                state.permissions[values[1]] = {}
            elseif has(statement.query, 'INSERT IGNORE INTO fpd_group_permissions') then
                local permissions = state.permissions[values[1]] or {}
                permissions[#permissions + 1] = values[2]
                state.permissions[values[1]] = permissions
            end
        end

        return true
    end

    return db
end

describe('admin group editor', function()
    local routes, state, denials

    --- A model where the floor keys live in a group `admin` inherits from --
    --- the arrangement the lockout hole lived in.
    local function seed()
        return {
            groups = {
                admin_base = { key = 'admin_base', name = 'Base', version = 3 },
                admin = { key = 'admin', name = 'Administration', inherits = 'admin_base', version = 7 },
                patrol = { key = 'patrol', name = 'Patrol', version = 2 },
            },
            permissions = {
                admin_base = { 'admin.groups.edit', 'admin.permissions.edit', 'page.admin' },
                admin = { 'admin.audit.view' },
                patrol = { 'page.records' },
            },
            mappings = {},
            writes = {},
        }
    end

    --- An administrator who holds everything the seed can grant, so escalation
    --- never decides a test that is about something else.
    local function administrator()
        return helper.session({
            permissions = { ['admin.*'] = true, ['page.*'] = true, ['rms.*'] = true },
        })
    end

    local function call(name, session, input)
        return routes[name].handler(session, input)
    end

    before_each(function()
        state = seed()
        denials = {}

        local FredPD = helper.load({ 'shared/generated/schema', 'server/core/perms' })

        routes = {}

        FredPD.Core.db = fakeDb(state)
        FredPD.Core.route = {
            define = function(definition) routes[definition.name] = definition end,
            refuse = function(code, fields) return { __err = code, fields = fields } end,
        }
        FredPD.Core.audit = {
            denied = function(_session, action, reason) denials[#denials + 1] = action .. ':' .. reason end,
            write = function() end,
        }
        FredPD.Core.session = { refreshAll = function() end }
        FredPD.Core.perms.reload = function() end

        loadInto('server/modules/admin/routes')
    end)

    describe('the admin floor', function()
        it('refuses an edit that strips the floor out of the group admin inherits from', function()
            -- The hole: the floor is measured against `admin`'s expansion, but
            -- the edit names `admin_base`, so the old check never ran.
            local result = call('admin.group.update', administrator(), {
                key = 'admin_base',
                version = 3,
                permissions = { 'admin.audit.view' },
            })

            assert.are.equal('forbidden', result.__err)
            assert.are.equal('would_lock_out', result.fields.permissions)

            -- And nothing was written on the way to refusing.
            assert.are.same(
                { 'admin.groups.edit', 'admin.permissions.edit', 'page.admin' },
                state.permissions.admin_base
            )
            assert.are.equal(3, state.groups.admin_base.version)
        end)

        it('refuses an edit that cuts admin loose from the group holding the floor', function()
            local result = call('admin.group.update', administrator(), {
                key = 'admin',
                version = 7,
                inherits = '',
            })

            assert.are.equal('forbidden', result.__err)
            assert.are.equal('would_lock_out', result.fields.permissions)
            assert.are.equal('admin_base', state.groups.admin.inherits)
        end)

        it('refuses stripping the floor from admin itself when nothing else grants it', function()
            state.groups.admin.inherits = nil
            state.permissions.admin = { 'admin.groups.edit', 'admin.permissions.edit', 'page.admin' }

            local result = call('admin.group.update', administrator(), {
                key = 'admin',
                version = 7,
                permissions = { 'admin.audit.view' },
            })

            assert.are.equal('forbidden', result.__err)
        end)

        it('still lets the floor keys move between groups in the chain', function()
            -- `admin` may hold none of them itself: what is refused is the edit
            -- that leaves the expansion short, not the one that moves a key.
            local result = call('admin.group.update', administrator(), {
                key = 'admin',
                version = 7,
                permissions = {},
            })

            assert.is_nil(result.__err)
            assert.are.same({}, state.permissions.admin)
        end)

        it('leaves an unrelated group editable', function()
            local result = call('admin.group.update', administrator(), {
                key = 'patrol',
                version = 2,
                permissions = { 'page.records', 'rms.person.view' },
            })

            assert.is_nil(result.__err)
            assert.are.same({ 'page.records', 'rms.person.view' }, state.permissions.patrol)
        end)

        it('does not refuse every edit in a database whose floor is already broken', function()
            -- Hand-editing the tables is the only way back in after a lockout.
            -- Asserting the floor outright would refuse the repair as well.
            state.permissions.admin_base = { 'admin.audit.view' }

            local result = call('admin.group.update', administrator(), {
                key = 'patrol',
                version = 2,
                permissions = { 'page.records' },
            })

            assert.is_nil(result.__err)
        end)

        it('refuses a delete that would empty the floor', function()
            -- The ordinary path is closed by the child count; this is the model
            -- where that has not committed yet.
            state.groups.admin.inherits = 'admin_base'
            state.groups.orphan = { key = 'orphan', name = 'Orphan', version = 1 }
            state.permissions.orphan = {}

            -- `admin_base` has a child, so it is refused on the child count.
            local children = call('admin.group.delete', administrator(), { key = 'admin_base' })
            assert.are.equal('conflict', children.__err)
            assert.are.equal('inherited_by_groups', children.fields.inherits)

            -- The group nothing depends on still deletes.
            local orphan = call('admin.group.delete', administrator(), { key = 'orphan' })
            assert.is_nil(orphan.__err)
            assert.is_nil(state.groups.orphan)
        end)

        it('refuses to delete the protected group', function()
            local result = call('admin.group.delete', administrator(), { key = 'admin' })

            assert.are.equal('forbidden', result.__err)
            assert.are.equal('protected', result.fields.key)
            assert.is_truthy(state.groups.admin)
        end)
    end)

    describe('optimistic locking', function()
        it('refuses an update that carries no version', function()
            local result = call('admin.group.update', administrator(), {
                key = 'patrol',
                permissions = { 'page.records' },
            })

            assert.are.equal('invalid', result.__err)
            assert.are.equal('required', result.fields.version)
        end)

        it('refuses a save composed against an older version', function()
            local first = call('admin.group.update', administrator(), {
                key = 'patrol',
                version = 2,
                permissions = { 'page.records', 'rms.person.view' },
            })

            assert.is_nil(first.__err)
            assert.are.equal(3, first.version)

            -- The second administrator still holds version 2.
            local second = call('admin.group.update', administrator(), {
                key = 'patrol',
                version = 2,
                permissions = { 'page.records' },
            })

            assert.are.equal('conflict', second.__err)
            assert.are.equal('stale', second.fields.version)

            -- The first administrator's grant is still there.
            assert.are.same({ 'page.records', 'rms.person.view' }, state.permissions.patrol)
        end)

        it('bumps the version even when only permissions change', function()
            call('admin.group.update', administrator(), {
                key = 'patrol',
                version = 2,
                permissions = {},
            })

            assert.are.equal(3, state.groups.patrol.version)
        end)

        it('reports a version on a group that has since been deleted as not found', function()
            state.groups.patrol = nil

            local result = call('admin.group.update', administrator(), {
                key = 'patrol',
                version = 2,
                permissions = {},
            })

            assert.are.equal('not_found', result.__err)
        end)
    end)

    describe('the model lock', function()
        it('serialises writes across the model, whichever group they name', function()
            local before = state.groups.admin.version

            call('admin.group.update', administrator(), {
                key = 'patrol',
                version = 2,
                permissions = { 'page.records' },
            })

            -- Editing `patrol` moved the model on, so an editor still holding
            -- the old `admin` row is refused rather than committing a decision
            -- it made against a model that no longer exists.
            assert.are.equal(before + 1, state.groups.admin.version)

            local stale = call('admin.group.update', administrator(), {
                key = 'admin',
                version = before,
                permissions = { 'admin.audit.view' },
            })

            assert.are.equal('conflict', stale.__err)
        end)

        it('refuses a write whose checks were made against a model that has since changed', function()
            -- Another administrator commits in the window between the model read
            -- and the write it was judged against -- the TOCTOU itself.
            state.afterModelRead = function()
                state.groups.admin.version = state.groups.admin.version + 1
            end

            local result = call('admin.group.update', administrator(), {
                key = 'admin_base',
                version = 3,
                name = 'Renamed',
            })

            assert.are.equal('conflict', result.__err)
            assert.are.equal('Base', state.groups.admin_base.name)
            assert.are.equal(3, state.groups.admin_base.version)
        end)

        it('does not take the lock twice when the edited group is admin itself', function()
            local result = call('admin.group.update', administrator(), {
                key = 'admin',
                version = 7,
                description = 'Configures FredPD',
            })

            assert.is_nil(result.__err)
            assert.are.equal(8, state.groups.admin.version)
        end)
    end)

    describe('reads', function()
        it('lists groups with the version the editor has to send back', function()
            local result = call('admin.group.list', administrator(), {})

            assert.are.equal(3, #result.groups)
            assert.are.equal('admin', result.groups[1].key)
            assert.are.equal(7, result.groups[1].version)
            assert.is_true(result.groups[1].locked)
        end)

        it('is not a write', function()
            -- Read-only mode (spec 4.2, second tier) must not hide the
            -- permission model from the administrator diagnosing the outage.
            assert.is_nil(routes['admin.group.list'].writes)
            assert.is_nil(routes['admin.permission.list'].writes)
            assert.is_nil(routes['admin.permission.list'].audit)

            -- The model itself is still refused against a snapshot nobody can
            -- vouch for, and reading it is still audited.
            assert.is_true(routes['admin.group.list'].sensitive)
            assert.are.equal('group.listed', routes['admin.group.list'].audit)
        end)

        it('offers a group with no permissions of its own as an empty list', function()
            state.permissions.patrol = {}

            local result = call('admin.group.list', administrator(), {})
            local patrol

            for index = 1, #result.groups do
                if result.groups[index].key == 'patrol' then patrol = result.groups[index] end
            end

            assert.are.same({}, patrol.permissions)
            assert.are.same({}, patrol.effective)
        end)
    end)

    describe('escalation', function()
        --- An administrator with the editor and nothing an intelligence officer
        --- has -- the seeded `admin` group, which deliberately carries neither
        --- `records.breakglass` nor `intel.source.identity.view` (spec 4.3,
        --- Appendix C).
        local function editor()
            return helper.session({ permissions = { ['page.*'] = true, ['admin.*'] = true } })
        end

        --- The bundle that is above that administrator, in two halves: the keys
        --- the group holds itself, and the keys it inherits.
        local function seedIntelCommand()
            state.groups.intel_base = { key = 'intel_base', name = 'Intel base', version = 4 }
            state.permissions.intel_base = { 'intel.source.identity.view' }

            state.groups.intel_command = {
                key = 'intel_command',
                name = 'Intel command',
                inherits = 'intel_base',
                version = 5,
            }
            state.permissions.intel_command = { 'page.intel', 'records.breakglass' }
        end

        --- Nothing written, anywhere: not the group's own rows, not its version,
        --- and not the model lock on `admin`.
        local function assertUntouched()
            assert.are.same({ 'page.intel', 'records.breakglass' }, state.permissions.intel_command)
            assert.are.same({ 'intel.source.identity.view' }, state.permissions.intel_base)
            assert.are.equal('intel_base', state.groups.intel_command.inherits)
            assert.are.equal(5, state.groups.intel_command.version)
            assert.are.equal(7, state.groups.admin.version)
            assert.are.equal(0, #state.writes)
        end

        it('refuses an administrator authoring a group worth more than they hold', function()
            local result = call('admin.group.update', editor(), {
                key = 'patrol',
                version = 2,
                permissions = { 'records.breakglass' },
            })

            assert.are.equal('forbidden', result.__err)
            assert.are.equal('admin.group.update:escalation:records.breakglass', denials[1])
            assert.are.same({ 'page.records' }, state.permissions.patrol)
        end)

        it('refuses emptying a group that already carries more than they hold', function()
            -- The result is within the editor's own clearance -- it grants
            -- nothing at all -- so measuring only the proposal lets this
            -- through, and every officer mapped to the group loses the bundle.
            seedIntelCommand()

            local result = call('admin.group.update', editor(), {
                key = 'intel_command',
                version = 5,
                permissions = {},
            })

            assert.are.equal('forbidden', result.__err)
            assert.are.equal('admin.group.update:escalation:existing:records.breakglass', denials[1])
            assertUntouched()
        end)

        it('refuses removing the one key from it they are not cleared to author', function()
            seedIntelCommand()

            local result = call('admin.group.update', editor(), {
                key = 'intel_command',
                version = 5,
                permissions = { 'page.intel' },
            })

            assert.are.equal('forbidden', result.__err)
            assertUntouched()
        end)

        it('refuses cutting it loose from the group it inherits the rest from', function()
            -- No permission row is touched, and the group still grants only what
            -- the editor holds afterwards. The bundle is gutted all the same.
            seedIntelCommand()

            local result = call('admin.group.update', editor(), {
                key = 'intel_command',
                version = 5,
                inherits = '',
                permissions = { 'page.intel' },
            })

            assert.are.equal('forbidden', result.__err)
            assertUntouched()
        end)

        it('refuses a rename of it, as the delete route refuses a delete', function()
            -- The module says reaching into such a group at all is what is
            -- denied: a rename today is an edit tomorrow.
            seedIntelCommand()

            local renamed = call('admin.group.update', editor(), {
                key = 'intel_command',
                version = 5,
                name = 'Renamed',
            })

            assert.are.equal('forbidden', renamed.__err)
            assert.are.equal('Intel command', state.groups.intel_command.name)
            assertUntouched()

            -- The same refusal the other route already gave, so the two agree.
            local deleted = call('admin.group.delete', editor(), { key = 'intel_command' })

            assert.are.equal('forbidden', deleted.__err)
            assert.is_truthy(state.groups.intel_command)
        end)

        it('still lets them edit a group that is within their own clearance', function()
            -- The guard is about the bundle, not about editing being dangerous:
            -- a group they could author, they may also empty.
            seedIntelCommand()

            local result = call('admin.group.update', editor(), {
                key = 'patrol',
                version = 2,
                permissions = {},
            })

            assert.is_nil(result.__err)
            assert.are.same({}, state.permissions.patrol)
            assert.are.same({}, denials)
        end)
    end)
end)

-- -----------------------------------------------------------------------------
-- The response envelope
-- -----------------------------------------------------------------------------

describe('route.markArrays', function()
    local route
    local ARRAY_MT = { __jsontype = 'array' }

    before_each(function()
        -- The marker the encoder exports. FiveM's is lua-cjson's; the shape is
        -- all this needs -- that `route.lua` asks the encoder for its own marker
        -- rather than inventing one.
        _G.json = { array_mt = ARRAY_MT }
        route = helper.load({ 'server/core/route' }).Core.route
    end)

    after_each(function()
        _G.json = nil
    end)

    it('marks an empty list so it encodes as [] rather than {}', function()
        local data = route.markArrays({ permissions = {}, effective = {} })

        assert.are.equal(ARRAY_MT, getmetatable(data.permissions))
        assert.are.equal(ARRAY_MT, getmetatable(data.effective))
    end)

    it('marks the lists nested inside a list of rows', function()
        local data = route.markArrays({
            groups = {
                { key = 'patrol', permissions = { 'page.records' }, effective = {} },
                { key = 'fresh', permissions = {}, effective = {} },
            },
        })

        assert.are.equal(ARRAY_MT, getmetatable(data.groups))
        assert.are.equal(ARRAY_MT, getmetatable(data.groups[2].permissions))
        assert.are.equal(ARRAY_MT, getmetatable(data.groups[2].effective))
    end)

    it('leaves a record alone', function()
        local data = route.markArrays({ group = { key = 'patrol', name = 'Patrol' } })

        assert.is_nil(getmetatable(data.group))
    end)

    it('leaves the values themselves untouched', function()
        local data = route.markArrays({ count = 2, key = 'patrol', rows = { 'a', 'b' } })

        assert.are.equal(2, data.count)
        assert.are.equal('patrol', data.key)
        assert.are.same({ 'a', 'b' }, data.rows)
    end)

    it('does not replace a metatable a value already carries', function()
        local own = {}
        local data = route.markArrays({ rows = setmetatable({}, own) })

        assert.are.equal(own, getmetatable(data.rows))
    end)

    it('survives a value that refers to itself', function()
        local data = { rows = {} }
        data.rows[1] = data

        assert.has_no.errors(function() route.markArrays(data) end)
    end)

    it('does nothing at all when the encoder exports no marker', function()
        _G.json = nil
        route = helper.load({ 'server/core/route' }).Core.route

        local data = route.markArrays({ rows = {} })

        assert.is_nil(getmetatable(data.rows))
    end)
end)
