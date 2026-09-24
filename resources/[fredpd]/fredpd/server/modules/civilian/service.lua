--- Civilian mode (spec 7.29): the pure part.
---
--- What a member of the public may hand in at a front desk, and what they
--- are shown of their own records. No natives, no database
--- (`spec/civilian_spec.lua`).

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Civilian = {}

local KINDS <const> = { stolen_property = true, complaint = true }

function Civilian.isKind(value) return KINDS[value] == true end

--- How far back an occurrence may be dated, in days. Further back than this is
--- a typo, not a report.
local OLDEST_DAYS <const> = 365

--- Plain text as a report keeps it: control characters out (a newline and a
--- tab stay), trimmed, bounded by characters rather than bytes.
local function clean(value, max)
    if type(value) ~= 'string' then return nil end

    local text = value:gsub('\r\n', '\n'):gsub('[\0-\8\11\12\14-\31\127]', ''):match('^%s*(.-)%s*$')
    if text == '' then return nil end

    local length = utf8.len(text)
    if not length then return nil end
    if length > max then text = text:sub(1, (utf8.offset(text, max + 1) or (#text + 1)) - 1) end

    return text
end

--- A report as handed in, checked and cleaned, or a refusal.
---
--- @param input table { kind, description, place, property, occurredAt }
--- @param now number epoch seconds
--- @return table|nil report, table|nil fields
function Civilian.validateReport(input, now)
    if not Civilian.isKind(input.kind) then return nil, { kind = 'unknown' } end

    local description = clean(input.description, 2000)
    if not description or utf8.len(description) < 10 then return nil, { description = 'too_short' } end

    local occurredAt = nil
    if input.occurredAt ~= nil then
        occurredAt = math.floor(tonumber(input.occurredAt) or 0)
        if occurredAt > now + 300 or occurredAt < now - OLDEST_DAYS * 86400 then
            return nil, { occurredAt = 'out_of_range' }
        end
    end

    return {
        kind = input.kind,
        description = description,
        place = clean(input.place, 191),
        -- What was taken belongs to a theft; a complaint has none.
        property = input.kind == 'stolen_property' and clean(input.property, 500) or nil,
        occurredAt = occurredAt,
    }
end

--- Appendix D: `{AGENCY}-M{YY}-{######}`.
function Civilian.numberPrefix(shortName, year)
    return ('%s-M%02d-'):format(tostring(shortName):upper(), year % 100), 6
end

--- The permission that reads a kind of report in the inbox. A complaint is
--- about the police, so internal affairs reads it, not the officers it names.
function Civilian.readPermission(kind)
    return kind == 'complaint' and 'ia.case.view' or 'public.report.view'
end

--- The permission that closes one.
function Civilian.handlePermission(kind)
    return kind == 'complaint' and 'ia.case.manage' or 'public.report.handle'
end

FredPD.Modules.civilian = Civilian

return Civilian
