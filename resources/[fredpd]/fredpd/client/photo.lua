--- Taking a photograph for a record (spec 7.3, 7.9; ADR-019).
---
--- The NUI does the upload; this file only does what a browser cannot: find
--- who is standing at the terminal, point a camera at their face, and take the
--- picture. It sends nothing to the server itself -- the begin and commit
--- steps are routes the NUI calls, and the server decides both.

-- luacheck: read globals CreateCamWithParams PointCamAtCoord SetCamActive RenderScriptCams DestroyCam
-- luacheck: read globals GetPedBoneCoords GetEntityForwardVector GetPlayerFromServerId DisplayRadar
-- luacheck: read globals IsRadarHidden

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local screenshot = FredPD.Client.screenshot

--- How close somebody must be to have their mugshot taken, in metres. The
--- server checks its own range again; this is only who to ask about.
local NEAREST_RADIUS <const> = 3.0

--- The head bone (SKEL_Head).
local HEAD_BONE <const> = 31086

local function nearestPlayerId()
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local best, bestDistance = nil, NEAREST_RADIUS

    for _, playerId in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(playerId)

        if ped ~= myPed and DoesEntityExist(ped) then
            local distance = #(myCoords - GetEntityCoords(ped))
            if distance <= bestDistance then best, bestDistance = playerId, distance end
        end
    end

    return best and GetPlayerServerId(best) or nil
end

--- Hides or shows the MDT for the moment the picture is taken, without
--- closing it: the NUI keeps every form as it was.
local function setHidden(hidden)
    SendNUIMessage({ type = 'fredpd:photo', hidden = hidden })
end

--- A camera in front of a player's face, for a mugshot. Returns a function
--- that puts the view back.
local function faceCamera(serverId)
    local player = GetPlayerFromServerId(serverId)
    if not player or player == -1 then return nil end

    local ped = GetPlayerPed(player)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    local head = GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
    local forward = GetEntityForwardVector(ped)
    local at = head + forward * 0.9

    local cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', at.x, at.y, at.z + 0.02, 0.0, 0.0, 0.0, 38.0, false, 0)
    PointCamAtCoord(cam, head.x, head.y, head.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    return function()
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)
    end
end

RegisterNUICallback('fredpd:photoNearest', function(_, cb)
    local targetId = nearestPlayerId()
    if not targetId then
        cb({ ok = false, err = FredPD.ErrorCode.NOT_FOUND, fields = { targetId = 'unreachable' } })
        return
    end

    cb({ ok = true, data = { targetId = targetId } })
end)

--- `{ targetId? }`: with a target, a mugshot of that player's face; without,
--- what the officer is looking at.
RegisterNUICallback('fredpd:photoCapture', function(data, cb)
    if not screenshot.available() then
        cb({ ok = false, err = FredPD.ErrorCode.CONFLICT, fields = { _input = 'no_screenshot' } })
        return
    end

    local targetId = type(data) == 'table' and tonumber(data.targetId) or nil

    setHidden(true)
    local radarWasHidden = IsRadarHidden()
    DisplayRadar(false)

    local restore = targetId and faceCamera(targetId) or nil
    if targetId and not restore then
        DisplayRadar(not radarWasHidden)
        setHidden(false)
        cb({ ok = false, err = FredPD.ErrorCode.NOT_FOUND, fields = { targetId = 'unreachable' } })
        return
    end

    -- A few frames for the NUI to hide and the camera to settle. Taken
    -- inside a pcall: whatever the screenshot resource does, the view and
    -- the MDT come back.
    Wait(250)
    local ok, image = pcall(screenshot.capture)
    if not ok then image = nil end

    if restore then restore() end
    DisplayRadar(not radarWasHidden)
    setHidden(false)

    if not image then
        cb({ ok = false, err = FredPD.ErrorCode.CONFLICT, fields = { _input = 'no_screenshot' } })
        return
    end

    cb({ ok = true, data = { image = image } })
end)
