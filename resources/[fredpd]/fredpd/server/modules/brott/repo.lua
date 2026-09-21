--- Brottskatalogen SQL (spec 7.10). Parameterized only (invariant 8).
---
--- Two things about this repo differ from every other one in the suite, and
--- both follow from 7.10's "a change never alters past records":
---
---   * **There is no UPDATE.** An edit is `supersede` plus `create`, in one
---     transaction. A catalogue row that records point at is immutable, so the
---     usual allowlist-of-columns update helper would be the one way to break
---     the guarantee the whole table exists to provide.
---   * **There is no DELETE.** An offence that is no longer chargeable is
---     superseded, not removed: the anmälningar that cite it still have to
---     render, and a foreign key to a deleted row renders as nothing at all.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local SELECT <const> = [[
    SELECT id, agency_id AS agencyId, code, version,
           balk, kapitel, paragraf, stycke,
           label_key AS labelKey, description_key AS descriptionKey,
           grad, boter, fangelse_min_months AS fangelseMinMonths,
           fangelse_max_months AS fangelseMaxMonths,
           forsok, forberedelse, preskription_years AS preskriptionYears,
           superseded_at AS supersededAt, created_at AS createdAt
      FROM fpd_brott
]]

--- Turns MySQL's 0/1 into real booleans, so callers never compare against 0.
---
--- The same normalisation `placements/repo.lua` does, and for the same reason:
--- one comparison written as `row.boter == 1` somewhere downstream is a bug
--- that only shows up when the driver changes.
local function normalize(row)
    if not row then return nil end

    row.boter = row.boter == 1 or row.boter == true
    row.forsok = row.forsok == 1 or row.forsok == true
    row.forberedelse = row.forberedelse == 1 or row.forberedelse == true

    return row
end

--- Every current offence in an agency's catalogue.
---
--- Ordered the way brottsbalken is, so a charging list reads down the statute
--- rather than by insertion order: balk, then kapitel, then paragraf, then the
--- grad within the paragraf. `balk IS NULL` sorts last, which puts
--- agency-local codes after the statutory ones instead of ahead of them.
function Repo.current(agencyId)
    local rows = FredPD.Core.db.query(
        SELECT .. [[ WHERE agency_id = ? AND superseded_at IS NULL
                     ORDER BY balk IS NULL, balk, kapitel, paragraf, stycke, grad ]],
        { agencyId }
    )

    for index = 1, #rows do normalize(rows[index]) end
    return rows
end

--- One offence by its id, whatever version it is and whether or not it is
--- current.
---
--- A record cites a version by id and must keep rendering after that version is
--- superseded, so this deliberately does not filter on `superseded_at`.
function Repo.byId(id, agencyId)
    return normalize(FredPD.Core.db.single(
        SELECT .. ' WHERE id = ? AND agency_id = ?',
        { id, agencyId }
    ))
end

--- The current version of an offence, by code.
function Repo.byCode(code, agencyId)
    return normalize(FredPD.Core.db.single(
        SELECT .. ' WHERE agency_id = ? AND code = ? AND superseded_at IS NULL',
        { agencyId, code }
    ))
end

--- Several offences by id, in one statement.
---
--- For a record that cites a handful of offences: the alternative is one query
--- per charge, which is four round trips on an ordinary anmälan and shows up in
--- the route timings spec 12 sets budgets on.
---
--- The placeholder list is built from the *count* of ids, never from their
--- values, so this stays parameterized (invariant 8).
---
--- @param ids table list of numeric ids
--- @return table rows, in no particular order
function Repo.byIds(ids, agencyId)
    if type(ids) ~= 'table' or #ids == 0 then return {} end

    local placeholders = {}
    local values = {}

    for index = 1, #ids do
        placeholders[index] = '?'
        values[index] = ids[index]
    end

    values[#values + 1] = agencyId

    local rows = FredPD.Core.db.query(
        SELECT .. (' WHERE id IN (%s) AND agency_id = ?'):format(table.concat(placeholders, ', ')),
        values
    )

    for index = 1, #rows do normalize(rows[index]) end
    return rows
end

--- Every version of one offence, newest first. For an audit screen.
function Repo.versions(code, agencyId)
    local rows = FredPD.Core.db.query(
        SELECT .. ' WHERE agency_id = ? AND code = ? ORDER BY version DESC',
        { agencyId, code }
    )

    for index = 1, #rows do normalize(rows[index]) end
    return rows
end

--- The version number a new version of this code would take.
---
--- Read inside the same transaction as the insert that uses it -- see
--- `createVersion` -- never on its own.
local NEXT_VERSION_SQL <const> =
    [[(SELECT COALESCE(MAX(b.version), 0) + 1 FROM fpd_brott b
        WHERE b.agency_id = ? AND b.code = ?)]]

--- The columns an insert writes, in the order `insertValues` supplies them.
local INSERT_SQL <const> = [[
    INSERT INTO fpd_brott
        (agency_id, code, version, balk, kapitel, paragraf, stycke,
         label_key, description_key, grad, boter,
         fangelse_min_months, fangelse_max_months,
         forsok, forberedelse, preskription_years, created_by)
    VALUES (?, ?, ]] .. NEXT_VERSION_SQL .. [[, ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?,
            ?, ?, ?, ?)
]]

--- The values `INSERT_SQL` consumes, in order.
---
--- Note the two extra values in the middle: the version subquery takes the
--- agency and the code again. A nil anywhere in an oxmysql values list silently
--- shortens it and shifts every placeholder after it, so the booleans are
--- written as 0/1 rather than left to chance.
local function insertValues(input, agencyId, discordId)
    return {
        agencyId,
        input.code,
        agencyId, input.code,          -- NEXT_VERSION_SQL
        input.balk,
        input.kapitel,
        input.paragraf,
        input.stycke,
        input.labelKey,
        input.descriptionKey,
        input.grad,
        input.boter and 1 or 0,
        input.fangelseMinMonths or 0,
        input.fangelseMaxMonths,
        input.forsok and 1 or 0,
        input.forberedelse and 1 or 0,
        input.preskriptionYears,
        discordId,
    }
end

--- Adds the first version of an offence that is not in the catalogue yet.
---
--- @return number|nil the new row's id
function Repo.create(input, agencyId, discordId)
    return FredPD.Core.db.insert(INSERT_SQL, insertValues(input, agencyId, discordId))
end

--- Supersedes the current version of an offence and writes a new one.
---
--- Both statements in one transaction, because the unique index on
--- `current_marker` allows exactly one live version per code: between the
--- insert and the supersede there would be two, and whichever statement ran
--- second would be refused. Superseding first and inserting second is therefore
--- not a preference, it is the only order that commits.
---
--- @return boolean committed
function Repo.createVersion(input, agencyId, discordId)
    return FredPD.Core.db.transaction({
        {
            query = [[UPDATE fpd_brott SET superseded_at = CURRENT_TIMESTAMP(3)
                       WHERE agency_id = ? AND code = ? AND superseded_at IS NULL]],
            values = { agencyId, input.code },
        },
        {
            query = INSERT_SQL,
            values = insertValues(input, agencyId, discordId),
        },
    })
end

--- Retires an offence without replacing it.
---
--- For a statute that was repealed: the code stops being chargeable, every
--- record that cites it still reads.
function Repo.supersede(code, agencyId)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_brott SET superseded_at = CURRENT_TIMESTAMP(3)
           WHERE agency_id = ? AND code = ? AND superseded_at IS NULL]],
        { agencyId, code }
    )
end

FredPD.Repo.brott = Repo
