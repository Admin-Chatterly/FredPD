--- The master name index: SQL and record-level access (spec 7.3, 7.2).
---
--- This file owns `fpd_persons` and its children, and it is the first consumer
--- of `server/modules/access`. Four things about it are load-bearing.
---
--- **Every read goes out through the access module.** `searchPersons` and
--- `readPerson` take the *session* rather than an agency id, and neither of
--- them returns a row that has not been past `FredPD.Repo.access`. That is why
--- the session is a parameter of a file that is otherwise pure SQL: a repo
--- function that returned raw rows would be a function a future route could
--- call and hand straight to a client, and spec 4.5 would then be enforced by
--- everyone remembering to enforce it (invariant 4).
---
--- **The filtering is applied to the result set, not to the detail view.** A
--- search that lists a restricted person and refuses to open them has already
--- disclosed that the person is on file, which is the fact a compartment exists
--- to keep. `Repo.searchPersons` therefore over-fetches, filters, and only then
--- cuts the list to the size the caller asked for -- because
--- `Access.filterSearchResults` deliberately returns no count of what it
--- dropped, so the only safe way to fill a page is to ask for more rows than
--- the page holds.
---
--- **Nothing user-facing is built here** (invariant 6) and **nothing is
--- concatenated into SQL** (invariant 8). The one thing this file builds by
--- string is a list of `?` placeholders and a fixed set of `WHERE` fragments
--- that contain no values; the search term reaches MariaDB only ever as a bound
--- parameter, including the `%term%` of a LIKE.
---
--- **Field-level redaction is not here.** `fields.mental_health.view` and
--- `fields.victim_address.view` are decided in `routes.lua`, where the
--- session's permissions are already in hand; this file returns the caution and
--- the address and the route decides who sees them. Record-level access
--- (classification, compartments, seals) is the opposite: it is applied here,
--- because it decides whether a row may leave the database at all.
---
--- ## Phonetic search (7.2)
---
--- `fpd_persons` carries three generated columns -- `name_normalized`,
--- `soundex_first`, `soundex_last` -- and `fpd_person_aliases` carries two more.
--- They are generated so they cannot drift from the names they come from, and
--- the search below is written so that each branch of it can use an index:
---
---   * exact and prefix matches on `name_normalized` (`idx_fpd_persons_name`),
---   * `soundex_last = SOUNDEX(?)` and `soundex_first = SOUNDEX(?)`, which are
---     index seeks (`idx_fpd_persons_soundex`) rather than a function applied
---     to every row,
---   * an alias match through `idx_fpd_person_aliases_search` and
---     `idx_fpd_person_aliases_soundex`.
---
--- Only the `%token%` containment branch is a scan, and it is what "partial"
--- means: `SOUNDEX` alone will not find "Johan" inside "Karl Johansson".
---
--- `NULLIF(?, '')` appears throughout. An empty parameter is how this file says
--- "this branch does not apply to this search" -- `SOUNDEX(NULL)` is NULL and
--- `column = NULL` is never true, so an empty term cannot accidentally match
--- every row with an empty phone number. It is also how a nullable column is
--- written: a nil inside an oxmysql values list silently shortens the list and
--- shifts every placeholder after it, so nothing here ever passes one.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

--- The access repository (record-level access, spec 4.5).
local function accessRepo()
    return FredPD.Repo.access
end

--- The pure access service, for the classification test applied to a child row.
local function accessService()
    return FredPD.Modules.access
end

--- The record type these rows are known by in the generic access tables.
local RECORD_TYPE <const> = 'person'

--- Appendix D: `P-{######}`, one unbroken sequence per agency, no year in it.
local NUMBER_PREFIX <const> = 'P-'
local NUMBER_WIDTH <const> = 6

-- -----------------------------------------------------------------------------
-- Columns
-- -----------------------------------------------------------------------------

--- What a person row carries when it leaves this file.
---
--- `agency_id` and `classification` are selected because the access module
--- reads them off the row (`Access.control`), not because the interface wants
--- them -- and `identifier` is deliberately *not* selected. It is the ESX
--- character key; it identifies a player rather than a person on file, nothing
--- in the records interface needs it, and a column that leaves the server is a
--- column that ends up in a client's console.
local PERSON_COLUMNS <const> = [[
    p.id, p.agency_id AS agencyId, p.person_number AS personNumber,
    p.first_name AS firstName, p.middle_name AS middleName, p.last_name AS lastName,
    p.date_of_birth AS dateOfBirth, p.sex, p.phone, p.address,
    p.deceased_at AS deceasedAt, p.missing_since AS missingSince,
    p.classification, p.version,
    p.created_by AS createdBy, p.created_at AS createdAt,
    p.updated_by AS updatedBy, p.updated_at AS updatedAt
]]

