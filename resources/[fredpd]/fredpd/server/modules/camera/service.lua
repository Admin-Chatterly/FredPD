--- Cameras (spec 7.19): the pure part.
---
--- What a footage request must say, whether one lets its requester look now,
--- and where a body-worn or dash camera sits on the officer or car it is on.
--- No natives, no database (`spec/camera_spec.lua`).

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Camera = {}

local SOURCES <const> = { cctv = true, bodycam = true, dashcam = true }

function Camera.isSource(value) return SOURCES[value] == true end

--- The terminals a camera is watched from.
Camera.TERMINALS = { station_terminal = true, dispatch_console = true }

--- A request as it will be kept, or a refusal.
---
--- The window is what the requester may look during: it may start a little
--- in the past (a request written after the event it is for) and runs at most
--- `maxHours`, ending no more than a week ahead.
---
--- @param input table { source, cameraId, officerId, windowFrom, windowTo, reason }
--- @param now number epoch seconds
--- @param maxHours number|nil
--- @return table|nil request, table|nil fields
function Camera.validateRequest(input, now, maxHours)
    if not Camera.isSource(input.source) then return nil, { source = 'unknown' } end

    if input.source == 'cctv' then
        if not input.cameraId then return nil, { cameraId = 'required' } end
    elseif not input.officerId then
        return nil, { officerId = 'required' }
    end

    local from, to = tonumber(input.windowFrom), tonumber(input.windowTo)
    if not from or not to or to <= from then return nil, { windowTo = 'out_of_range' } end
    if from < now - 3600 or to > now + 7 * 86400 then return nil, { windowFrom = 'out_of_range' } end
    if to - from > (tonumber(maxHours) or 12) * 3600 then return nil, { windowTo = 'too_long' } end

    local reason = type(input.reason) == 'string' and input.reason:match('^%s*(.-)%s*$') or ''
    if utf8.len(reason) == nil or utf8.len(reason) < 5 then return nil, { reason = 'too_short' } end

    return {
        source = input.source,
        cameraId = input.source == 'cctv' and input.cameraId or nil,
        officerId = input.source ~= 'cctv' and input.officerId or nil,
        windowFrom = math.floor(from),
        windowTo = math.floor(to),
        reason = reason,
    }
end

--- Does this request let its requester look through this camera now?
function Camera.covers(request, source, cameraId, officerId, now)
    if type(request) ~= 'table' or request.status ~= 'approved' then return false end
    if request.source ~= source then return false end
    if source == 'cctv' and request.cameraId ~= cameraId then return false end
    if source ~= 'cctv' and request.officerId ~= officerId then return false end

    return now >= request.windowFrom and now <= request.windowTo
end

--- Appendix D: `F{YY}-{#####}`.
function Camera.numberPrefix(year)
    return ('F%02d-'):format(year % 100), 5
end

--- Where a camera on a person or a car looks from: a body-worn camera on the
--- chest, a dash camera behind the windscreen, both facing the way the
--- wearer or the car faces. GTA headings are degrees, anticlockwise from
--- north, so forward is (-sin, cos).
---
--- @return table { x, y, z, heading }
function Camera.mount(source, x, y, z, heading)
    local rad = math.rad(heading or 0)
    local fx, fy = -math.sin(rad), math.cos(rad)

    if source == 'dashcam' then
        return { x = x + fx * 0.6, y = y + fy * 0.6, z = z + 0.65, heading = heading }
    end

    return { x = x + fx * 0.3, y = y + fy * 0.3, z = z + 0.45, heading = heading }
end

FredPD.Modules.camera = Camera

return Camera
