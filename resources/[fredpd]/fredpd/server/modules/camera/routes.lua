--- Cameras (spec 7.19): CCTV, body-worn and dash cameras, live view and the
--- footage request.
---
--- **Live view** is watched from a station terminal or the dispatch console,
--- by an officer on duty, and every view is audited from its start to its end.
--- Holding `camera.view` is enough to look; anybody else looks only through
--- an approved footage request of their own, for that camera, while its
--- window is open.
---
--- A CCTV camera is a placement (`cctv_camera`): the viewer is handed where it
--- hangs, once. A body-worn camera is an on-duty officer's issued `bodycam`,
--- and a dash camera the agency vehicle an officer is in: where those are is
--- read by the server and sent to the one viewer a few times a second --
--- never broadcast (invariant 5) -- until the view ends, the viewer leaves the
--- terminal, or the camera stops being one (off duty, bodycam handed in, out of
--- the car). The viewer's game then streams the scene around that position;
--- other players and cars there appear only when OneSync puts them in range of
--- the viewer, which is what a camera across the city can show (7.19 is O).
---
--- **A footage request** names one source, a window and a reason, optionally a
--- förundersökning. A supervisor approves or denies it (never their own), and
--- the requester may keep one still from the view as the request's evidence,
--- through the media pipeline (ADR-019).

local route = FredPD.Core.route
local repo = FredPD.Repo.camera
local service = FredPD.Modules.camera

local VIEW <const> = 'camera.view'
local REQUEST <const> = 'camera.footage.request'
local APPROVE <const> = 'camera.footage.approve'

local function config()
    return FredPD.Config.server.cameras or {}
end

local function perms()
    return FredPD.Core.perms
end

-- -----------------------------------------------------------------------------
-- Sources
-- -----------------------------------------------------------------------------

--- The on-duty officer with this roster id, in this agency, or nil.
local function onDutySession(agencyId, officerId)
    for src, session in pairs(FredPD.Core.session.all()) do
        if session.officerId == officerId and session.agencyId == agencyId then
            if FredPD.Bridge.policejob.isOnDuty(src) then return src, session end
            return nil
        end
    end
    return nil
end

--- Is this officer's camera of this kind a camera right now?
local function liveTarget(agencyId, source, officerId)
    local src, session = onDutySession(agencyId, officerId)
    if not src then return nil end

    if source == 'bodycam' then
        if not FredPD.Modules.personnelHolds(officerId, agencyId, 'bodycam') then return nil end
    elseif source == 'dashcam' then
        if not FredPD.Bridge.policejob.isInAgencyVehicle(src) then return nil end
    else
        return nil
    end

    return src, session
end

--- A CCTV camera this agency may use.
local function cctv(agencyId, cameraId)
    local placement = FredPD.Core.placements.get(cameraId)
    if not placement or placement.kind ~= 'cctv_camera' then return nil end
    if not FredPD.Modules.placements.isUsableBy(placement, agencyId) then return nil end
    return placement
end