-- -----------------------------------------------------------------------------
-- The search term
-- -----------------------------------------------------------------------------

--- Normalizes what was typed into what `name_normalized` holds.
---
--- `name_normalized` is `LOWER(TRIM(CONCAT_WS(' ', first, middle, last)))`, so
--- the term is lower-cased and its whitespace collapsed to match.
---
--- `%`, `_` and `\` are removed rather than escaped. Escaping them would mean
--- an `ESCAPE '\\'` clause on every LIKE, and a server running with
--- `NO_BACKSLASH_ESCAPES` parses that as two characters and refuses the
--- statement -- so the whole search would fail on a setting FredPD does not
--- control. None of the three occurs in a name, and a search for `%` that
--- matched every person on file is the failure this avoids.
---
--- @param value any
--- @return string normalized, possibly empty
function Repo.normalize(value)
    local text = type(value) == 'string' and value or tostring(value or '')

    text = text:gsub('[%%_\\]', ' ')
    text = text:gsub('%s+', ' ')
    text = text:match('^%s*(.-)%s*$') or ''

    return text:lower()
end

--- How many words of a term are used. Anything past this is a sentence, not a
--- name, and each token costs a LIKE.
local MAX_TOKENS <const> = 4

--- The shortest term worth running. One character matches a third of the index
--- and answers nothing.
local MIN_TERM <const> = 2

--- Turns what was typed into the parts the query binds.
---
--- Returns nil for anything too short to search on, which the route reports as
--- an invalid field rather than running.
---
--- @param value any what the officer typed
--- @return table|nil { full, tokens, first, last, digits, number }
function Repo.parseTerm(value)
    local full = Repo.normalize(value)
    if #full < MIN_TERM then return nil end

    local tokens = {}
    for word in full:gmatch('[^ ]+') do
        if #tokens < MAX_TOKENS then tokens[#tokens + 1] = word end
    end

    if #tokens == 0 then return nil end

    return {
        full = full,
        tokens = tokens,

        -- With one word typed, it is tried as both a first and a last name:
        -- "johansson" and "karl" are the same search as far as the officer is
        -- concerned, and which column a name lives in is not something they
        -- should have to know.
        first = tokens[1],
        last = tokens[#tokens],

        -- Digits only, for the phone branch. `''` when the term has none, which
        -- `NULLIF(?, '')` turns into "this branch does not apply".
        --
        -- The separators are stripped from the *column* as well, in the one
        -- deliberately unindexed comparison in this file: the phone column holds
        -- whatever the framework wrote into it, and an officer types a number
        -- the way it is printed on the card in their hand. An exact match on a
        -- column that is sometimes `555-0134` and sometimes `5550134` finds the
        -- person half the time, which is worse than not offering the branch.
        digits = (full:gsub('%D', '')),

        -- A person number as it is stored (`P-000431`). Upper-cased, because
        -- the column is not lower-case like `name_normalized` is.
        number = full:upper(),
    }
end

-- -----------------------------------------------------------------------------
-- Search
-- -----------------------------------------------------------------------------

--- `?, ?, ?` for n values. Placeholders, never values (invariant 8).
local function placeholders(count)
    local marks = {}
    for index = 1, count do marks[index] = '?' end

    return table.concat(marks, ',')
end

--- The alias branches. Each is a fragment with its own placeholders; the values
--- are appended by the caller in the same order the fragments appear.
local ALIAS_EXACT <const> = [[EXISTS (SELECT 1 FROM fpd_person_aliases a
                                       WHERE a.person_id = p.id AND a.alias_normalized = ?)]]

local ALIAS_MATCH <const> = [[EXISTS (SELECT 1 FROM fpd_person_aliases a
                                       WHERE a.person_id = p.id
                                         AND (a.alias_normalized LIKE ?
                                              OR a.alias_soundex = SOUNDEX(NULLIF(?, ''))))]]

--- Which alias matched, so the list can say *why* a row is in it. A person
--- found under "Bulldog" and listed only as "Marko Petrov" looks like a wrong
--- result otherwise.
local MATCHED_ALIAS <const> = [[(SELECT a.alias FROM fpd_person_aliases a
                                  WHERE a.person_id = p.id
                                    AND (a.alias_normalized LIKE ?
                                         OR a.alias_soundex = SOUNDEX(NULLIF(?, '')))
                                  ORDER BY CHAR_LENGTH(a.alias), a.alias LIMIT 1)]]

--- The containment test, one LIKE per word, ANDed.
---
--- ANDed rather than ORed on purpose: "karl johansson" must mean both words,
--- not either. ORing them turns a two-word search into every Karl in the city,
--- and the ranking below cannot rescue a result set that large.
---
--- @return string fragment, table values
local function partialFragment(terms)
    local parts, values = {}, {}

    for index = 1, #terms.tokens do
        parts[index] = 'p.name_normalized LIKE ?'
        values[index] = '%' .. terms.tokens[index] .. '%'
    end

    return '(' .. table.concat(parts, ' AND ') .. ')', values
end

--- How well a row matched, highest first.
---
--- The scale is ordinal and nothing outside the ORDER BY reads it, so the exact
--- numbers do not matter; their order does. An exact name beats a person
--- number, which beats a phone number, which beats a prefix, which beats words
--- in any order, which beats an alias, which beats a phonetic match -- and a
--- phonetic match on both names beats one on either alone, because two
--- SOUNDEX codes agreeing by chance is much rarer than one.
---
--- @return string fragment, table values
local function scoreFragment(terms)
    local partial, partialValues = partialFragment(terms)

    local sql = ([[CASE
        WHEN p.name_normalized = ? THEN 100
        WHEN p.person_number = NULLIF(?, '') THEN 95
        WHEN REPLACE(REPLACE(p.phone, '-', ''), ' ', '') = NULLIF(?, '') THEN 90
        WHEN p.name_normalized LIKE ? THEN 80
        WHEN %s THEN 70
        WHEN %s THEN 60
        WHEN p.soundex_last = SOUNDEX(NULLIF(?, '')) AND p.soundex_first = SOUNDEX(NULLIF(?, '')) THEN 50
        WHEN p.soundex_last = SOUNDEX(NULLIF(?, '')) THEN 40
        WHEN p.soundex_first = SOUNDEX(NULLIF(?, '')) THEN 35
        ELSE 20
    END]]):format(partial, ALIAS_EXACT)

    local values = {
        terms.full,
        terms.number,
        terms.digits,
        terms.full .. '%',
    }

    for index = 1, #partialValues do values[#values + 1] = partialValues[index] end

    values[#values + 1] = terms.full          -- ALIAS_EXACT
    values[#values + 1] = terms.last          -- both-name phonetic
    values[#values + 1] = terms.first
    values[#values + 1] = terms.last          -- last name alone
    values[#values + 1] = terms.first         -- first name alone

    return sql, values
end

--- Which rows are candidates at all.
---
--- Phonetic *and* partial, as 7.2 requires, and the phonetic half is tried both
--- ways round: a term of "johansson karl" must find the same person as "karl
--- johansson", and neither the officer nor the index knows which order was
--- typed.
---
--- @return string fragment, table values
local function matchFragment(terms)
    local partial, partialValues = partialFragment(terms)

    local branches = {
        partial,
        "p.person_number = NULLIF(?, '')",
        "REPLACE(REPLACE(p.phone, '-', ''), ' ', '') = NULLIF(?, '')",
        "p.soundex_last = SOUNDEX(NULLIF(?, ''))",
        "p.soundex_first = SOUNDEX(NULLIF(?, ''))",
        "p.soundex_last = SOUNDEX(NULLIF(?, ''))",
        "p.soundex_first = SOUNDEX(NULLIF(?, ''))",
        ALIAS_MATCH,
    }

    local values = {}
    for index = 1, #partialValues do values[index] = partialValues[index] end

    values[#values + 1] = terms.number
    values[#values + 1] = terms.digits
    values[#values + 1] = terms.last
    values[#values + 1] = terms.first
    values[#values + 1] = terms.first     -- the same two, the other way round
    values[#values + 1] = terms.last
    values[#values + 1] = '%' .. terms.full .. '%'
    values[#values + 1] = terms.full

    return '(' .. table.concat(branches, '\n        OR ') .. ')', values
end

--- The largest page a caller may ask for, and how many rows are read to fill it.
---
--- The multiplier is the price of doing access control properly. Rows the
--- reader may not know about are removed *after* the database has ranked them,
--- and `Access.filterSearchResults` returns no count of what it dropped (by
--- design: a count is itself a disclosure), so a full page can only be
--- guaranteed by reading more rows than the page holds. Four times is enough
--- for any realistic mix of classifications without turning a 25-row page into
--- a table scan; a reader whose page still comes up short is one whose agency
--- has classified most of its index above them, and the honest answer there is
--- a short page.
local MAX_LIMIT <const> = 50
local OVERFETCH <const> = 4
local OVERFETCH_CEILING <const> = 300

--- Runs a person search and applies record-level access to the result set.
---
--- @param session table the session, never input (invariant 1)
--- @param params table { terms (from `parseTerm`), dateOfBirth, limit, allowRestricted }
--- @return table { persons, restrictedWithheld, restrictedIncluded }
function Repo.searchPersons(session, params)
    local terms = params.terms
    local limit = math.min(math.max(tonumber(params.limit) or 25, 1), MAX_LIMIT)

    local score, values = scoreFragment(terms)
    local matchSql, matchValues = matchFragment(terms)

    -- The matched-alias column sits between the score and the WHERE clause, so
    -- its two values go between theirs. Order of placeholders is order of
    -- values, and there is no second chance to get it right.
    values[#values + 1] = '%' .. terms.full .. '%'
    values[#values + 1] = terms.full

    values[#values + 1] = session.agencyId

    for index = 1, #matchValues do values[#values + 1] = matchValues[index] end

    local dobClause = ''
    if params.dateOfBirth then
        dobClause = ' AND p.date_of_birth = ?'
        values[#values + 1] = params.dateOfBirth
    end

    values[#values + 1] = math.min(limit * OVERFETCH, OVERFETCH_CEILING)

    local rows = db().query(([[
        SELECT %s,
               %s AS matchScore,
               %s AS matchedAlias
          FROM fpd_persons p
         WHERE p.agency_id = ?
           AND %s%s
         ORDER BY matchScore DESC, p.last_name, p.first_name, p.id
         LIMIT ?]]):format(PERSON_COLUMNS, score, MATCHED_ALIAS, matchSql, dobClause), values)

    for index = 1, #rows do
        -- What a stub says it is standing in for. Set here rather than selected
        -- as a literal, because it is FredPD's word for the row and not the
        -- database's.
        rows[index].recordType = RECORD_TYPE
    end

    -- Invariant 4, and the acceptance criterion for M2: rows this reader may
    -- not know about are gone from here on -- no id, no name, no gap where they
    -- were. Rows in a stubbed compartment come back as the three-field stub.
    -- The call also writes the search's audit entry (invariant 11).
    local shaped = accessRepo().filterSearch(session, RECORD_TYPE, rows)

    local persons, withheld, included = {}, false, false

    for index = 1, #shaped do
        local row = shaped[index]

        if #persons >= limit then break end

        if row.restricted then
            -- A stub. It carries no id and no name; it is the "restricted
            -- record -- contact <unit>" line 4.5 asks for.
            persons[#persons + 1] = row
        elseif accessService().isRestricted(row) and not params.allowRestricted then
            -- The reader *is* cleared for this one, but 7.2 requires a reason or
            -- a case number before a query reaches restricted data. Withheld
            -- until they give one, and the flag below is what asks them for it.
            withheld = true
        else
            included = included or accessService().isRestricted(row)
            persons[#persons + 1] = row
        end
    end

    return { persons = persons, restrictedWithheld = withheld, restrictedIncluded = included }
end

-- -----------------------------------------------------------------------------
-- One person
-- -----------------------------------------------------------------------------

--- One person, through the access module.
---
--- The second return value is what the caller shows when the row is refused:
--- `stub` means the reader may be told a record exists and who to ring about
--- it, `hidden` means they may not, and `missing` means it genuinely is not
--- there. Only `full` comes with a row.
---
--- The refusal path builds a second reader, which costs one lookup, and it is
--- worth it: without it every refusal would have to be answered as "not found",
--- and the stub in 4.5 -- the thing that tells an officer to ring the narcotics
--- unit instead of assuming the person is unknown to the police -- could not
--- exist.
---
--- @param session table
--- @param id number
--- @return table|nil row, string visibility 'full' | 'stub' | 'hidden' | 'missing'
--- @return table|nil the raw row, for building a stub from
function Repo.readPerson(session, id)
    local row = db().single(
        ([[SELECT %s FROM fpd_persons p WHERE p.agency_id = ? AND p.id = ?]]):format(PERSON_COLUMNS),
        { session.agencyId, id }
    )

    if not row then return nil, 'missing' end

    row.recordType = RECORD_TYPE

    -- Audits the read when the record is restricted, including the refusal
    -- (invariant 11), and attaches the row's compartments, seal and grants.
    local allowed = accessRepo().read(session, RECORD_TYPE, row)
    if allowed then return allowed, 'full' end

    -- `row` still carries what `read` attached, so this decides the refusal
    -- without touching the access tables again.
    local reader = accessRepo().reader(session)

    return nil, accessService().visibility(reader, row), row
end

--- Aliases and monikers (7.3).
function Repo.aliases(agencyId, personId)
    return db().query(
        [[SELECT a.id, a.alias, a.kind, a.source, a.created_by AS createdBy, a.created_at AS createdAt
            FROM fpd_person_aliases a
           WHERE a.agency_id = ? AND a.person_id = ?
           ORDER BY a.kind, a.alias]],
        { agencyId, personId }
    )
end

--- The physical description (7.3). One row or none.
function Repo.descriptors(agencyId, personId)
    return db().single(
        [[SELECT d.height_cm AS heightCm, d.weight_kg AS weightKg, d.build,
                 d.hair_colour AS hairColour, d.hair_style AS hairStyle,
                 d.eye_colour AS eyeColour, d.complexion, d.glasses, d.notes,
                 d.updated_by AS updatedBy, d.updated_at AS updatedAt
            FROM fpd_person_descriptors d
           WHERE d.agency_id = ? AND d.person_id = ?]],
        { agencyId, personId }
    )
end

--- Photo history: mugshots, field photos, and the marks, scars and tattoos 7.3
--- asks for.
---
--- `media_ref` is a store reference, not a URL. It is served through the
--- gateway behind a signed URL (invariant 9); a client that receives this
--- cannot fetch anything with it on its own.
function Repo.photos(agencyId, personId)
    return db().query(
        [[SELECT ph.id, ph.kind, ph.media_ref AS mediaRef, ph.body_location AS bodyLocation,
                 ph.description, ph.taken_at AS takenAt, ph.source_case AS sourceCase,
                 ph.classification, ph.created_by AS createdBy, ph.created_at AS createdAt
            FROM fpd_person_photos ph
           WHERE ph.agency_id = ? AND ph.person_id = ?
           ORDER BY ph.taken_at DESC, ph.id DESC
           LIMIT 100]],
        { agencyId, personId }
    )
end

--- "Fingerprints on file" and "DNA on file" -- never a biometric value (8.1).
function Repo.biometrics(agencyId, personId)
    return db().query(
        [[SELECT b.kind, b.on_file AS onFile, b.index_name AS indexName,
                 b.recorded_on AS recordedOn, b.updated_at AS updatedAt
            FROM fpd_person_biometrics_index b
           WHERE b.agency_id = ? AND b.person_id = ?
           ORDER BY b.kind]],
        { agencyId, personId }
    )
end

--- The live cautions on a set of people, in one query (7.3, spec 12).
---
--- Live means not cancelled and not expired, and expiry is evaluated by the
--- database on every read rather than swept by a job: a caution stops being a
--- caution at a moment when no statement of ours runs, and a sweeper that dies
--- leaves officers being warned about people who are no longer flagged.
---
--- One query for the whole page, not one per row -- section 12 budgets 150 ms
--- for a search and the cautions are part of it.
---
--- @param agencyId string
--- @param personIds table list of ids
--- @return table personId -> list of cautions
function Repo.liveCautions(agencyId, personIds)
    local byPerson = {}
    if type(personIds) ~= 'table' or #personIds == 0 then return byPerson end

    local values = { agencyId }
    for index = 1, #personIds do values[#values + 1] = personIds[index] end

    local rows = db().query(
        ([[SELECT c.id, c.person_id AS personId, c.kind, c.detail, c.field_key AS fieldKey,
                  c.source_case AS sourceCase, c.classification, c.expires_at AS expiresAt,
                  c.created_by AS createdBy, c.created_at AS createdAt
             FROM fpd_person_cautions c
            WHERE c.agency_id = ? AND c.person_id IN (%s)
              AND c.cancelled_at IS NULL
              AND (c.expires_at IS NULL OR c.expires_at > NOW(3))
            ORDER BY c.created_at DESC]]):format(placeholders(#personIds)),
        values
    )

    for index = 1, #rows do
        local row = rows[index]
        local list = byPerson[row.personId]

        if not list then
            list = {}
            byPerson[row.personId] = list
        end

        list[#list + 1] = row
    end

    return byPerson
end

--- One caution, for the cancel path.
function Repo.getCaution(agencyId, id)
    return db().single(
        [[SELECT c.id, c.person_id AS personId, c.kind, c.field_key AS fieldKey,
                 c.classification, c.cancelled_at AS cancelledAt
            FROM fpd_person_cautions c
           WHERE c.agency_id = ? AND c.id = ?]],
        { agencyId, id }
    )
end

--- Vehicles and firearms registered to a person (7.3: linked records).
---
--- Both are read through the same access filter as anything else, under their
--- own record type: a person an officer may read does not carry with them
--- permission to read a vehicle that is part of a restricted investigation.
---
--- The projection is deliberately thin -- enough to list and link, not enough
--- to be a substitute for the vehicle and firearm modules' own reads, which own
--- these tables (7.4, 7.5).
function Repo.linkedVehicles(session, personId)
    local rows = db().query(
        [[SELECT v.id, v.agency_id AS agencyId, v.plate, v.model, v.colour,
                 v.registration_status AS registrationStatus,
                 v.insurance_status AS insuranceStatus, v.classification
            FROM fpd_vehicles v
           WHERE v.agency_id = ? AND v.owner_person_id = ?
           ORDER BY v.plate
           LIMIT 50]],
        { session.agencyId, personId }
    )

    for index = 1, #rows do rows[index].recordType = 'vehicle' end

    return accessRepo().filterSearch(session, 'vehicle', rows)
end

function Repo.linkedFirearms(session, personId)
    local rows = db().query(
        [[SELECT f.id, f.agency_id AS agencyId, f.serial, f.make, f.model, f.type,
                 f.calibre, f.status, f.classification
            FROM fpd_firearms f
           WHERE f.agency_id = ? AND f.owner_person_id = ?
           ORDER BY f.serial
           LIMIT 50]],
        { session.agencyId, personId }
    )

    for index = 1, #rows do rows[index].recordType = 'firearm' end

    return accessRepo().filterSearch(session, 'firearm', rows)
end

-- -----------------------------------------------------------------------------
-- Writes
-- -----------------------------------------------------------------------------

--- The columns `person.update` may write, and nothing else.
---
--- A fixed allowlist in code (never a column name from input) is what keeps an
--- UPDATE from being told which column to set by the client that sent it.
--- `person_number`, `agency_id`, `identifier`, `version` and every `created_*`
--- and `updated_*` column are absent on purpose: they are the server's
--- (invariant 1).
local UPDATE_COLUMNS <const> = {
    firstName = 'first_name',
    middleName = 'middle_name',
    lastName = 'last_name',
    dateOfBirth = 'date_of_birth',
    sex = 'sex',
    phone = 'phone',
    address = 'address',
    classification = 'classification',
}

--- Fixed order, so the statement a given input produces is the same every time
--- (`pairs` is not ordered) and the values line up with the placeholders.
local UPDATE_ORDER <const> = {
    'firstName', 'middleName', 'lastName', 'dateOfBirth', 'sex', 'phone', 'address', 'classification',
}

--- Columns that are NOT NULL and therefore cannot take the `NULLIF(?, '')`
--- treatment the nullable ones get.
local NOT_NULLABLE <const> = { classification = true }

--- Updates a person, with optimistic locking (spec 13.1).
---
--- The version is in the WHERE clause, so a stale edit affects no rows and the
--- route can report a conflict instead of silently overwriting the officer who
--- saved first.
---
--- An empty string means "clear this field": it travels as `''` and
--- `NULLIF(?, '')` makes it NULL in the database. It cannot travel as a Lua nil,
--- because a nil in an oxmysql values list shortens the list and shifts every
--- placeholder after it -- which here would write a phone number into `sex`.
---
--- @return number rows affected
function Repo.updatePerson(agencyId, id, expectedVersion, fields, discordId)
    local sets, values = {}, {}

    for index = 1, #UPDATE_ORDER do
        local name = UPDATE_ORDER[index]
        local value = fields[name]

        if value ~= nil then
            local column = UPDATE_COLUMNS[name]

            if NOT_NULLABLE[name] then
                sets[#sets + 1] = ('`%s` = ?'):format(column)
            else
                sets[#sets + 1] = ("`%s` = NULLIF(?, '')"):format(column)
            end

            values[#values + 1] = value
        end
    end

    -- Deceased and missing are booleans on the way in and timestamps in the
    -- database: *when* somebody died is a fact, and a client's clock is not
    -- allowed to decide it (invariant 1). Setting a flag that is already set
    -- keeps the original moment rather than moving it to now.
    if fields.deceased ~= nil then
        sets[#sets + 1] = '`deceased_at` = CASE WHEN ? = 1 THEN COALESCE(`deceased_at`, NOW(3)) ELSE NULL END'
        values[#values + 1] = fields.deceased and 1 or 0
    end

    if fields.missing ~= nil then
        sets[#sets + 1] = '`missing_since` = CASE WHEN ? = 1 THEN COALESCE(`missing_since`, NOW(3)) ELSE NULL END'
        values[#values + 1] = fields.missing and 1 or 0
    end

    if #sets == 0 then return 0 end

    sets[#sets + 1] = '`version` = `version` + 1'
    sets[#sets + 1] = '`updated_by` = ?'
    values[#values + 1] = discordId

    values[#values + 1] = agencyId
    values[#values + 1] = id
    values[#values + 1] = expectedVersion

    return db().execute(
        ('UPDATE fpd_persons SET %s WHERE agency_id = ? AND id = ? AND version = ?')
            :format(table.concat(sets, ', ')),
        values
    )
end

--- Puts a person in the index and gives them their number.
---
--- No route calls this yet: 7.3 says identity comes from the framework, so the
--- rows are created by the paths that first meet a person -- booking, an arrest,
--- a field interview -- rather than by an officer typing a new file into
--- existence. It lives here because the number must be allocated the one
--- correct way, and `core/counters.lua` is the only correct way: the counter row
--- is locked inside the transaction that writes the record, which behaves the
--- same under every isolation level (ADR-012).
---
--- `P-{######}` has no year in it (Appendix D), so the counter is year-less and
--- the sequence runs unbroken for the life of the agency.
---
--- @return number|nil id
function Repo.createPerson(agencyId, fields, discordId)
    local counters = FredPD.Core.counters
    local year = counters.YEARLESS

    local values = counters.numberValues(NUMBER_PREFIX, NUMBER_WIDTH, 'person', agencyId, year)
    local base = #values

    -- Written by index rather than appended: several of these are routinely
    -- absent, and appending after a nil fills its slot with the next value.
    values[base + 1] = agencyId
    values[base + 2] = fields.identifier or ''
    values[base + 3] = fields.firstName or ''
    values[base + 4] = fields.middleName or ''
    values[base + 5] = fields.lastName or ''
    values[base + 6] = fields.dateOfBirth or ''
    values[base + 7] = fields.sex or ''
    values[base + 8] = fields.phone or ''
    values[base + 9] = fields.address or ''
    values[base + 10] = fields.classification or 'internal'
    values[base + 11] = discordId

    local committed = db().transaction(counters.transaction('person', agencyId, year, {
        {
            query = ([[INSERT INTO fpd_persons
                           (person_number, agency_id, identifier, first_name, middle_name,
                            last_name, date_of_birth, sex, phone, address, classification, created_by)
                       VALUES (%s, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''),
                               NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?, ?)]])
                :format(counters.numberSql()),
            values = values,
        },
    }))

    if not committed then return nil end

    -- Read back, because a transaction reports only whether it committed. The
    -- lookup is scoped to the officer who just wrote it: one Discord account
    -- holds one session, so nobody else can have interleaved a person under
    -- this signature.
    return db().scalar(
        'SELECT id FROM fpd_persons WHERE agency_id = ? AND created_by = ? ORDER BY id DESC LIMIT 1',
        { agencyId, discordId }
    )
