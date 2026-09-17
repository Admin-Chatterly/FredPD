--- Motor pool routes (spec 7.31).
---
--- Every route here requires being on duty and standing at a `motorpool`
--- placement, both verified server-side (spec 3.10, 4.3). The ped is an
--- entrance, not an authorisation.

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
    audit = 'garage.returned',
    subjectType = 'vehicle',
    auditDetail = function(input)
        return { plate = input.plate }
    end,
    handler = function(session, input)
        local plate = input.plate:upper()
        local outstanding = repo.outstandingDraw(session.agencyId, plate)

        -- Only a vehicle this agency's motor pool actually issued can be
        -- returned to it. Otherwise any emergency vehicle found in the street
        -- could be handed in here.
        if not outstanding then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND)
        end

        FredPD.Bridge.society.releaseVehicle(session.agencyId, plate)
        repo.log('return', session, outstanding.model, plate, input.placementId)

        return { plate = plate }
    end,
})
