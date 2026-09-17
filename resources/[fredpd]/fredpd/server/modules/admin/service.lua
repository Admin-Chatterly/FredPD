--- Administration logic (spec 7.30, 16).
---
--- No natives, so busted can test it: the setup code and the statements that
--- first-run setup writes are exactly the parts worth proving, and both would
--- otherwise only be exercised by installing a server.

FredPD = FredPD or {}
FredPD.Modules = FredPD.Modules or {}

local Admin = {}

--- No 0/O and no 1/I: the code is read off a server console and typed into a
--- chat box, and those are the pairs people get wrong.
local ALPHABET <const> = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'

Admin.SETUP_CODE_LENGTH = 6

--- A one-time setup code.
--- @param random function|nil defaults to math.random; injectable for tests
function Admin.generateSetupCode(random)
    random = random or math.random

    local code = {}

    for index = 1, Admin.SETUP_CODE_LENGTH do
        local at = random(#ALPHABET)
        code[index] = ALPHABET:sub(at, at)
    end

    return table.concat(code)
end

--- Does a code typed in game match the one the console printed?
---
--- Case-insensitive, because the alphabet has no lower-case forms and nobody
--- should be locked out by their shift key. Nil or empty never matches -- in
--- particular a nil `expected`, which is the state after setup has already run.
function Admin.codeMatches(given, expected)
    if type(given) ~= 'string' or type(expected) ~= 'string' then return false end
    if given == '' or expected == '' then return false end

    return given:upper() == expected:upper()
end

--- The statements first-run setup writes: the agency, the first officer, and
--- that officer's Discord roles mapped to `admin`.
---
--- Returns statements rather than running them, so what setup would write can
--- be asserted on without a database.
---
--- Every role the officer holds is mapped, not only their highest: FredPD has
--- no view of Discord's role hierarchy, so mapping them all is what makes setup
--- work whatever their roles happen to be called.
---
--- @param agency table { id, name, shortName, accentColor }
--- @param officer table { discordId, callsign, name }
--- @param roleIds table Discord role ids the officer holds
--- @return table list of { query, values }
function Admin.bootstrapStatements(agency, officer, roleIds)
    local statements = {
        {
            query = [[INSERT INTO fpd_agencies (id, name, short_name, accent_color)
                      VALUES (?, ?, ?, ?)
                      ON DUPLICATE KEY UPDATE name = VALUES(name), short_name = VALUES(short_name)]],
            values = { agency.id, agency.name, agency.shortName, agency.accentColor or '#1b4f9c' },
        },
        {
            query = [[INSERT INTO fpd_officers (discord_id, agency_id, callsign, name)
                      VALUES (?, ?, ?, ?)]],
            values = { officer.discordId, agency.id, officer.callsign, officer.name },
        },
    }

    for index = 1, #roleIds do
        statements[#statements + 1] = {
            query = [[INSERT IGNORE INTO fpd_role_map
                          (discord_role_id, discord_role_name, group_key, agency_id, created_by)
                      VALUES (?, NULL, 'admin', ?, ?)]],
            values = { roleIds[index], agency.id, officer.discordId },
        }
    end

    return statements
end

FredPD.Modules.admin = Admin
