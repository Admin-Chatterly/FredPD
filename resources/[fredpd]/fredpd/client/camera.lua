--- Live view through a camera (spec 7.19).
---
--- The NUI starts a view with `camera.view.start` (the server decides whether
--- this officer may look, and through what) and hands the answer here. This
--- file only does what a browser cannot: put a scripted camera where the
--- server said, hide the MDT without closing it, and give the officer keys to
--- look around, keep a still, and leave. A body-worn or dash camera moves with
--- the frames the server sends this viewer and nobody else.

-- luacheck: read globals CreateCam SetCamCoord SetCamRot SetCamActive RenderScriptCams DestroyCam
-- luacheck: read globals SetFocusPosAndVel ClearFocus HideHudAndRadarThisFrame DisableAllControlActions
-- luacheck: read globals EnableControlAction IsDisabledControlJustPressed IsDisabledControlPressed

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local screenshot = FredPD.Client.screenshot

--- Control ids: arrows look around, E keeps a still, Backspace leaves.
local KEY_UP <const>, KEY_DOWN <const>, KEY_LEFT <const>, KEY_RIGHT <const> = 172, 173, 174, 175
local KEY_STILL <const> = 38
local KEY_LEAVE <const> = 177

--- How far a fixed camera turns from where it points, in degrees.
local YAW_LIMIT <const> = 60.0
local PITCH_MIN <const>, PITCH_MAX <const> = -60.0, 15.0

local view = nil

local function setHidden(hidden)
    SendNUIMessage({ type = 'fredpd:photo', hidden = hidden })
end

local function overlay()
    if not view then return end
    local key = view.requestId and 'camera.overlay.withStill' or 'camera.overlay.plain'
    lib.showTextUI(FredPD.t(key, { label = view.label }))
end

local function place(x, y, z, heading)
    if not view then return end
    view.base = { x = x, y = y, z = z, heading = heading }
    SetCamCoord(view.cam, x, y, z)
    SetCamRot(view.cam, view.pitch, 0.0, heading + view.yaw, 2)
    SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)
end

--- Puts everything back as it was: the game camera, the MDT, the focus.
local function close(notice)
    if not view then return end
    local current = view
    view = nil

    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(current.cam, false)
    ClearFocus()
    lib.hideTextUI()
    setHidden(false)
    SetNuiFocus(true, true)

    if notice then
        lib.notify({ title = FredPD.t('app.name'), description = FredPD.t(notice), type = 'inform' })
    end
end

local function keepStill()
    if not view or not view.requestId or view.stillTaken then return end
    if not screenshot.available() then
        lib.notify({ title = FredPD.t('app.name'), description = FredPD.t('camera.still.unavailable'), type = 'error' })
        return
    end

    lib.hideTextUI()
    Wait(120)
    local ok, image = pcall(screenshot.capture)
    overlay()

    if not ok or not image then
        lib.notify({ title = FredPD.t('app.name'), description = FredPD.t('camera.still.failed'), type = 'error' })
        return
    end

    view.stillTaken = true
    -- The NUI, hidden but not closed, does the upload and the commit: the
    -- server decides both (`camera.still.begin` / `.commit`).
    SendNUIMessage({ type = 'fredpd:cameraStill', requestId = view.requestId, image = image })
    lib.notify({ title = FredPD.t('app.name'), description = FredPD.t('camera.still.sent'), type = 'inform' })
end

local function controls()
    CreateThread(function()
        while view do
            HideHudAndRadarThisFrame()
            DisableAllControlActions(0)
            EnableControlAction(0, 249, true) -- push to talk stays

            if IsDisabledControlJustPressed(0, KEY_LEAVE) then
                FredPD.Client.core.call('camera.view.stop', {})
                close()
                return
            end

            if IsDisabledControlJustPressed(0, KEY_STILL) then keepStill() end

            local turned = false
            if IsDisabledControlPressed(0, KEY_LEFT) then view.yaw = math.min(YAW_LIMIT, view.yaw + 0.6) turned = true end
            if IsDisabledControlPressed(0, KEY_RIGHT) then view.yaw = math.max(-YAW_LIMIT, view.yaw - 0.6) turned = true end
            if IsDisabledControlPressed(0, KEY_UP) then view.pitch = math.min(PITCH_MAX, view.pitch + 0.4) turned = true end
            if IsDisabledControlPressed(0, KEY_DOWN) then view.pitch = math.max(PITCH_MIN, view.pitch - 0.4) turned = true end

            if turned and view.base then
                SetCamRot(view.cam, view.pitch, 0.0, view.base.heading + view.yaw, 2)
            end

            Wait(0)
        end
    end)
end

--- `{ source, label, requestId?, position? }`, the server's own answer.
RegisterNUICallback('fredpd:cameraOpen', function(data, cb)
    if type(data) ~= 'table' or view then
        cb({ ok = false, err = FredPD.ErrorCode.CONFLICT })
        return
    end

    view = {
        cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true),
        label = tostring(data.label or ''),
        requestId = tonumber(data.requestId),
        yaw = 0.0,
        pitch = data.source == 'cctv' and -20.0 or -5.0,
    }

    SetNuiFocus(false, false)
    setHidden(true)

    local position = data.position
    if type(position) == 'table' then
        place(tonumber(position.x) or 0.0, tonumber(position.y) or 0.0, tonumber(position.z) or 0.0,
            tonumber(position.heading) or 0.0)
    end

    SetCamActive(view.cam, true)
    RenderScriptCams(true, false, 0, true, true)
    overlay()
    controls()

    cb({ ok = true, data = {} })
end)

--- Where a body-worn or dash camera is now, from the server, to this viewer.
RegisterNetEvent('fredpd:cameraFrame', function(frame)
    if not view or type(frame) ~= 'table' then return end
    place(tonumber(frame.x) or 0.0, tonumber(frame.y) or 0.0, tonumber(frame.z) or 0.0, tonumber(frame.heading) or 0.0)
end)

--- The server ended the view: the camera stopped being one, or the viewer
--- left the terminal.
RegisterNetEvent('fredpd:cameraEnded', function(payload)
    if not view then return end
    local reason = type(payload) == 'table' and payload.reason or 'stopped'
    close(reason ~= 'stopped' and reason ~= 'replaced' and ('camera.ended.' .. reason) or nil)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and view then close() end
end)