end

--- Adds a caution (7.3).
---
--- `fieldKey` is set by the route from the kind, never taken from input: it is
--- the permission that gates the caution, and a client that could choose it
--- could publish a mental-health flag by declaring it gated on nothing. The
--- database refuses a mental-health caution without it either way
--- (`ck_fpd_person_cautions_field`), which is the point of having the rule in
--- both places.
---
--- Expiry arrives as a number of days and the *database* turns it into a
--- moment. A client-supplied timestamp would let an officer write a caution
--- that expired before it was created, or one that never expires while
--- appearing to (invariant 1).
---
--- @return number id
function Repo.addCaution(agencyId, personId, fields, discordId)
    return db().insert(
        [[INSERT INTO fpd_person_cautions
              (agency_id, person_id, kind, detail, field_key, source_case, classification,
               expires_at, created_by)
          VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?,
                  CASE WHEN ? = 0 THEN NULL ELSE DATE_ADD(NOW(3), INTERVAL ? DAY) END, ?)]],
        {
            agencyId, personId, fields.kind,
            fields.detail or '', fields.fieldKey or '', fields.sourceCase or '',
            fields.classification or 'internal',
            fields.expiresInDays or 0, fields.expiresInDays or 0,
            discordId,
        }
    )
end

--- Cancels a caution.
---
--- An update rather than a delete, and `cancelled_at IS NULL` in the WHERE so a
--- second cancel affects no rows and is reported as a conflict. The row stays:
--- "this person was flagged as violent for six months and then somebody
--- withdrew it" is a question an audit asks.
---
--- @return number rows affected
function Repo.cancelCaution(agencyId, id, discordId)
    return db().execute(
        [[UPDATE fpd_person_cautions
             SET cancelled_at = NOW(3), cancelled_by = ?
           WHERE agency_id = ? AND id = ? AND cancelled_at IS NULL]],
        { discordId, agencyId, id }
    )
