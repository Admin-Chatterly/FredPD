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

--- 12 characters of a 32-character alphabet is 60 bits.
---
--- Not 6. FiveM's Lua has no cryptographic random source, so this comes from
--- `math.random`, whose state is seeded from the clock and is not built to
--- resist somebody who knows roughly when the resource started -- which anybody
--- watching the server restart does. Guessing rate is already bounded hard by
--- the rate limit on the event, so the length is there to defeat *seed
--- prediction*, where an attacker reproduces the generator's state rather than
--- guessing its output. At 60 bits, reproducing the state has to be exact.
Admin.SETUP_CODE_LENGTH = 12

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
--- `roleIds` is what the operator explicitly named -- normally exactly one. It
--- used to be every role the officer held, which was a quiet catastrophe: an
--- operator who also holds `@Member`, like everyone on the server, would map
--- `@Member` to `admin` and hand the whole community `admin.permissions.edit`
--- and `admin.audit.view`. Setup now makes the operator name the role.
---
--- @param agency table { id, name, shortName, accentColor }
--- @param officer table { discordId, identifier, callsign, name }
--- @param roleIds table Discord role ids to map to `admin`
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
            -- `identifier` binds the ESX character (spec 4.1). Left NULL,
            -- `Session.open` skips the binding check entirely, and the one
            -- officer who holds `admin` could open FredPD from a criminal alt --
            -- which is the exact thing that binding exists to prevent.
            query = [[INSERT INTO fpd_officers (discord_id, agency_id, identifier, callsign, name)
                      VALUES (?, ?, ?, ?, ?)]],
            values = {
                officer.discordId,
                agency.id,
                officer.identifier,
                officer.callsign,
                officer.name,
            },
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
