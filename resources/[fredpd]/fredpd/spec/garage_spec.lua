--- Motor pool (spec 7.31).
---
--- The fleet filter decides which vehicles an officer is offered *and* which
--- they may actually draw. Both answers come from the same function on the
--- server, so a client asking for a vehicle it was never shown still fails.

local helper = require('spec.helper')

describe('garage', function()
    local garage

    before_each(function()
        garage = helper.load({ 'server/modules/garage/service' }).Modules.garage
    end)

    local fleet = {
        { model = 'police', labelKey = 'fleet.cruiser', enabled = true },
        { model = 'police2', labelKey = 'fleet.interceptor', permission = 'garage.pursuit', enabled = true },
        { model = 'polmav', labelKey = 'fleet.helicopter', certification = 'air', enabled = true },
        { model = 'riot', labelKey = 'fleet.riot', permission = 'garage.tactical', certification = 'tactical', enabled = true },
        { model = 'police4', labelKey = 'fleet.unmarked', enabled = false },
    }

    local function grants(...)
        local held = {}
        for _, permission in ipairs({ ... }) do held[permission] = true end

        return function(permission) return held[permission] == true end
    end

    local function certified(...)
        local held = {}
        for _, name in ipairs({ ... }) do held[name] = true end
        return held
    end

    describe('allowedFleet', function()
        it('offers the unrestricted vehicles to any officer', function()
            local allowed = garage.allowedFleet(fleet, grants(), certified())

            assert.are.equal(1, #allowed)
            assert.are.equal('police', allowed[1].model)
        end)

        it('offers a permission-gated vehicle once the permission is held', function()
            local allowed = garage.allowedFleet(fleet, grants('garage.pursuit'), certified())

            assert.are.equal(2, #allowed)
        end)

        it('withholds a vehicle whose certification the officer lacks', function()
            local allowed = garage.allowedFleet(fleet, grants(), certified())

            for index = 1, #allowed do
                assert.are_not.equal('polmav', allowed[index].model)
            end
        end)

        it('offers it once the certification is held', function()
            local allowed = garage.allowedFleet(fleet, grants(), certified('air'))
            local models = {}
            for index = 1, #allowed do models[allowed[index].model] = true end

            assert.is_true(models.polmav)
        end)

        it('requires both when an entry demands a permission and a certification', function()
            local permissionOnly = garage.allowedFleet(fleet, grants('garage.tactical'), certified())
            local certificationOnly = garage.allowedFleet(fleet, grants(), certified('tactical'))
            local both = garage.allowedFleet(fleet, grants('garage.tactical'), certified('tactical'))

            local function includes(list, model)
                for index = 1, #list do
                    if list[index].model == model then return true end
                end
                return false
            end

            assert.is_false(includes(permissionOnly, 'riot'))
            assert.is_false(includes(certificationOnly, 'riot'))
            assert.is_true(includes(both, 'riot'))
        end)

        it('never offers a disabled entry', function()
            local allowed = garage.allowedFleet(fleet, grants('garage.pursuit', 'garage.tactical'), certified('air', 'tactical'))

            for index = 1, #allowed do
                assert.are_not.equal('police4', allowed[index].model)
            end
        end)
    end)

    describe('findAllowed', function()
        it('finds a vehicle the officer may draw', function()
            local entry = garage.findAllowed(fleet, 'police', grants(), certified())

            assert.is_not_nil(entry)
            assert.are.equal('police', entry.model)
        end)

        it('refuses a model the officer was never offered', function()
            -- The restriction is applied here, on the server, not by the menu
            -- that displayed it.
            assert.is_nil(garage.findAllowed(fleet, 'polmav', grants(), certified()))
            assert.is_nil(garage.findAllowed(fleet, 'police2', grants(), certified()))
        end)

        it('refuses a disabled model', function()
            assert.is_nil(garage.findAllowed(fleet, 'police4', grants(), certified()))
        end)

        it('refuses a model that is not in the fleet at all', function()
            assert.is_nil(garage.findAllowed(fleet, 'adder', grants(), certified()))
        end)
    end)

    describe('generatePlate', function()
        it('produces an 8 character plate', function()
            assert.are.equal(8, #garage.generatePlate('LSPD'))
        end)

        it('starts with the agency prefix', function()
            assert.are.equal('LSPD', garage.generatePlate('LSPD'):sub(1, 4))
        end)

        it('upper-cases the prefix', function()
            assert.are.equal('LSPD', garage.generatePlate('lspd'):sub(1, 4))
        end)

        it('still fills the plate when there is no prefix', function()
            assert.are.equal(8, #garage.generatePlate(''))
            assert.are.equal(8, #garage.generatePlate(nil))
        end)

        it('truncates a prefix that would leave no room for the random part', function()
            local plate = garage.generatePlate('VERYLONGAGENCY')

            assert.are.equal(8, #plate)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- Gating (migration 0003)
    --
    -- The rule the user chose: either gate opens the vehicle, and an entry with
    -- neither is open to anyone. Every branch of that sentence is one test,
    -- because the failure modes point in opposite directions -- an `and` where
    -- the `or` belongs takes a unit's vehicles away, and the reverse hands the
    -- air fleet to the whole department.
    -- -------------------------------------------------------------------------

    describe('gatingSatisfied', function()
        local function holds(...)
            local held = {}
            for _, id in ipairs({ ... }) do held[id] = true end
            return function(roleId) return held[roleId] == true end
        end

        local function satisfies(...)
            local met = {}
            for _, key in ipairs({ ... }) do met[key] = true end
            return function(groupKey) return met[groupKey] == true end
        end

        local AIR_ROLE <const> = '900000000000000001'
        local OTHER_ROLE <const> = '900000000000000002'

        it('lets anyone draw an entry with neither gate set', function()
            assert.is_true(garage.gatingSatisfied({}, holds(), satisfies()))
        end)

        it('treats blank columns as no gate at all', function()
            -- An empty string must never read as "gated on the empty role",
            -- which would take the vehicle away from everyone.
            local entry = { requiredGroup = '', requiredDiscordRole = '   ' }

            assert.is_true(garage.gatingSatisfied(entry, holds(), satisfies()))
        end)

        it('opens on the Discord role alone', function()
            local entry = { requiredDiscordRole = AIR_ROLE }

            assert.is_true(garage.gatingSatisfied(entry, holds(AIR_ROLE), satisfies()))
        end)

        it('opens on the permission group alone', function()
            local entry = { requiredGroup = 'air_support' }

            assert.is_true(garage.gatingSatisfied(entry, holds(), satisfies('air_support')))
        end)

        it('opens on either gate when both are set', function()
            local entry = { requiredGroup = 'air_support', requiredDiscordRole = AIR_ROLE }

            -- The role, without the group.
            assert.is_true(garage.gatingSatisfied(entry, holds(AIR_ROLE), satisfies()))
            -- The group, without the role.
            assert.is_true(garage.gatingSatisfied(entry, holds(), satisfies('air_support')))
            -- Both, which is the ordinary case for a unit that has each.
            assert.is_true(garage.gatingSatisfied(entry, holds(AIR_ROLE), satisfies('air_support')))
        end)

        it('refuses when neither gate is met', function()
            local entry = { requiredGroup = 'air_support', requiredDiscordRole = AIR_ROLE }

            assert.is_false(garage.gatingSatisfied(entry, holds(OTHER_ROLE), satisfies('patrol')))
        end)

        it('refuses a role gate the officer does not hold', function()
            local entry = { requiredDiscordRole = AIR_ROLE }

            assert.is_false(garage.gatingSatisfied(entry, holds(OTHER_ROLE), satisfies('air_support')))
        end)

        it('refuses a group gate the officer does not satisfy', function()
            local entry = { requiredGroup = 'air_support' }

            assert.is_false(garage.gatingSatisfied(entry, holds(AIR_ROLE), satisfies('patrol')))
        end)

        it('fails closed when a gate names something that does not exist', function()
            -- A group deleted since the gate was written, or a role id with a
            -- typo in it: both predicates answer false, and the vehicle stays
            -- gated rather than falling open.
            local entry = { requiredGroup = 'deleted_group', requiredDiscordRole = '123' }

            assert.is_false(garage.gatingSatisfied(
                entry,
                function() return false end,
                function() return false end
            ))
        end)
    end)

    describe('drawableFleet', function()
        local gated = {
            { model = 'police', labelKey = 'fleet.cruiser', enabled = true },
            {
                model = 'polmav', labelKey = 'fleet.helicopter', enabled = true,
                requiredDiscordRole = '900000000000000001',
            },
            {
                model = 'fbi', labelKey = 'fleet.unmarked', enabled = true,
                requiredGroup = 'detectives',
            },
            {
                model = 'riot2', labelKey = 'fleet.bearcat', enabled = true,
                permission = 'garage.tactical', requiredGroup = 'swat',
            },
        }

        local function models(list)
            local set = {}
            for index = 1, #list do set[list[index].model] = true end
            return set
        end

        local function checks(overrides)
            local base = {
                hasPermission = function() return false end,
                certifications = {},
                holdsDiscordRole = function() return false end,
                satisfiesGroup = function() return false end,
            }

            for key, value in pairs(overrides or {}) do base[key] = value end
            return base
        end

        it('offers only the ungated vehicles to an officer with no gates met', function()
            local drawable = models(garage.drawableFleet(gated, checks()))

            assert.is_true(drawable.police)
            assert.is_nil(drawable.polmav)
            assert.is_nil(drawable.fbi)
        end)

        it('adds the vehicle whose Discord role the officer holds', function()
            local drawable = models(garage.drawableFleet(gated, checks({
                holdsDiscordRole = function(id) return id == '900000000000000001' end,
            })))

            assert.is_true(drawable.polmav)
            assert.is_nil(drawable.fbi)
        end)

        it('adds the vehicle whose permission group the officer satisfies', function()
            local drawable = models(garage.drawableFleet(gated, checks({
                satisfiesGroup = function(key) return key == 'detectives' end,
            })))

            assert.is_true(drawable.fbi)
            assert.is_nil(drawable.polmav)
        end)

        it('still applies the older permission filter on top of the gate', function()
            -- A gate opened is not a permission granted: the entry's own
            -- `permission` is checked as well, and both must pass.
            local groupOnly = models(garage.drawableFleet(gated, checks({
                satisfiesGroup = function(key) return key == 'swat' end,
            })))

            local both = models(garage.drawableFleet(gated, checks({
                hasPermission = function(key) return key == 'garage.tactical' end,
                satisfiesGroup = function(key) return key == 'swat' end,
            })))

            assert.is_nil(groupOnly.riot2)
            assert.is_true(both.riot2)
        end)
    end)

    -- -------------------------------------------------------------------------
    -- The fleet editor's input
    -- -------------------------------------------------------------------------

    describe('isLocaleKey', function()
        it('accepts a locale key', function()
            assert.is_true(garage.isLocaleKey('fleet.cruiser'))
            assert.is_true(garage.isLocaleKey('garage.fleet.helicopterLong'))
        end)

        it('rejects a display name', function()
            -- `label_key` is a key, not a name (invariant 6). A name stored here
            -- is an English string no translation can ever reach.
            assert.is_false(garage.isLocaleKey('Police Cruiser'))
            assert.is_false(garage.isLocaleKey('Polisbil'))
        end)

        it('rejects a key with no second segment', function()
            assert.is_false(garage.isLocaleKey('cruiser'))
        end)

        it('rejects a malformed key', function()
            assert.is_false(garage.isLocaleKey('.cruiser'))
            assert.is_false(garage.isLocaleKey('fleet.'))
            assert.is_false(garage.isLocaleKey('fleet..cruiser'))
        end)
    end)

    describe('validateFleetInput', function()
        local function valid(overrides)
            local entry = {
                model = 'police',
                labelKey = 'fleet.cruiser',
            }

            for key, value in pairs(overrides or {}) do entry[key] = value end
            return entry
        end

        it('accepts a complete entry', function()
            assert.is_nil(garage.validateFleetInput(valid({
                permission = 'garage.tactical',
                certification = 'air',
                requiredGroup = 'air_support',
                requiredDiscordRole = '900000000000000001',
            }), true))
        end)

        it('requires a model and a label key when adding', function()
            local err, fields = garage.validateFleetInput({}, true)

            assert.are.equal('invalid', err)
            assert.are.equal('required', fields.model)
            assert.are.equal('required', fields.labelKey)
        end)

        it('does not require them when updating', function()
            assert.is_nil(garage.validateFleetInput({ enabled = false }, false))
        end)

        it('rejects a blank model even on an update', function()
            -- `model` and `label_key` are NOT NULL, so an empty string is a
            -- missing value rather than "clear this field".
            local _, fields = garage.validateFleetInput({ model = '' }, false)

            assert.are.equal('required', fields.model)
        end)

        it('rejects a display name in the label key', function()
            local err, fields = garage.validateFleetInput(valid({ labelKey = 'Police Cruiser' }), true)

            assert.are.equal('invalid', err)
            assert.are.equal('not_locale_key', fields.labelKey)
        end)

        it('rejects a role name where a snowflake belongs', function()
            local _, fields = garage.validateFleetInput(
                valid({ requiredDiscordRole = 'Air Support' }), true
            )

            assert.are.equal('not_snowflake', fields.requiredDiscordRole)
        end)

        it('rejects a group key that is not one', function()
            local _, fields = garage.validateFleetInput(valid({ requiredGroup = 'Air Support' }), true)

            assert.are.equal('not_group_key', fields.requiredGroup)
        end)

        it('accepts an empty gate as clearing it', function()
            assert.is_nil(garage.validateFleetInput(
                valid({ requiredGroup = '', requiredDiscordRole = '' }), true
            ))
        end)

        it('rejects a permission that is not a permission key', function()
            local _, fields = garage.validateFleetInput(valid({ permission = 'Tactical' }), true)

            assert.are.equal('not_permission_key', fields.permission)
        end)
    end)

    describe('normalizeFleetInput', function()
        it('trims and lower-cases the spawn name', function()
            local entry = garage.normalizeFleetInput({ model = '  POLICE2 ' })

            assert.are.equal('police2', entry.model)
        end)

        it('keeps an empty string, which means clear this gate', function()
            -- An absent field is "leave it alone" and an empty one is "clear
            -- it". Collapsing the two here would make a gate impossible to
            -- remove from the editor.
            local entry = garage.normalizeFleetInput({ requiredGroup = '' })

            assert.are.equal('', entry.requiredGroup)
            assert.is_nil(entry.requiredDiscordRole)
        end)

        it('leaves untouched fields nil', function()
            local entry = garage.normalizeFleetInput({ enabled = false })

            assert.is_nil(entry.model)
            assert.is_nil(entry.labelKey)
            assert.is_false(entry.enabled)
        end)
    end)
end)

-- =============================================================================
-- The routes (spec 7.31, migration 0003)
--
-- The tests above prove the rule. These prove it is *reached*: the gate columns
-- were configurable and unit-tested for a release in which no route evaluated
-- them, so every vehicle a department gated was drawable by every officer. A
-- predicate with no caller is the defect this block exists to catch, which is
-- why the handlers are driven here rather than the service functions.
--
-- `route.define` is stubbed to collect the definitions instead of registering a
-- callback, and the repo, the agency cache and the society bridge are stubbed
-- too; `perms.satisfies` and `perms.missing` are the real ones, because how the
-- group gate composes out of them is exactly what is under test.
-- =============================================================================

describe('garage routes', function()
    local FORBIDDEN <const> = 'forbidden'
    local AIR_ROLE <const> = '900000000000000001'
    local OTHER_ROLE <const> = '900000000000000002'

    --- Loads the module with its neighbours stubbed.
    ---
    --- @param options table
    ---   fleet   rows `repo.fleetFor` returns
    ---   roles   the Discord role ids the snapshot holds for this member
    ---   groups  group key -> set of permissions, as the permission cache holds
    ---   holds   list of permission keys the session carries
    ---   agency  the row `agencies.get` returns
    --- @return table routes by name, table session, table recorded calls
    local function wire(options)
        local FredPD = helper.load({
            'server/core/perms',
            'server/modules/garage/service',
        })

        local calls = { memberRoles = 0, logged = {}, registered = {} }

        FredPD.ErrorCode = { FORBIDDEN = FORBIDDEN, NOT_FOUND = 'not_found' }

        local routes = {}

        FredPD.Core.route = {
            define = function(definition) routes[definition.name] = definition end,
            refuse = function(code, fields) return { __err = code, fields = fields } end,
        }

        -- Only the two lookups that touch the database are replaced. Everything
        -- else about the permission model stays real.
        FredPD.Core.perms.memberRoles = function(_discordId)
            calls.memberRoles = calls.memberRoles + 1
            return options.roles or {}, 0
        end

        FredPD.Core.perms.permissionsOf = function(groupKey)
            return (options.groups or {})[groupKey]
        end

        FredPD.Core.agencies = {
            get = function(_id) return options.agency end,
        }

        FredPD.Repo = FredPD.Repo or {}
        FredPD.Repo.garage = {
            fleetFor = function(_agencyId) return options.fleet or {} end,
            log = function(action, _session, model, plate, placementId)
                calls.logged[#calls.logged + 1] = {
                    action = action, model = model, plate = plate, placementId = placementId,
                }
                return 1
            end,
            latestEvent = function() return nil end,
            fleetAll = function() return {} end,
            fleetEntry = function() return nil end,
            fleetEntryByModel = function() return nil end,
        }

        FredPD.Bridge = {
            society = {
                registerVehicle = function(agencyId, plate, model)
                    calls.registered[#calls.registered + 1] = { agencyId, plate, model }
                end,
                releaseVehicle = function() end,
            },
        }

        assert(loadfile('resources/[fredpd]/fredpd/server/modules/garage/routes.lua'))()

        local permissions = {}
        for _, key in ipairs(options.holds or {}) do permissions[key] = true end

        local session = helper.session({ permissions = permissions })

        return routes, session, calls
    end

    local function models(result)
        local set = {}
        for index = 1, #result.fleet do set[result.fleet[index].model] = true end
        return set
    end

    --- A fleet covering every shape of gate: none, role only, group only, both.
    local function gatedFleet()
        return {
            { model = 'police', labelKey = 'fleet.cruiser', enabled = true },
            {
                model = 'polmav', labelKey = 'fleet.helicopter', enabled = true,
                requiredDiscordRole = AIR_ROLE,
            },
            {
                model = 'fbi', labelKey = 'fleet.unmarked', enabled = true,
                requiredGroup = 'detectives',
            },
            {
                model = 'riot', labelKey = 'fleet.bearcat', enabled = true,
                requiredGroup = 'swat', requiredDiscordRole = OTHER_ROLE,
            },
        }
    end

    --- `detectives` grants one key; `swat` grants two, so a session holding only
    --- the first satisfies neither.
    local GROUPS <const> = {
        detectives = { ['records.person.view'] = true },
        swat = { ['records.person.view'] = true, ['garage.tactical'] = true },
    }

    describe('garage.fleet', function()
        it('lists only the ungated vehicles to an officer who meets no gate', function()
            local routes, session = wire({ fleet = gatedFleet(), groups = GROUPS })
            local listed = models(routes['garage.fleet'].handler(session, {}))

            assert.is_true(listed.police)
            assert.is_nil(listed.polmav)
            assert.is_nil(listed.fbi)
            assert.is_nil(listed.riot)
        end)

        it('lists the role-gated vehicle to the officer holding the role', function()
            local routes, session = wire({
                fleet = gatedFleet(), groups = GROUPS, roles = { AIR_ROLE },
            })

            local listed = models(routes['garage.fleet'].handler(session, {}))

            assert.is_true(listed.polmav)
            assert.is_nil(listed.fbi)
        end)

        it('lists the group-gated vehicle to the officer who satisfies the group', function()
            local routes, session = wire({
                fleet = gatedFleet(), groups = GROUPS, holds = { 'records.person.view' },
            })

            local listed = models(routes['garage.fleet'].handler(session, {}))

            assert.is_true(listed.fbi)
            -- `swat` grants a second key this session does not hold, so the
            -- vehicle gated on it stays out of the list.
            assert.is_nil(listed.riot)
        end)

        it('lists a vehicle gated on both once either gate opens', function()
            -- The role, without the group.
            local roleRoutes, roleSession = wire({
                fleet = gatedFleet(), groups = GROUPS, roles = { OTHER_ROLE },
            })

            assert.is_true(models(roleRoutes['garage.fleet'].handler(roleSession, {})).riot)

            -- The group, without the role.
            local groupRoutes, groupSession = wire({
                fleet = gatedFleet(), groups = GROUPS,
                holds = { 'records.person.view', 'garage.tactical' },
            })

            assert.is_true(models(groupRoutes['garage.fleet'].handler(groupSession, {})).riot)
        end)

        it('fails closed on a gate naming a group the cache never heard of', function()
            local routes, session = wire({
                fleet = {
                    { model = 'fbi', labelKey = 'fleet.unmarked', enabled = true, requiredGroup = 'deleted' },
                },
                groups = GROUPS,
                holds = { 'records.person.view' },
            })

            assert.is_nil(models(routes['garage.fleet'].handler(session, {})).fbi)
        end)

        it('reads the Discord snapshot once, however large the fleet', function()
            -- Forty vehicles must not become forty round trips (spec 12).
            local fleet = {}
            for index = 1, 40 do
                fleet[index] = {
                    model = ('police%d'):format(index),
                    labelKey = 'fleet.cruiser',
                    enabled = true,
                    requiredDiscordRole = AIR_ROLE,
                }
            end

            local routes, session, calls = wire({ fleet = fleet, roles = { AIR_ROLE } })
            local listed = routes['garage.fleet'].handler(session, {})

            assert.are.equal(40, #listed.fleet)
            assert.are.equal(1, calls.memberRoles)
        end)
    end)

    describe('garage.draw', function()
        local function draw(routes, session, model)
            return routes['garage.draw'].handler(session, { model = model, placementId = 7 })
        end

        it('refuses a gated vehicle to a session that holds neither gate', function()
            -- The list would not have offered it; this is the call that arrives
            -- anyway, and it is the one that has to refuse.
            local routes, session, calls = wire({ fleet = gatedFleet(), groups = GROUPS })

            assert.are.equal(FORBIDDEN, draw(routes, session, 'polmav').__err)
            assert.are.equal(FORBIDDEN, draw(routes, session, 'fbi').__err)
            assert.are.equal(FORBIDDEN, draw(routes, session, 'riot').__err)
            assert.are.equal(0, #calls.logged)
            assert.are.equal(0, #calls.registered)
        end)

        it('draws the role-gated vehicle for the officer holding the role', function()
            local routes, session, calls = wire({
                fleet = gatedFleet(), groups = GROUPS, roles = { AIR_ROLE },
                agency = { id = 'lspd', shortName = 'LSPD' },
            })

            local result = draw(routes, session, 'polmav')

            assert.are.equal('polmav', result.model)
            assert.are.equal(1, #calls.logged)
            assert.are.equal('draw', calls.logged[1].action)
        end)

        it('draws the group-gated vehicle for a session holding everything it grants', function()
            local routes, session = wire({
                fleet = gatedFleet(), groups = GROUPS, holds = { 'records.person.view' },
                agency = { id = 'lspd', shortName = 'LSPD' },
            })

            assert.are.equal('fbi', draw(routes, session, 'fbi').model)
        end)

        it('refuses a group gate the session only partly satisfies', function()
            -- `swat` grants two keys. Holding one of them is not holding the
            -- group, and the vehicle stays gated.
            local routes, session = wire({
                fleet = gatedFleet(), groups = GROUPS, holds = { 'records.person.view' },
            })

            assert.are.equal(FORBIDDEN, draw(routes, session, 'riot').__err)
        end)

        it('still draws an ungated vehicle', function()
            local routes, session = wire({
                fleet = gatedFleet(), groups = GROUPS,
                agency = { id = 'lspd', shortName = 'LSPD' },
            })

            assert.are.equal('police', draw(routes, session, 'police').model)
        end)

        it('leaves the draw permission to the route wrapper, not the gate', function()
            -- An ungated vehicle is open to anyone who may draw at all -- it is
            -- not open to everyone. The permission is checked once, by the
            -- route layer, and folding it into the gate here would hide it.
            local routes = wire({ fleet = gatedFleet() })

            assert.are.equal('garage.vehicle.draw', routes['garage.draw'].perm)
            assert.are.equal('garage.vehicle.draw', routes['garage.fleet'].perm)
            assert.is_true(routes['garage.draw'].context.onDuty)
            assert.are.equal('motorpool', routes['garage.draw'].context.accessPoint)
        end)

        it('plates from the agency short name, not the agency key', function()
            -- The key is a primary key chosen at bootstrap -- here
            -- `lspd_metro`, which would have plated the whole agency `LSPD_M`.
            local routes, session, calls = wire({
                fleet = gatedFleet(),
                agency = { id = 'lspd_metro', name = 'Los Santos PD', shortName = 'LSPD' },
            })

            session.agencyId = 'lspd_metro'

            local result = draw(routes, session, 'police')

            assert.are.equal(8, #result.plate)
            assert.are.equal('LSPD', result.plate:sub(1, 4))

            -- The plate the officer is given is the plate logged and the plate
            -- registered to the society: one value, generated once.
            assert.are.equal(result.plate, calls.logged[1].plate)
            assert.are.equal(result.plate, calls.registered[1][2])
        end)

        it('falls back to the agency id when the agency row has gone', function()
            -- A deleted agency still issues a plate rather than raising, the
            -- same way `agencies.nameOf` still renders a name.
            local routes, session = wire({ fleet = gatedFleet() })
            local result = draw(routes, session, 'police')

            assert.are.equal(8, #result.plate)
            assert.are.equal('LSPD', result.plate:sub(1, 4))
        end)
    end)
end)
