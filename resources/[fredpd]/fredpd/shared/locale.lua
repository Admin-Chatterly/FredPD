--- Locale loader (spec 5.1).
---
--- Loads `locales/<lang>.json`, falls back to `en` for any missing key, and
--- lets a server override individual keys from `locales/custom/<lang>.json`
--- without touching the shipped files. The custom folder is git-ignored so a
--- server's own wording survives updates.
---
--- Invariant 6: every user-facing string in Lua and in the NUI comes from here.

local FALLBACK_LANG <const> = 'en'

local translations = {}
local fallback = {}

--- Flattens `{ a = { b = 'x' } }` into `{ ['a.b'] = 'x' }` so lookups are a
--- single table index and keys read the same in Lua, JSON and the NUI.
local function flatten(source, prefix, out)
    for key, value in pairs(source) do
        local path = prefix and (prefix .. '.' .. key) or key

        if type(value) == 'table' then
            flatten(value, path, out)
        else
            out[path] = tostring(value)
        end
    end

    return out
end

local function loadFile(path)
    local raw = LoadResourceFile(FredPD.resource, path)
    if not raw then return nil end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        print(('[fredpd] locale file %s is not valid JSON, ignoring it'):format(path))
        return nil
    end

    return flatten(decoded, nil, {})
end

--- Loads `lang`, its fallback, and any custom overlay on top.
--- @param lang string
function FredPD.loadLocale(lang)
    fallback = loadFile(('locales/%s.json'):format(FALLBACK_LANG)) or {}
    translations = lang == FALLBACK_LANG and fallback or (loadFile(('locales/%s.json'):format(lang)) or {})

    local overlay = loadFile(('locales/custom/%s.json'):format(lang))
    if overlay then
        for key, value in pairs(overlay) do
            translations[key] = value
        end
    end

    FredPD.lang = lang
end

--- Translates `key`, substituting `{name}` placeholders from `params`.
--- An unknown key returns the key itself, which makes a missing translation
--- obvious in-game instead of rendering an empty string. `pnpm i18n:check`
--- keeps that from reaching a pull request.
--- @param key string
--- @param params table|nil
--- @return string
function FredPD.t(key, params)
    local value = translations[key] or fallback[key]
    if not value then return key end

    if params then
        value = value:gsub('{(%w+)}', function(name)
            local replacement = params[name]
            return replacement ~= nil and tostring(replacement) or ('{' .. name .. '}')
        end)
    end

    return value
end

FredPD.loadLocale(FredPD.Config.shared.locale or FALLBACK_LANG)
