--- The unified query: SQL (spec 7.2). Parameterized only (invariant 8).
---
--- Four rules shape every statement here, and the first two are the ones that
--- make this file allowed to exist at all.
---
--- **Nothing here decides who may read a row.** Every read selects the
--- access-control columns -- `id`, `agency_id`, `classification` -- and
--- `routes.lua` hands the rows to the access module before anything reaches a
--- client (invariant 4). A WHERE clause in this file that filtered on
--- classification would be a second, quieter copy of the access model, and the
--- first time the two disagreed the quieter one would win.
---
--- **This module reads the registers' tables and does not call their repos.**
--- A module reaches another module through its `service.lua`, never its
--- `repo.lua`, and the two registers publish their *rules* there and their SQL
--- nowhere. So the statements below are this module's own, deliberately thin:
--- enough to rank a result and raise a hot-file hit, never enough to be a
--- second way of reading a record. Opening what a query found is still
--- `person.get`, `vehicle.get` and `firearm.get`, which own those tables.
---
--- **No nil ever reaches a values list.** A nil appended to a Lua list appends
--- nothing, so the next value takes its slot and every placeholder after it
--- reads the wrong parameter. Optional columns travel as `''` or `0` and
--- `NULLIF` turns them back into NULL in the database.
---
--- **The log row is written for every query, including the empty one.** A
--- search that found nothing is as interesting to a misuse investigation as one
--- that did -- more so, when somebody is working through a list of names. The
--- insert returns its id, because a hot-file confirmation is bound to the query
--- that raised the lead (7.2).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

--- `?, ?, ?` for a list of n values. Placeholders only: no value is ever
--- concatenated into a statement (invariant 8).
local function placeholders(count)
    local marks = {}
    for index = 1, count do marks[index] = '?' end

    return table.concat(marks, ',')
end