end

-- -----------------------------------------------------------------------------
-- The query log (7.2, 11.4)
-- -----------------------------------------------------------------------------

--- Records that a query was run, what was typed, and what came back.
---
--- Separate from the audit log and not a duplicate of it. The audit log answers
--- "who read record 431"; this answers "who has been looking up their
--- ex-partner", which is the most common real misuse of a police system, and it
--- needs the *term* -- including a term that matched nothing, which is as
--- interesting as one that did.
---
--- Everything identifying the officer comes from the session (invariant 1).
--- `restricted` may only be 1 when a reason or a case number was given: the
--- database enforces that with a CHECK, and the route refuses to include
--- restricted rows without one, so the two agree.
function Repo.logQuery(session, entry)
    db().insert(
        [[INSERT INTO fpd_query_log
              (agency_id, discord_id, officer_id, identifier, query_type, term,
               access_point, restricted, reason, case_number, result_count, hit_count)
          VALUES (?, ?, NULLIF(?, 0), NULLIF(?, ''), ?, ?, NULLIF(?, ''), ?,
                  NULLIF(?, ''), NULLIF(?, ''), ?, ?)]],
        {
            session.agencyId,
            session.discordId,
            session.officerId or 0,
            session.identifier or '',
            entry.queryType,
            entry.term,
            session.accessPoint or '',
            entry.restricted and 1 or 0,
            entry.reason or '',
            entry.caseNumber or '',
            entry.resultCount or 0,
            entry.hitCount or 0,
        }
    )
