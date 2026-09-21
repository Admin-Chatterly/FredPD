--- The signed link to the gateway (spec 3.7). Natives from here down.
---
--- Both directions sign `<timestamp>.<body>` with the shared secret --
--- `gateway/src/hmac.ts`'s own docstring states the identical rule, and this
--- file is the Lua side of that one contract. The timestamp sits inside the
--- signed material, so it cannot be moved to a fresh window without
--- invalidating the signature, which is what makes the gateway's replay
--- check (`replayWindowSeconds`, spec 3.7) meaningful.
---
--- Loopback only: `config.url` is expected to be `http://127.0.0.1:<port>`,
--- never a public address (gateway/CLAUDE.md's own rule, mirrored here).

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}
FredPD.Bridge.gateway = FredPD.Bridge.gateway or {}

local hmac = FredPD.Bridge.gateway.hmac

local Client = {}

local SIGNATURE_HEADER <const> = 'x-fredpd-signature'
local TIMESTAMP_HEADER <const> = 'x-fredpd-timestamp'

--- Milliseconds to wait for a response before treating the gateway as
--- unreachable. The gateway is loopback and normally answers in single-digit
--- milliseconds; this is generous headroom for PDF rendering, which launches
--- a real Chromium (spec 3.3) and is the slowest thing gateway does.
local TIMEOUT_MS <const> = 20000

local function config()
    return FredPD.Config.server.gateway
end

function Client.isEnabled()
    local cfg = config()
    return cfg ~= nil and cfg.enabled == true and type(cfg.secret) == 'string' and cfg.secret ~= ''
end

--- Signs and sends one request to the gateway, and resolves to its response.
---
--- A network failure, a timeout, or a non-2xx status all resolve the same
--- shape (`ok = false`) rather than raising: every caller already has to
--- handle "the gateway said no", and a Lua error here would just be that same
--- case reaching the caller through a different door.
---
--- @param method string 'GET' | 'POST'
--- @param path string starts with '/', e.g. '/fx/media/upload-token'
--- @param bodyTable table|nil encoded as JSON; nil sends an empty body
--- @return table result `{ ok = true, status, body }` or `{ ok = false, reason }`
function Client.request(method, path, bodyTable)
    if not Client.isEnabled() then
        return { ok = false, reason = 'disabled' }
    end

    local cfg = config()
    local body = bodyTable and json.encode(bodyTable) or ''
    local timestamp = os.time()
    local signature = hmac.sha256Hex(cfg.secret, tostring(timestamp) .. '.' .. body)

    local request = promise.new()
    local settled = false

    local function settle(result)
        if settled then return end
        settled = true
        request:resolve(result)
    end

    PerformHttpRequest(cfg.url .. path, function(status, responseBody)
        if status == 0 or status == nil then
            settle({ ok = false, reason = 'unreachable' })
            return
        end

        local decoded = nil
        if responseBody and responseBody ~= '' then
            local ok, parsed = pcall(json.decode, responseBody)
            if ok then decoded = parsed end
        end

        settle({ ok = status >= 200 and status < 300, status = status, body = decoded })
    end, method, body, {
        ['Content-Type'] = 'application/json',
        [SIGNATURE_HEADER] = signature,
        [TIMESTAMP_HEADER] = tostring(timestamp),
    })

    SetTimeout(TIMEOUT_MS, function() settle({ ok = false, reason = 'timeout' }) end)

    return Citizen.Await(request)
end

FredPD.Bridge.gateway.client = Client

return Client