--- Groups rows by one of their columns, for a batched child query.
local function groupBy(rows, key)
    local grouped = {}

    for index = 1, #rows do
        local row = rows[index]
        local list = grouped[row[key]]

        if not list then
            list = {}
            grouped[row[key]] = list
        end

        list[#list + 1] = row
    end

    return grouped
end

-- =============================================================================
-- The registers, read for ranking
-- =============================================================================

--- What a person row carries into a result list.
---
--- `identifier` is not selected, for the reason `persons/repo.lua` gives: it is
--- the ESX character key, it identifies a player rather than a person on file,
--- and a column that leaves the server ends up in a client's console.
--- `address` is selected because an address query has to be able to rank on it;
--- the route redacts it for a reader without `fields.victim_address.view`
--- before anything is returned (4.5).
local PERSON_COLUMNS <const> = [[
    p.id, p.agency_id AS agencyId, p.person_number AS personNumber,
    p.first_name AS firstName, p.middle_name AS middleName, p.last_name AS lastName,
    p.date_of_birth AS dateOfBirth, p.sex, p.phone, p.address,
    p.deceased_at AS deceasedAt, p.missing_since AS missingSince,
    p.classification
]]

--- The alias branch, so a person found under a moniker is found at all (7.3).
local ALIAS_MATCH <const> = [[EXISTS (SELECT 1 FROM fpd_person_aliases a
                                       WHERE a.person_id = p.id
                                         AND (a.alias_normalized LIKE ?
                                              OR a.alias_soundex = SOUNDEX(NULLIF(?, ''))))]]

--- The name index, in the three ways a query reaches it.
---
--- `mode` is `name`, `phone` or `address` and comes from
--- `service.personMode`, not from input. Each branch is written so it can use
--- an index: `name_normalized` prefix and the two SOUNDEX columns are seeks
--- (`idx_fpd_persons_name`, `idx_fpd_persons_soundex`), and only the `%token%`
--- containment test is a scan -- which is what "partial" means, because SOUNDEX
--- alone will not find "Johan" inside "Karl Johansson" (7.2).
---
--- `NULLIF(?, '')` is how a branch says "this does not apply to this search":
--- `SOUNDEX(NULL)` is NULL and `column = NULL` is never true, so an empty term
--- cannot match every row with an empty phone number.
---
--- @param agencyId string from the session, never from input (invariant 1)
--- @param params table { mode, term, tokens, digits, limit }
--- @return table rows
function Repo.searchPersons(agencyId, params)
    local values = { agencyId }
    local clause

    if params.mode == 'phone' then
        clause = "REPLACE(REPLACE(p.phone, '-', ''), ' ', '') = NULLIF(?, '')"
        values[#values + 1] = params.digits or ''
    elseif params.mode == 'address' then
        clause = 'p.address LIKE ?'
        values[#values + 1] = '%' .. params.term:lower() .. '%'
    else
        local tokens = params.tokens or {}
        local partial = {}

        -- ANDed, not ORed: "karl johansson" means both words. ORing them turns
        -- a two-word search into every Karl in the city and no ranking rescues
        -- a result set that large.
        for index = 1, #tokens do
            partial[index] = 'p.name_normalized LIKE ?'
            values[#values + 1] = '%' .. tokens[index] .. '%'
        end

        local branches = {
            #partial > 0 and ('(' .. table.concat(partial, ' AND ') .. ')') or '0',
            "p.person_number = NULLIF(?, '')",
            "p.soundex_last = SOUNDEX(NULLIF(?, ''))",
            "p.soundex_first = SOUNDEX(NULLIF(?, ''))",
            -- The same two the other way round: an officer who types
            -- "johansson karl" must find who "karl johansson" finds.
            "p.soundex_last = SOUNDEX(NULLIF(?, ''))",
            "p.soundex_first = SOUNDEX(NULLIF(?, ''))",
            ALIAS_MATCH,
        }

        local tokens1 = tokens[1] or ''
        local tokensLast = tokens[#tokens] or ''

        values[#values + 1] = params.term:upper()
        values[#values + 1] = tokensLast
        values[#values + 1] = tokens1
        values[#values + 1] = tokens1
        values[#values + 1] = tokensLast
        values[#values + 1] = '%' .. params.term:lower() .. '%'
        values[#values + 1] = params.term:lower()

        clause = '(' .. table.concat(branches, '\n           OR ') .. ')'
    end

    values[#values + 1] = params.limit or 75

    return db().query(
        ([[SELECT %s
             FROM fpd_persons p
            WHERE p.agency_id = ?
              AND %s
            ORDER BY p.last_name, p.first_name, p.id
            LIMIT ?]]):format(PERSON_COLUMNS, clause),
        values
    )
end

--- The vehicle register: a plate prefix or a whole VIN.
---
--- A prefix rather than `%term%` for the reason the register itself gives:
--- `uq_fpd_vehicles_plate` can serve a leading-anchored LIKE and cannot serve a
--- leading wildcard, and a full scan on every partial plate is the difference
--- between the 150 ms budget of section 12 and a query that gets slower every
--- day the server runs.
function Repo.searchVehicles(agencyId, term, limit)
    return db().query(
        [[SELECT v.id, v.agency_id AS agencyId, v.plate, v.vin, v.model, v.colour,
                 v.registration_status AS registrationStatus,
                 v.insurance_status AS insuranceStatus,
                 v.owner_person_id AS ownerPersonId, v.classification
            FROM fpd_vehicles v
           WHERE v.agency_id = ? AND (v.plate LIKE ? OR v.vin = ?)
           ORDER BY v.plate
           LIMIT ?]],
        { agencyId, term:upper() .. '%', term:upper(), limit or 75 }
    )
end

--- The firearm register: a serial prefix, same index reasoning.
function Repo.searchFirearms(agencyId, term, limit)
    return db().query(
        [[SELECT f.id, f.agency_id AS agencyId, f.serial, f.make, f.model, f.type,
                 f.calibre, f.status, f.owner_person_id AS ownerPersonId, f.classification
            FROM fpd_firearms f
           WHERE f.agency_id = ? AND f.serial LIKE ?
           ORDER BY f.serial
           LIMIT ?]],
        { agencyId, term:upper() .. '%', limit or 75 }
    )
end

-- =============================================================================
-- The hot file (7.2)
-- =============================================================================

--- Live flags for several vehicles at once.
---
--- One query however many rows came back, and only for rows the reader is
--- already allowed to see: asking the database about the flags on a record that
--- was filtered out would be the same disclosure by a slower route.
---
--- "Live" is a cleared-at of NULL and an expiry that has not passed, and both
--- are evaluated by the database rather than in Lua -- the expiry is the point
--- of the column, and a server whose clock disagrees with its database should
--- believe the database.
---
--- Each row carries its own `classification`, because a BOLO written by the
--- intelligence unit can sit on an ordinary vehicle (4.5, "attachments can be
--- stricter") and the caller filters them accordingly.
---
--- @param ids table vehicle ids
--- @return table vehicleId -> list of flags
function Repo.liveFlagsFor(agencyId, ids)
    if type(ids) ~= 'table' or #ids == 0 then return {} end

    local values = { agencyId }
    for index = 1, #ids do values[#values + 1] = ids[index] end

    return groupBy(db().query(
        ([[SELECT f.id, f.agency_id AS agencyId, f.vehicle_id AS vehicleId, f.kind,
                  f.case_number AS caseNumber, f.classification, f.expires_at AS expiresAt
             FROM fpd_vehicle_flags f
            WHERE f.agency_id = ? AND f.vehicle_id IN (%s)
              AND f.cleared_at IS NULL AND (f.expires_at IS NULL OR f.expires_at > NOW(3))
            ORDER BY f.created_at DESC, f.id DESC]]):format(placeholders(#ids)),
        values
    ), 'vehicleId')
end

--- Live cautions for several people at once (7.3).
---
--- `detail` is deliberately not selected. A result list is read at a roadside,
--- the detail of a caution is a paragraph, and on a mental-health caution it is
--- the one string `fields.mental_health.view` exists to keep off most screens --
--- a list is the easiest place to leak one by accident. `field_key` *is*
--- selected, because the caller needs it to apply that gate.
---
--- @return table personId -> list of cautions
function Repo.liveCautionsFor(agencyId, ids)
    if type(ids) ~= 'table' or #ids == 0 then return {} end

    local values = { agencyId }
    for index = 1, #ids do values[#values + 1] = ids[index] end

    return groupBy(db().query(
        ([[SELECT c.id, c.agency_id AS agencyId, c.person_id AS personId, c.kind,
                  c.field_key AS fieldKey, c.classification, c.expires_at AS expiresAt
             FROM fpd_person_cautions c
            WHERE c.agency_id = ? AND c.person_id IN (%s)
              AND c.cancelled_at IS NULL AND (c.expires_at IS NULL OR c.expires_at > NOW(3))
            ORDER BY c.created_at DESC, c.id DESC]]):format(placeholders(#ids)),
        values
    ), 'personId')
end

--- One hit and the record it hangs off, for the confirmation route.
---
--- Returns both halves because both are checked: the record decides whether
--- this reader may know about any of it (4.5), and the flag or caution carries
--- its own classification on top of that. A firearm is its own hit -- the
--- status is a column on the weapon rather than a row of its own -- so the two
--- halves are the same row there.
---
--- `expired` is computed by the database rather than compared in Lua, for the
--- same reason the searches above evaluate expiry in SQL.
---
--- @return table|nil { record, child, recordType, recordId, kind }
function Repo.hitTarget(agencyId, hitType, hitId)
    if hitType == 'vehicle_flag' then
        local flag = db().single(
            [[SELECT f.id, f.agency_id AS agencyId, f.vehicle_id AS vehicleId, f.kind,
                     f.classification, f.cleared_at AS clearedAt,
                     (f.expires_at IS NOT NULL AND f.expires_at <= NOW(3)) AS expired
                FROM fpd_vehicle_flags f
               WHERE f.agency_id = ? AND f.id = ?]],
            { agencyId, hitId }
        )

        if not flag then return nil end

        local vehicle = db().single(
            [[SELECT v.id, v.agency_id AS agencyId, v.plate, v.classification
                FROM fpd_vehicles v
               WHERE v.agency_id = ? AND v.id = ?]],
            { agencyId, flag.vehicleId }
        )

        if not vehicle then return nil end

        return {
            record = vehicle, child = flag, recordType = 'vehicle',
            recordId = vehicle.id, kind = flag.kind,
        }
    end

    if hitType == 'firearm' then
        local firearm = db().single(
            [[SELECT f.id, f.agency_id AS agencyId, f.serial, f.status, f.classification
                FROM fpd_firearms f
               WHERE f.agency_id = ? AND f.id = ?]],
            { agencyId, hitId }
        )

        if not firearm then return nil end

        return {
            record = firearm, child = firearm, recordType = 'firearm',
            recordId = firearm.id, kind = firearm.status,
        }
    end

    local caution = db().single(
        [[SELECT c.id, c.agency_id AS agencyId, c.person_id AS personId, c.kind,
                 c.field_key AS fieldKey, c.classification, c.cancelled_at AS cancelledAt,
                 (c.expires_at IS NOT NULL AND c.expires_at <= NOW(3)) AS expired
            FROM fpd_person_cautions c
           WHERE c.agency_id = ? AND c.id = ?]],
        { agencyId, hitId }
    )

    if not caution then return nil end

    local person = db().single(
        [[SELECT p.id, p.agency_id AS agencyId, p.classification
            FROM fpd_persons p
           WHERE p.agency_id = ? AND p.id = ?]],
        { agencyId, caution.personId }
    )

    if not person then return nil end

    return {
        record = person, child = caution, recordType = 'person',
        recordId = person.id, kind = caution.kind,
    }
end

-- =============================================================================
-- The query log (7.2) and hit confirmations
-- =============================================================================

--- Records a query: who, what, when, from which access point (7.2).
---
--- Everything identifying comes from the session (invariant 1). `resultCount`
--- is the number of rows the reader was *allowed* to see, counted after access
--- filtering, so the log cannot be used to work out how many records were
--- hidden -- which would be the leak the filtering exists to prevent.
---
--- Nothing in the values list may be nil: a nil in an oxmysql values list
--- silently shortens it and shifts every placeholder after it, which here would
--- write an officer id into the query type. `officer_id`, `identifier` and
--- `access_point` are all legitimately absent -- a terminal session with no
--- character bound -- so a sentinel travels and MariaDB turns it back into NULL.
---
--- @return number the log row's id, which a confirmation is bound to
function Repo.logQuery(session, entry)
    return db().insert(
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

--- One of this session's own query rows, for binding a confirmation to it.
---
--- Scoped to the agency *and* to the Discord id that ran it. A confirmation
--- names the query that raised the lead, and the client supplies that id, so
--- without this check an officer could attach their confirmation to somebody
--- else's query and the log would say the wrong person acted on it
--- (invariant 1).
function Repo.ownQuery(session, queryId)
    return db().single(
        [[SELECT id, query_type AS queryType, created_at AS createdAt
            FROM fpd_query_log
           WHERE agency_id = ? AND discord_id = ? AND id = ?]],
        { session.agencyId, session.discordId, queryId }
    )
end

--- Has this query already answered this hit?
---
--- `uq_fpd_hotfile_confirmations_query` enforces it, and this asks first so the
--- officer is told "already confirmed" rather than shown an internal error.
function Repo.confirmationFor(agencyId, queryId, hitType, hitId)
    if queryId == nil then return nil end

    return db().single(
        [[SELECT id, outcome, confirmed_by AS confirmedBy, confirmed_at AS confirmedAt
            FROM fpd_hotfile_confirmations
           WHERE agency_id = ? AND query_id = ? AND hit_type = ? AND hit_id = ?]],
        { agencyId, queryId, hitType, hitId }
    )
end

--- Writes the confirmation (7.2).
---
--- Everything about *who* confirmed and *when* is the session's and the
--- database's (invariant 1): the officer sends the hit, the outcome and what
--- they confirmed it against, and nothing else.
---
--- @return number id
function Repo.confirmHit(session, input)
    return db().insert(
        [[INSERT INTO fpd_hotfile_confirmations
              (agency_id, query_id, hit_type, hit_id, hit_kind, record_type, record_id,
               outcome, case_number, detail, confirmed_by, officer_id)
          VALUES (?, NULLIF(?, 0), ?, ?, ?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, NULLIF(?, 0))]],
        {
            session.agencyId,
            input.queryId or 0,
            input.hitType,
            input.hitId,
            input.kind,
            input.recordType,
            input.recordId,
            input.outcome,
            input.caseNumber or '',
            input.detail or '',
            session.discordId,
            session.officerId or 0,
        }
    )
end

--- The query log, for `query.log.view` (7.2).
---
--- Scoped to the reader's own agency. `mine` is an officer asking what they
--- themselves have run; without it this is the misuse-investigation view, which
--- is why the permission is its own rather than part of `rms.person.view`.
---
--- Each row carries how many hits the query raised and how many of them were
--- confirmed afterwards. That pair is the point of the view: it is what
--- distinguishes an officer who acted on a confirmed record from one who acted
--- on a lead, months later, when somebody is asked about it (7.2).
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

    return db().query(
        ([[SELECT q.id, q.discord_id AS discordId, q.officer_id AS officerId,
                  q.query_type AS queryType, q.term, q.access_point AS accessPoint,
                  q.restricted, q.reason, q.case_number AS caseNumber,
                  q.result_count AS resultCount, q.hit_count AS hitCount,
                  q.created_at AS createdAt,
                  (SELECT COUNT(*) FROM fpd_hotfile_confirmations c
                    WHERE c.query_id = q.id) AS confirmationCount,
                  (SELECT COUNT(*) FROM fpd_hotfile_confirmations c
                    WHERE c.query_id = q.id AND c.outcome = 'confirmed') AS confirmedCount
             FROM fpd_query_log q
            WHERE %s
            ORDER BY q.created_at DESC, q.id DESC
            LIMIT ?]]):format(table.concat(where, ' AND ')),
        values
    )
end

FredPD.Repo.query = Repo
