--- Motor pool routes (spec 7.31).
---
--- Drawing and returning a vehicle requires being on duty and standing at a
--- `motorpool` placement, both verified server-side (spec 3.10, 4.3). The ped is
--- an entrance, not an authorisation.
---
--- The fleet *editor* at the bottom of this file carries neither condition, and
--- the comment there says why.

local route = FredPD.Core.route
local service = FredPD.Modules.garage
local repo = FredPD.Repo.garage

--- The officer's certifications. Full certification tracking is M6 (spec 7.23);
--- until then nobody holds one, so any fleet entry that requires a certification
--- is simply not offered. That fails closed, which is the right direction.
local function certificationsFor(_session)
    return {}
end

local function permissionChecker(session)
    return function(permission)
        return FredPD.Core.perms.satisfies(session.permissions, permission)
    end
end

route.define({
    name = 'garage.fleet',
    perm = 'garage.vehicle.draw',
    schema = 'FleetList',
    context = { onDuty = true, accessPoint = 'motorpool' },
    handler = function(session, _input)
        local fleet = repo.fleetFor(session.agencyId)

        return {
            fleet = service.allowedFleet(fleet, permissionChecker(session), certificationsFor(session)),
        }
    end,
})

route.define({
    name = 'garage.draw',
    perm = 'garage.vehicle.draw',
    schema = 'GarageDraw',
    context = { onDuty = true, accessPoint = 'motorpool' },
    limit = { per = 10, window = 60 },
    writes = true,
    audit = 'garage.drawn',
    subjectType = 'vehicle',
    auditDetail = function(input, result)
        return { model = input.model, plate = result and result.plate }
    end,
    handler = function(session, input)
        local fleet = repo.fleetFor(session.agencyId)

        -- Looked up among what this officer is *allowed* to draw, so asking for
        -- a model the menu never offered fails here rather than succeeding.
        local entry = service.findAllowed(
            fleet, input.model, permissionChecker(session), certificationsFor(session)
        )

        if not entry then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        local plate = service.generatePlate(session.agencyId)

        -- The agency owns the fleet, not the officer driving it (spec 7.31).
        -- A society that is unavailable does not block the draw: the vehicle
        -- still spawns and the draw is still logged against the officer, which
        -- is the part that matters for accountability.
        FredPD.Bridge.society.registerVehicle(session.agencyId, plate, entry.model)

        repo.log('draw', session, entry.model, plate, input.placementId)

        return { model = entry.model, plate = plate, livery = entry.livery }
    end,
})

route.define({
    name = 'garage.return',
    perm = 'garage.vehicle.return',
    schema = 'GarageReturn',
    context = { onDuty = true, accessPoint = 'motorpool' },
    writes = true,
    audit = 'garage.returned',
    subjectType = 'vehicle',
    auditDetail = function(input)
        return { plate = input.plate }
    end,
    handler = function(session, input)
        local plate = input.plate:upper()
        local latest = repo.latestEvent(session.agencyId, plate)

        -- Only a vehicle this agency's motor pool actually issued can be
        -- returned to it. Otherwise any emergency vehicle found in the street
        -- could be handed in here.
        if not latest then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        -- And only once. A plate whose last event is already a return has been
        -- handed back; accepting it again would write another log row and
        -- release the vehicle from the society a second time, which is how the
        -- record of who had what out gets muddied (spec 7.31).
        if latest.action ~= 'draw' then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        FredPD.Bridge.society.releaseVehicle(session.agencyId, plate)
        repo.log('return', session, latest.model, plate, input.placementId)

        return { plate = plate }
    end,
})

-- =============================================================================
-- The fleet editor (spec 7.31, [S])
--
-- Until now the fleet was rows inserted by hand in SQL, and `garage.fleet.edit`
-- was a seeded permission no route used. These four routes are that permission.
--
-- They deliberately carry *no* context conditions. The three routes above
-- require being on duty and standing at a motor pool ped, because drawing a
-- vehicle is something you do at the motor pool. Configuring which vehicles
-- exist is not: an administrator does it from the MDT, in uniform or out of it,
-- and a `motorpool` access point on these routes would mean the fleet can only
-- be edited by walking to a ped -- a rule with nothing behind it. What restricts
-- them is `garage.fleet.edit`, checked on the server for every call like any
-- other permission (invariant 4).
--
-- `label_key` is a locale key, never a display name (invariant 6). The editor
-- accepts `fleet.cruiser`; the NUI renders whatever the locale files say that
-- is. `service.isLocaleKey` is what stops "Police Cruiser" being stored in a
-- column no translation can reach.
-- =============================================================================

--- Does this permission group exist?
---
--- A gate naming a group that was never created, or one deleted since, is a
--- typo that silently locks the vehicle to nobody. Refusing it at write time
--- means the administrator finds out now, with the field named, instead of a
--- unit finding out at shift change.
local function groupExists(key)
    return FredPD.Core.perms.permissionsOf(key) ~= nil
