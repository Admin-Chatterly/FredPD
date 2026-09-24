--- Client-side helpers.
---
--- The client sends intent and renders answers. It decides nothing: every call
--- here reaches a route that re-checks the session, the permission and the
--- context on the server (invariants 1 and 3).

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local Client = {}

--- Calls a route and returns its envelope.
---
--- Always returns a table, so callers only branch on `ok` and never have to
--- guard against nil from a timed-out callback.
--- @return table { ok = boolean, data = any, err = string|nil }
function Client.call(name, data)
    local response = lib.callback.await('fredpd:' .. name, false, data or {})

    if type(response) ~= 'table' then
        return { ok = false, err = FredPD.ErrorCode.INTERNAL }
    end

    return response
end

--- Shows a route failure to the player, translated.
---
--- Every error code has an `error.<code>` key, and `pnpm i18n:check` keeps it
--- that way, so this can never render a blank notification.
local CONTEXT_CONDITIONS <const> = { onDuty = true, accessPoint = true, inAgencyVehicle = true }

function Client.showError(response)
    local key = 'error.' .. (response.err or 'internal')

    -- A context refusal names the condition that failed; say which one
    -- rather than listing every condition a route could have.
    local condition = type(response.fields) == 'table' and response.fields._context
    if response.err == FredPD.ErrorCode.CONTEXT and CONTEXT_CONDITIONS[condition] then
        key = 'error.contextNeeds.' .. condition
    end

    lib.notify({
        title = FredPD.t('app.name'),
        description = FredPD.t(key),
        type = 'error',
    })
end

--- Shows a translated success notification.
function Client.notify(localeKey, params)
    lib.notify({
        title = FredPD.t('app.name'),
        description = FredPD.t(localeKey, params),
        type = 'success',
    })
end

FredPD.Client.core = Client
