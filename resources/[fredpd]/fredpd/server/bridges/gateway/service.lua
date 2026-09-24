--- The gateway bridge's public API (spec 3.7): the three calls the gateway
--- already serves -- a media upload token, a media download token, and PDF
--- rendering -- plus the outbox that retries a call the gateway did not
--- answer.
---
--- Off by default with the rest of the gateway (ADR-010): every function
--- here checks `client.isEnabled()` first and answers `ok = false, reason =
--- 'disabled'` rather than erroring, so a server that has not deployed the
--- gateway is simply a server where these calls always politely decline --
--- exactly the posture `client.lua` already takes one layer down.
---
--- **Why an outbox.** A synchronous call (a token request an officer is
--- waiting on) that fails just fails -- the officer sees a refusal and tries
--- again, the same as any other route. A PDF render is different: it can be
--- launched from a workflow (an approval, a disposition) where nobody is
--- staring at a spinner, and a gateway that is mid-restart when it is called
--- must not silently lose the request. `Gateway.renderPdf` writes to the
--- outbox first and removes the row only once the gateway has actually
--- confirmed the render; `Gateway.retryOutbox` (run on a timer from
--- `Gateway.start`, spec 13.3's retention job is a separate concern and does
--- not touch this table) resends whatever is still there.

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}
FredPD.Bridge.gateway = FredPD.Bridge.gateway or {}

local client = FredPD.Bridge.gateway.client

local Gateway = {}

--- Rows older than this are given up on rather than retried forever -- a
--- render request from three days ago is almost certainly for a session that
--- has moved on, and an outbox that never shrinks is a slow leak.
local MAX_ATTEMPT_AGE_SECONDS <const> = 24 * 3600

local MAX_ATTEMPTS <const> = 10

function Gateway.isEnabled()
    return client.isEnabled()
end

-- -----------------------------------------------------------------------------
-- The three calls
-- -----------------------------------------------------------------------------

--- @param kind string|nil 'image' for a photograph the gateway re-encodes
---   and refuses when it is not one
--- @return boolean ok
--- @return table result `{ mediaRef, uploadUrl, expiresAt }` or `{ reason }`
function Gateway.requestUploadToken(kind)
    local result = client.request('POST', '/fx/media/upload-token', { kind = kind })

    if not result.ok then return false, { reason = result.reason or 'gateway_error' } end

    return true, result.body
end

--- @param mediaRef string
--- @return boolean ok
--- @return table result `{ mediaRef, downloadUrl, expiresAt }` or `{ reason }`
function Gateway.requestDownloadToken(mediaRef)
    local result = client.request('POST', '/fx/media/download-token', { mediaRef = mediaRef })

    if not result.ok then return false, { reason = result.reason or 'gateway_error' } end

    return true, result.body
end

--- Renders a document to PDF from the same editor JSON the NUI holds
--- (invariant 10 -- never HTML built from a template). Queues to the outbox
--- first; see the module header for why.
---
--- @param document table `{ title, fields, body, classification? }`
--- @return boolean ok
--- @return table result `{ mediaRef, downloadUrl, expiresAt, bytes }` or `{ reason }`
function Gateway.renderPdf(document)
    if not Gateway.isEnabled() then return false, { reason = 'disabled' } end

    local outboxId = FredPD.Repo.gatewayOutbox.enqueue('pdf.render', document)

    local result = client.request('POST', '/fx/pdf/render', document)

    if result.ok then
        FredPD.Repo.gatewayOutbox.remove(outboxId)
        return true, result.body
    end

    FredPD.Repo.gatewayOutbox.recordFailure(outboxId, result.reason or 'gateway_error')
    return false, { reason = result.reason or 'gateway_error', outboxId = outboxId }
end

-- -----------------------------------------------------------------------------
-- Download links, signed here (ADR-019)
-- -----------------------------------------------------------------------------

--- The download key, derived once: `deriveKey(secret, 'media-download')` in
--- the gateway's own `config.ts`, byte for byte.
local downloadKey, downloadKeyFor = nil, nil

local function keyFor(secret)
    if downloadKeyFor ~= secret then
        downloadKey = FredPD.Bridge.gateway.hmac.sha256Hex(secret, 'media-download')
        downloadKeyFor = secret
    end

    return downloadKey
end

--- A link the NUI can load a stored file from, for `mediaLinkSeconds`.
---
--- Signed here rather than asked of the gateway: a person record with six
--- photographs would otherwise cost six HTTP round trips on every open, and
--- the token is the same HMAC the gateway would have computed with the same
--- derived key (`media/tokens.ts`). The ref is always one this server stored
--- on a row; it is never taken from input.
---
--- @param mediaRef string
--- @param thumbnail boolean|nil the 320px WebP instead of the original
--- @param now number|nil epoch seconds, for tests
--- @return string|nil url, nil when the gateway is off
function Gateway.downloadUrl(mediaRef, thumbnail, now)
    if not Gateway.isEnabled() or type(mediaRef) ~= 'string' or not mediaRef:match('^media_[%x%-]+$') then
        return nil
    end

    local cfg = FredPD.Config.server.gateway
    local expiresAt = (now or os.time()) + (tonumber(cfg.mediaLinkSeconds) or 900)
    local token = FredPD.Bridge.gateway.hmac.sha256Hex(
        keyFor(cfg.secret), ('%s.download.%d'):format(mediaRef, expiresAt))

    local base = tostring(cfg.mediaUrl or cfg.url):gsub('/+$', '')

    return ('%s/media/%s%s?token=%s&expires=%d'):format(
        base, mediaRef, thumbnail and '/thumbnail' or '', token, expiresAt)
end

-- -----------------------------------------------------------------------------
-- The outbox
-- -----------------------------------------------------------------------------

--- One pass over whatever is still queued. Rows past `MAX_ATTEMPTS` or
--- `MAX_ATTEMPT_AGE_SECONDS` are dropped rather than retried -- see the
--- module header.
function Gateway.retryOutbox()
    if not Gateway.isEnabled() then return end

    local cutoff = os.time() - MAX_ATTEMPT_AGE_SECONDS
    local rows = FredPD.Repo.gatewayOutbox.pending(MAX_ATTEMPTS, cutoff)

    for index = 1, #rows do
        local row = rows[index]

        if row.kind == 'pdf.render' then
            local result = client.request('POST', '/fx/pdf/render', row.payload)

            if result.ok then
                FredPD.Repo.gatewayOutbox.remove(row.id)
            else
                FredPD.Repo.gatewayOutbox.recordFailure(row.id, result.reason or 'gateway_error')
            end
        end
    end

    FredPD.Repo.gatewayOutbox.dropStale(MAX_ATTEMPTS, cutoff)
end

--- Retries now, then every 5 minutes. Started from `main.lua` at boot, the
--- same shape `Discord.start` uses.
function Gateway.start()
    if not Gateway.isEnabled() then return end

    CreateThread(function()
        while true do
            Gateway.retryOutbox()
            Wait(5 * 60 * 1000)
        end
    end)
end

FredPD.Bridge.gateway.service = Gateway

return Gateway