end

--- The gating fields, for the audit entry.
---
--- Worth recording precisely: these decide who may take a vehicle out, so
--- "fleet entry updated" on its own tells the next administrator nothing they
--- can act on (invariant 11).
local function gatingDetail(input)
    return {
        model = input.model,
        labelKey = input.labelKey,
        permission = input.permission,
        certification = input.certification,
        requiredGroup = input.requiredGroup,
        requiredDiscordRole = input.requiredDiscordRole,
        enabled = input.enabled,
    }
end

route.define({
    name = 'garage.fleet.manage',
    perm = 'garage.fleet.edit',
    schema = 'FleetManage',
    -- A read, marked like the writes beside it, for the same reason
    -- `admin.group.list` is: this is the configuration screen behind the motor
    -- pool, and there is no version of an outage where somebody needs to open
    -- it against a Discord snapshot nobody can vouch for (spec 4.2).
    writes = true,
    audit = 'garage.fleet.listed',
    auditDetail = function(_input, result)
        return { count = #result.fleet }
    end,
    handler = function(session, _input)
        return {
            -- The agency comes from the session. An administrator configures
            -- their own motor pool, and an agency id in the input would be an
            -- attack rather than a field (invariant 1).
            fleet = repo.fleetAll(session.agencyId),

            -- The group keys the editor may offer for `requiredGroup`, so the
            -- field is a list to pick from rather than a string to mistype.
            -- Taken from the permission cache, which is the same place the gate
            -- is resolved from when a vehicle is drawn.
            groups = FredPD.Core.perms.groupKeys(),
        }
    end,
})

route.define({
    name = 'garage.fleet.add',
    perm = 'garage.fleet.edit',
    schema = 'FleetAdd',
    writes = true,
    audit = 'garage.fleet.added',
    subjectType = 'fleet_entry',
    auditDetail = function(input)
        return gatingDetail(input)
    end,
    handler = function(session, input)
        local entry = service.normalizeFleetInput(input)

        local err, fields = service.validateFleetInput(entry, true)
        if err then return route.refuse(err, fields) end

        if entry.requiredGroup and entry.requiredGroup ~= '' and not groupExists(entry.requiredGroup) then
            return route.refuse(FredPD.ErrorCode.INVALID, { requiredGroup = 'unknown' })
        end

        -- `(agency_id, model)` is unique. Refusing here turns a duplicate into a
        -- field error instead of an internal one, and says which field.
        if repo.fleetEntryByModel(session.agencyId, entry.model) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { model = 'exists' })
        end

        return { id = repo.addFleet(session.agencyId, entry), model = entry.model }
    end,
})

route.define({
    name = 'garage.fleet.update',
    perm = 'garage.fleet.edit',
    schema = 'FleetUpdate',
    writes = true,
    audit = 'garage.fleet.updated',
    subjectType = 'fleet_entry',
    auditDetail = function(input)
        return gatingDetail(input)
    end,
    handler = function(session, input)
        local existing = repo.fleetEntry(session.agencyId, input.id)
        if not existing then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local entry = service.normalizeFleetInput(input)

        local err, fields = service.validateFleetInput(entry, false)
        if err then return route.refuse(err, fields) end

        if entry.requiredGroup and entry.requiredGroup ~= '' and not groupExists(entry.requiredGroup) then
            return route.refuse(FredPD.ErrorCode.INVALID, { requiredGroup = 'unknown' })
        end

        if entry.model and entry.model ~= existing.model
            and repo.fleetEntryByModel(session.agencyId, entry.model)
        then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { model = 'exists' })
        end

        local affected = repo.updateFleet(session.agencyId, input.id, entry)

        if affected == nil then
            return route.refuse(FredPD.ErrorCode.INVALID, { _input = 'nothing_to_change' })
        end

        -- Zero rows is also what a save that changed nothing returns, so it is
        -- only an error when the row has genuinely gone -- deleted by another
        -- administrator between the read above and the write.
        if affected == 0 and not repo.fleetEntry(session.agencyId, input.id) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id, model = entry.model or existing.model }
    end,
})

route.define({
    name = 'garage.fleet.remove',
    perm = 'garage.fleet.edit',
    schema = 'FleetRemove',
    writes = true,
    audit = 'garage.fleet.removed',
    subjectType = 'fleet_entry',
    auditDetail = function(_input, result)
        return { model = result and result.model }
    end,
    handler = function(session, input)
        local existing = repo.fleetEntry(session.agencyId, input.id)
        if not existing then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        if repo.removeFleet(session.agencyId, input.id) == 0 then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        return { id = input.id, model = existing.model }
    end,
})