route.define({
    name = 'camera.sources',
    perm = REQUEST,
    schema = 'CameraSources',
    context = { onDuty = true },
    limit = { per = 20, window = 60 },
    handler = function(session)
        local cameras = {}
        for id, placement in pairs(FredPD.Core.placements.all()) do
            if placement.kind == 'cctv_camera' and FredPD.Modules.placements.isUsableBy(placement, session.agencyId) then
                cameras[#cameras + 1] = { id = id }
            end
        end
        table.sort(cameras, function(a, b) return a.id < b.id end)

        local bodycams, dashcams = {}, {}
        for src, other in pairs(FredPD.Core.session.all()) do
            if other.agencyId == session.agencyId and other.officerId ~= session.officerId
                and FredPD.Bridge.policejob.isOnDuty(src)
            then
                local entry = { officerId = other.officerId, callsign = other.callsign }
                if FredPD.Modules.personnelHolds(other.officerId, session.agencyId, 'bodycam') then
                    bodycams[#bodycams + 1] = entry
                end
                if FredPD.Bridge.policejob.isInAgencyVehicle(src) then dashcams[#dashcams + 1] = entry end
            end
        end

        return {
            cameras = cameras,
            bodycams = bodycams,
            dashcams = dashcams,
            mayView = perms().satisfies(session.permissions, VIEW),
        }
    end,
})

-- -----------------------------------------------------------------------------
-- Live view
-- -----------------------------------------------------------------------------

--- viewer src -> the view: { source, cameraId, officerId, targetSrc, requestId,
--- placementId, agencyId, discordId, startedAt, checkedAt }
local viewers = {}

--- Ends a view: the viewer's client is told, and the view is on the record.
local function endView(src, reason)
    local view = viewers[src]
    if not view then return end
    viewers[src] = nil

    TriggerClientEvent('fredpd:cameraEnded', src, { reason = reason })
    FredPD.Core.audit.write({
        action = 'camera.view.ended',
        discordId = view.discordId,
        agencyId = view.agencyId,
        subjectType = 'camera',
        detail = {
            source = view.source,
            cameraId = view.cameraId,
            officerId = view.officerId,
            requestId = view.requestId,
            seconds = os.time() - view.startedAt,
            reason = reason,
        },
    })
end

--- May this session look through this camera now: by `camera.view`, or by an
--- approved request of its own. Returns the request, when there is one, so a
--- still can be kept under it.
local function authorised(session, source, cameraId, officerId)
    local now = os.time()
    local request
    for _, row in ipairs(repo.approvedFor(session.agencyId, session.discordId, source)) do
        if service.covers(row, source, cameraId, officerId, now) then request = row break end
    end

    return perms().satisfies(session.permissions, VIEW) or request ~= nil, request
end

route.define({
    name = 'camera.view.start',
    perm = REQUEST,
    schema = 'CameraViewStart',
    context = { onDuty = true },
    sensitive = true,
    limit = { per = 10, window = 60 },
    audit = 'camera.view.started',
    subjectType = 'camera',
    auditDetail = function(input, result)
        return { source = input.source, cameraId = input.cameraId, officerId = input.officerId, requestId = result.requestId }
    end,
    handler = function(session, input)
        -- At a terminal a camera is watched from, checked where the player is.
        local placement = FredPD.Core.placements.get(input.placementId)
        if not placement or not service.TERMINALS[placement.kind]
            or not FredPD.Core.placements.playerIsAt(session.src, input.placementId, placement.kind)
        then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { placementId = 'not_at_terminal' })
        end

        local allowed, request = authorised(session, input.source, input.cameraId, input.officerId)
        if not allowed then return route.refuse(FredPD.ErrorCode.FORBIDDEN, { source = 'needs_request' }) end

        endView(session.src, 'replaced')

        local view = {
            source = input.source,
            requestId = request and request.id or nil,
            placementId = input.placementId,
            agencyId = session.agencyId,
            discordId = session.discordId,
            startedAt = os.time(),
            checkedAt = os.time(),
        }

        local answer = { source = input.source, requestId = view.requestId }

        if input.source == 'cctv' then
            local camera = input.cameraId and cctv(session.agencyId, input.cameraId)
            if not camera then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { cameraId = 'unknown' }) end
            view.cameraId = camera.id
            answer.position = { x = camera.x, y = camera.y, z = camera.z, heading = camera.heading or 0.0 }
            answer.label = ('CCTV %d'):format(camera.id)
        else
            if not input.officerId or input.officerId == session.officerId then
                return route.refuse(FredPD.ErrorCode.INVALID, { officerId = 'unknown' })
            end
            local targetSrc, target = liveTarget(session.agencyId, input.source, input.officerId)
            if not targetSrc then return route.refuse(FredPD.ErrorCode.CONFLICT, { officerId = 'no_camera' }) end
            view.officerId = input.officerId
            view.targetSrc = targetSrc
            answer.label = target.callsign or tostring(input.officerId)
        end

        viewers[session.src] = view
        return answer
    end,
})

route.define({
    name = 'camera.view.stop',
    perm = REQUEST,
    schema = 'CameraViewStop',
    handler = function(session)
        endView(session.src, 'stopped')
        return {}
    end,
})

--- Where the camera a view looks through is now, or nil when it is no longer
--- a camera.
local function frameFor(view)
    local ped = GetPlayerPed(view.targetSrc)
    if not ped or ped == 0 then return nil end

    local entity = ped
    if view.source == 'dashcam' then
        entity = GetVehiclePedIsIn(ped, false)
        if not entity or entity == 0 then return nil end
    end

    local coords = GetEntityCoords(entity)
    return service.mount(view.source, coords.x, coords.y, coords.z, GetEntityHeading(entity))
end

CreateThread(function()
    while true do
        local interval = math.max(100, tonumber(config().frameMs) or 250)
        Wait(interval)

        local now = os.time()
        for src, view in pairs(viewers) do
            -- Every couple of seconds: the viewer is still at the terminal, and
            -- the camera is still a camera.
            if now - view.checkedAt >= 2 then
                view.checkedAt = now
                if not FredPD.Core.session.get(src) then
                    endView(src, 'viewer_gone')
                elseif not FredPD.Core.placements.playerIsAt(src, view.placementId) then
                    endView(src, 'left_terminal')
                elseif view.targetSrc and not liveTarget(view.agencyId, view.source, view.officerId) then
                    endView(src, 'camera_off')
                end
            end

            if viewers[src] and view.targetSrc then
                local frame = frameFor(view)
                if frame then
                    TriggerClientEvent('fredpd:cameraFrame', src, frame)
                else
                    endView(src, 'camera_off')
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    endView(src, 'viewer_gone')
    for viewer, view in pairs(viewers) do
        if view.targetSrc == src then endView(viewer, 'camera_off') end
    end
end)

-- -----------------------------------------------------------------------------
-- Footage requests
-- -----------------------------------------------------------------------------

local function mayApprove(session)
    return perms().satisfies(session.permissions, APPROVE)
end

local function shaped(row)
    local out = {}
    for key, value in pairs(row) do out[key] = value end
    if row.stillRef then
        out.stillUrl, out.stillThumbUrl = FredPD.Modules.mediaApi.links(row.stillRef)
    end
    out.stillRef = nil
    return out
end

route.define({
    name = 'camera.footage.list',
    perm = REQUEST,
    schema = 'FootageList',
    handler = function(session, input)
        local rows = repo.list(session.agencyId, session.discordId, mayApprove(session), input.status, 100)
        local out = {}
        for index, row in ipairs(rows) do
            out[index] = shaped(row)
            out[index].mine = row.requestedBy == session.discordId
        end
        return { requests = out, mayApprove = mayApprove(session) }
    end,
})

route.define({
    name = 'camera.footage.request',
    perm = REQUEST,
    schema = 'FootageRequest',
    writes = true,
    limit = { per = 10, window = 60 },
    audit = 'camera.footage.requested',
    subjectType = 'footage',
    auditDetail = function(input, result)
        return { number = result.number, source = input.source, cameraId = input.cameraId, officerId = input.officerId }
    end,
    handler = function(session, input)
        local request, fields = service.validateRequest(input, os.time(), config().maxWindowHours)
        if not request then return route.refuse(FredPD.ErrorCode.INVALID, fields) end

        if request.source == 'cctv' and not cctv(session.agencyId, request.cameraId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { cameraId = 'unknown' })
        end
        if request.officerId and not FredPD.Repo.personnel.byId(request.officerId, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { officerId = 'unknown' })
        end

        -- An investigation it is for must be one this officer may read.
        if input.fuId then
            local fu = FredPD.Repo.anmalan.fuById(input.fuId, session.agencyId)
            if not fu or not FredPD.Repo.access.read(session, 'case', fu) then
                return route.refuse(FredPD.ErrorCode.NOT_FOUND, { fuId = 'unknown' })
            end
            request.fuId = input.fuId
        end

        local row = repo.insert(request, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        FredPD.Core.push.notifyPermission(APPROVE, 'camera.notify.requested', { number = row.number }, nil,
            function(other) return other.agencyId == session.agencyId and other.discordId ~= session.discordId end)

        return { id = row.id, number = row.number }
    end,
})

route.define({
    name = 'camera.footage.decide',
    perm = APPROVE,
    schema = 'FootageDecide',
    writes = true,
    sensitive = true,
    limit = { per = 20, window = 60 },
    audit = 'camera.footage.decided',
    subjectType = 'footage',
    auditDetail = function(input, result) return { number = result.number, approve = input.approve } end,
    handler = function(session, input)
        local row = repo.byId(input.id, session.agencyId)
        if not row then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        -- Nobody approves their own request to look.
        if row.requestedBy == session.discordId then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN, { id = 'own_request' })
        end

        local changed = repo.decide(row.id, session.agencyId, input.version, input.approve, session.discordId, input.note)
        if (changed or 0) == 0 then return route.refuse(FredPD.ErrorCode.CONFLICT, { version = 'stale' }) end

        return { id = row.id, number = row.number }
    end,
})

-- -----------------------------------------------------------------------------
-- The still
-- -----------------------------------------------------------------------------

--- The request a still may be kept under: this officer's, approved, open now,
--- and the one the view they are watching was started under.
local function stillRequest(session, requestId)
    local view = viewers[session.src]
    if not view or view.requestId ~= requestId then return nil end

    local row = repo.byId(requestId, session.agencyId)
    if not row or row.requestedBy ~= session.discordId or row.stillRef then return nil end
    if not service.covers(row, view.source, view.cameraId, view.officerId, os.time()) then return nil end

    return row
end

route.define({
    name = 'camera.still.begin',
    perm = REQUEST,
    schema = 'FootageStillBegin',
    writes = true,
    limit = { per = 5, window = 60 },
    handler = function(session, input)
        if not stillRequest(session, input.requestId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { requestId = 'not_viewing' })
        end

        local begun, refusal = FredPD.Modules.mediaApi.begin(session, 'footage_still', input.requestId)
        if not begun then return refusal end
        return begun
    end,
})

route.define({
    name = 'camera.still.commit',
    perm = REQUEST,
    schema = 'FootageStillCommit',
    writes = true,
    limit = { per = 5, window = 60 },
    audit = 'camera.still.kept',
    subjectType = 'footage',
    auditDetail = function(input, result) return { number = result.number, mediaRef = input.mediaRef } end,
    handler = function(session, input)
        local row = repo.byId(input.requestId, session.agencyId)
        if not row or row.requestedBy ~= session.discordId or row.stillRef then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { requestId = 'unknown' })
        end

        local api = FredPD.Modules.mediaApi
        local ok, refusal = api.commit(session, input.mediaRef, 'footage_still', row.id)
        if not ok then return refusal end

        if (repo.setStill(row.id, session.agencyId, input.mediaRef, session.discordId) or 0) == 0 then
            api.uncommit(session, input.mediaRef)
            return route.refuse(FredPD.ErrorCode.CONFLICT, { requestId = 'still_taken' })
        end

        return { id = row.id, number = row.number }
    end,
})