end

--- The query log, for `query.log.view` (7.2).
---
--- Scoped to the reader's own agency. `mine` is the officer asking what they
--- themselves have run; without it this is the misuse-investigation view, which
--- is why it is behind its own permission rather than behind `rms.person.view`.
function Repo.queryLog(agencyId, filter)
    local where = { 'q.agency_id = ?' }
    local values = { agencyId }

    if filter.discordId then
        where[#where + 1] = 'q.discord_id = ?'
        values[#values + 1] = filter.discordId
    end

    if filter.queryType then
        where[#where + 1] = 'q.query_type = ?'
        values[#values + 1] = filter.queryType
    end

    values[#values + 1] = math.min(math.max(tonumber(filter.limit) or 50, 1), 200)

    return db().query(([[
        SELECT q.id, q.discord_id AS discordId, q.officer_id AS officerId,
               q.query_type AS queryType, q.term, q.access_point AS accessPoint,
               q.restricted, q.reason, q.case_number AS caseNumber,
               q.result_count AS resultCount, q.hit_count AS hitCount,
               q.created_at AS createdAt
          FROM fpd_query_log q
         WHERE %s
         ORDER BY q.created_at DESC, q.id DESC
         LIMIT ?]]):format(table.concat(where, ' AND ')), values)
end

FredPD.Repo.persons = Repo
