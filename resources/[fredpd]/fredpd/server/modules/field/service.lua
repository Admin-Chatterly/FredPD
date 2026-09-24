--- Field actions: what an officer does to a person or a vehicle in front of
--- them, from the world rather than the MDT (spec 7.2, 7.4).
---
--- Pure: no natives, no database, so busted exercises it outside FXServer
--- (`spec/field_spec.lua`). The routes resolve who and what the officer is
--- looking at on the server -- from a server id or a network id, never from a
--- name or a plate the client typed -- and this file holds the rules they
--- apply to what they find.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Field = {}

--- How close an officer must stand to check somebody's ID or read a plate,
--- in metres. Arm's length and a bit: a check from across the street is a
--- check the officer could not have made.
Field.DEFAULT_RANGE = 5.0

--- Are two positions within `range` metres of each other?
--- @param a table|vector3|nil { x, y, z }
--- @param b table|vector3|nil
--- @param range number
function Field.withinRange(a, b, range)
    if not a or not b then return false end

    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return (dx * dx + dy * dy + dz * dz) <= range * range
end

--- A date of birth as `fpd_persons.date_of_birth` stores one, or nil.
---
--- ESX forks store it as whatever their identity resource was configured to
--- write: `YYYY-MM-DD`, or `DD/MM/YYYY` (esx_identity's default), sometimes
--- with dots or dashes. Anything that does not come out as a real calendar
--- date is dropped rather than guessed at: a person with no date of birth is
--- honest, a person with the wrong one is a false match waiting to happen.
function Field.normalizeDob(value)
    if type(value) ~= 'string' then return nil end

    local year, month, day = value:match('^%s*(%d%d%d%d)[%-/%.](%d%d?)[%-/%.](%d%d?)%s*$')
    if not year then
        day, month, year = value:match('^%s*(%d%d?)[%-/%.](%d%d?)[%-/%.](%d%d%d%d)%s*$')
    end
    if not year then return nil end

    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if month < 1 or month > 12 or day < 1 or day > 31 or year < 1900 or year > 2100 then return nil end

    local lengths = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if day > lengths[month] then return nil end
    if month == 2 and day == 29 and not (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
        return nil
    end

    return ('%04d-%02d-%02d'):format(year, month, day)
end

local SEXES <const> = {
    m = 'male', male = 'male', man = 'male',
    f = 'female', female = 'female', kvinna = 'female', w = 'female',
}

--- `ck_fpd_persons_sex` accepts four words; ESX stores one letter.
function Field.normalizeSex(value)
    if type(value) ~= 'string' then return nil end

    return SEXES[value:lower()]
end

--- The person fields a character's own identity gives, for registering
--- somebody the agency has never met. Only what the ID card says: name, date
--- of birth, sex, and the identifier that ties the record to this character.
---
--- @param identity table { identifier, firstName, lastName, dateOfBirth, sex }
--- @return table|nil fields, nil when there is not even a name to register
function Field.personFields(identity)
    if type(identity) ~= 'table' or type(identity.identifier) ~= 'string' or identity.identifier == '' then
        return nil
    end

    local first = type(identity.firstName) == 'string' and identity.firstName:match('^%s*(.-)%s*$') or ''
    local last = type(identity.lastName) == 'string' and identity.lastName:match('^%s*(.-)%s*$') or ''
    if first == '' and last == '' then return nil end

    return {
        identifier = identity.identifier,
        firstName = first ~= '' and first:sub(1, 64) or nil,
        lastName = last ~= '' and last:sub(1, 64) or nil,
        dateOfBirth = Field.normalizeDob(identity.dateOfBirth),
        sex = Field.normalizeSex(identity.sex),
    }
end

FredPD.Modules.field = Field

return Field
