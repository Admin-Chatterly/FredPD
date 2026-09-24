--- The screenshot bridge (spec 3.8, ADR-019): the only place FredPD names
--- screenshot-basic.
---
--- A server without it still runs FredPD: taking a photograph is refused with
--- a sentence saying why, and the records keep whatever photographs they have.

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local RESOURCE <const> = 'screenshot-basic'

local Screenshot = {}

function Screenshot.available()
    return GetResourceState(RESOURCE) == 'started'
end

--- What the game is drawing right now, as a JPEG data URI, or nil. Blocks
--- the calling thread until screenshot-basic answers, at most five seconds.
---
--- @return string|nil
function Screenshot.capture()
    if not Screenshot.available() then return nil end

    local result = promise.new()

    exports[RESOURCE]:requestScreenshot({ encoding = 'jpg', quality = 0.85 }, function(data)
        result:resolve(data)
    end)

    SetTimeout(5000, function()
        if result.state == 0 then result:resolve(nil) end
    end)

    local data = Citizen.Await(result)
    if type(data) ~= 'string' or not data:find('^data:image/') then return nil end

    return data
end

CreateThread(function()
    Wait(2000)

    if not Screenshot.available() then
        print('[fredpd] screenshot-basic is not started: photographs and mugshots cannot be taken.')
    end
end)

FredPD.Client.screenshot = Screenshot
