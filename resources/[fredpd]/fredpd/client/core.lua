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
function Client.showError(response)
    lib.notify({
        title = FredPD.t('app.name'),
        description = FredPD.t('error.' .. (response.err or 'internal')),
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
