--- Intelligence SQL (spec 10). Parameterised only (invariant 8).
---
--- MariaDB has no LATERAL join, so PD-Span's overview views are rebuilt as
--- correlated sub-selects. Detail screens fetch their sections separately
--- rather than aggregating into JSON in one query: several small indexed reads
--- beat one wide one, and each section is then reusable on its own.
---
--- Every query is scoped by `agency_id`. The scoping is here and in the
--- service, never in the input the client sent (invariant 4).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

-- -----------------------------------------------------------------------------
-- Persons
-- -----------------------------------------------------------------------------

local PERSON_COLUMNS <const> = [[
    p.id, p.name, p.alias, p.description, p.status, p.photo_path AS photoPath,
    p.classification, p.version, p.created_by AS createdBy,
    p.created_at AS createdAt, p.updated_at AS updatedAt
]]

--- The people list, with the counts the list page shows.
---
--- `search`, `status` and `tag` are optional. The tag filter goes through notes,
--- because tags live on intelligence rather than on people (spec 10).
function Repo.listPersons(agencyId, filter)
    local where = { 'p.agency_id = ?' }
    local values = { agencyId }

    if filter.search then
        where[#where + 1] = 'p.search_text LIKE ?'
        values[#values + 1] = '%' .. filter.search .. '%'
    end

    if filter.status then
        where[#where + 1] = 'p.status = ?'
        values[#values + 1] = filter.status
    end

    if filter.tag then
        where[#where + 1] = [[EXISTS (
            SELECT 1 FROM fpd_intel_notes n
              JOIN fpd_intel_note_tags t ON t.note_id = n.id
             WHERE n.person_id = p.id AND t.tag = ?)]]
        values[#values + 1] = filter.tag
    end

    values[#values + 1] = filter.limit or 100

    return db().query(([[
        SELECT %s,
               (SELECT COUNT(*) FROM fpd_intel_notes n WHERE n.person_id = p.id) AS noteCount,
               (SELECT MAX(n.created_at) FROM fpd_intel_notes n WHERE n.person_id = p.id) AS lastNoteAt,
               (SELECT GROUP_CONCAT(v.plate ORDER BY v.plate SEPARATOR ',')
                  FROM fpd_intel_vehicles v
                 WHERE v.person_id = p.id AND v.plate IS NOT NULL) AS plates
          FROM fpd_intel_persons p
         WHERE %s
         ORDER BY p.updated_at DESC
         LIMIT ?]]):format(PERSON_COLUMNS, table.concat(where, ' AND ')), values)
end

function Repo.getPerson(agencyId, id)
    return db().single(([[
        SELECT %s FROM fpd_intel_persons p
         WHERE p.agency_id = ? AND p.id = ?]]):format(PERSON_COLUMNS), { agencyId, id })
end

function Repo.createPerson(agencyId, input, discordId)
    return db().insert(
        [[INSERT INTO fpd_intel_persons
              (agency_id, name, alias, description, status, classification, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?)]],
        {
            agencyId, input.name, input.alias, input.description,
            input.status or 'unknown', input.classification or 'internal', discordId,
        }
    )
end

--- Updates only the fields present, and bumps `version`.
---
--- The version is checked in the WHERE clause, so a stale edit affects no rows
--- and the caller can report a conflict rather than silently overwriting
--- somebody else's change (spec 3.5, `conflict`).
function Repo.updatePerson(agencyId, id, expectedVersion, input)
    local columns = {
        name = 'name', alias = 'alias', description = 'description',
        status = 'status', classification = 'classification', photoPath = 'photo_path',
    }
    local order = { 'name', 'alias', 'description', 'status', 'classification', 'photoPath' }

    local sets, values = {}, {}

    for index = 1, #order do
        local field = order[index]
        if input[field] ~= nil then
            sets[#sets + 1] = ('`%s` = ?'):format(columns[field])
            values[#values + 1] = input[field] ~= '' and input[field] or nil
        end
    end

    if #sets == 0 then return 0 end

    sets[#sets + 1] = '`version` = `version` + 1'
    values[#values + 1] = agencyId
    values[#values + 1] = id
    values[#values + 1] = expectedVersion

    return db().execute(
        ('UPDATE fpd_intel_persons SET %s WHERE agency_id = ? AND id = ? AND version = ?')
            :format(table.concat(sets, ', ')),
        values
    )
end

function Repo.deletePerson(agencyId, id)
    return db().execute('DELETE FROM fpd_intel_persons WHERE agency_id = ? AND id = ?', { agencyId, id })
end

-- -----------------------------------------------------------------------------
-- Organisations
-- -----------------------------------------------------------------------------

local ORG_COLUMNS <const> = [[
    o.id, o.name, o.type, o.territory, o.status, o.notes,
    o.classification, o.version, o.created_by AS createdBy,
    o.created_at AS createdAt, o.updated_at AS updatedAt
]]

function Repo.listOrgs(agencyId, filter)
    local where = { 'o.agency_id = ?' }
    local values = { agencyId }

    if filter.search then
        where[#where + 1] = 'o.search_text LIKE ?'
        values[#values + 1] = '%' .. filter.search .. '%'
    end

    if filter.tag then
        where[#where + 1] = [[EXISTS (
            SELECT 1 FROM fpd_intel_notes n
              JOIN fpd_intel_note_tags t ON t.note_id = n.id
             WHERE n.org_id = o.id AND t.tag = ?)]]
        values[#values + 1] = filter.tag
    end

    values[#values + 1] = filter.limit or 100

    return db().query(([[
        SELECT %s,
               (SELECT COUNT(*) FROM fpd_intel_memberships m WHERE m.org_id = o.id) AS memberCount,
               (SELECT COUNT(*) FROM fpd_intel_memberships m
                 WHERE m.org_id = o.id AND m.is_confirmed = 1) AS confirmedCount,
               (SELECT COUNT(*) FROM fpd_intel_notes n WHERE n.org_id = o.id) AS noteCount
          FROM fpd_intel_orgs o
         WHERE %s
         ORDER BY o.updated_at DESC
         LIMIT ?]]):format(ORG_COLUMNS, table.concat(where, ' AND ')), values)
end

function Repo.getOrg(agencyId, id)
    return db().single(([[
        SELECT %s FROM fpd_intel_orgs o
         WHERE o.agency_id = ? AND o.id = ?]]):format(ORG_COLUMNS), { agencyId, id })
end

function Repo.createOrg(agencyId, input, discordId)
    return db().insert(
        [[INSERT INTO fpd_intel_orgs
              (agency_id, name, type, territory, status, notes, classification, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            agencyId, input.name, input.type, input.territory,
            input.status or 'active', input.notes, input.classification or 'internal', discordId,
        }
    )
end

function Repo.updateOrg(agencyId, id, expectedVersion, input)
    local columns = {
        name = 'name', type = 'type', territory = 'territory',
        status = 'status', notes = 'notes', classification = 'classification',
    }
    local order = { 'name', 'type', 'territory', 'status', 'notes', 'classification' }

    local sets, values = {}, {}

    for index = 1, #order do
        local field = order[index]
        if input[field] ~= nil then
            sets[#sets + 1] = ('`%s` = ?'):format(columns[field])
            values[#values + 1] = input[field] ~= '' and input[field] or nil
        end
    end

    if #sets == 0 then return 0 end

    sets[#sets + 1] = '`version` = `version` + 1'
    values[#values + 1] = agencyId
    values[#values + 1] = id
    values[#values + 1] = expectedVersion

    return db().execute(
        ('UPDATE fpd_intel_orgs SET %s WHERE agency_id = ? AND id = ? AND version = ?')
            :format(table.concat(sets, ', ')),
        values
    )
end

function Repo.deleteOrg(agencyId, id)
    return db().execute('DELETE FROM fpd_intel_orgs WHERE agency_id = ? AND id = ?', { agencyId, id })
end

-- -----------------------------------------------------------------------------
-- The intelligence log
-- -----------------------------------------------------------------------------

local NOTE_COLUMNS <const> = [[
    n.id, n.person_id AS personId, n.org_id AS orgId, n.case_id AS caseId,
    n.body, n.source, n.confidence,
    n.source_reliability AS sourceReliability, n.info_credibility AS infoCredibility,
    n.classification, n.version, n.created_by AS createdBy,
    n.created_at AS createdAt, n.updated_at AS updatedAt
]]

--- Attaches each note's tags in one extra query rather than one per note.
local function withTags(rows)
    if #rows == 0 then return rows end

    local ids, byId = {}, {}
    for index = 1, #rows do
        rows[index].tags = {}
        ids[#ids + 1] = '?'
        byId[rows[index].id] = rows[index]
    end

    local values = {}
    for index = 1, #rows do values[index] = rows[index].id end

    local tagRows = db().query(
        ('SELECT note_id AS noteId, tag FROM fpd_intel_note_tags WHERE note_id IN (%s) ORDER BY tag')
            :format(table.concat(ids, ',')),
        values
    )

    for index = 1, #tagRows do
        local note = byId[tagRows[index].noteId]
        if note then note.tags[#note.tags + 1] = tagRows[index].tag end
    end

    return rows
end

--- The intel log. Every filter is optional; combining them narrows.
function Repo.listNotes(agencyId, filter)
    local where = { 'n.agency_id = ?' }
    local values = { agencyId }

    if filter.personId then
        where[#where + 1] = 'n.person_id = ?'
        values[#values + 1] = filter.personId
    end

    if filter.orgId then
        where[#where + 1] = 'n.org_id = ?'
        values[#values + 1] = filter.orgId
    end

    if filter.caseId then
        where[#where + 1] = 'n.case_id = ?'
        values[#values + 1] = filter.caseId
    end

    if filter.source then
        where[#where + 1] = 'n.source = ?'
        values[#values + 1] = filter.source
    end

    if filter.confidence then
        where[#where + 1] = 'n.confidence = ?'
        values[#values + 1] = filter.confidence
    end

    if filter.search then
        where[#where + 1] = 'LOWER(n.body) LIKE ?'
        values[#values + 1] = '%' .. filter.search .. '%'
    end

    if filter.tag then
        where[#where + 1] =
            'EXISTS (SELECT 1 FROM fpd_intel_note_tags t WHERE t.note_id = n.id AND t.tag = ?)'
        values[#values + 1] = filter.tag
    end

    values[#values + 1] = filter.limit or 100

    return withTags(db().query(([[
        SELECT %s FROM fpd_intel_notes n
         WHERE %s
         ORDER BY n.created_at DESC
         LIMIT ?]]):format(NOTE_COLUMNS, table.concat(where, ' AND ')), values))
end

function Repo.getNote(agencyId, id)
    local rows = withTags(db().query(([[
        SELECT %s FROM fpd_intel_notes n
         WHERE n.agency_id = ? AND n.id = ?]]):format(NOTE_COLUMNS), { agencyId, id }))

    return rows[1]
end

--- Writes the note and its tags together, so a failure leaves neither.
function Repo.createNote(agencyId, input, tags, discordId)
    local id = db().insert(
        [[INSERT INTO fpd_intel_notes
              (agency_id, person_id, org_id, case_id, body, source, confidence,
               source_reliability, info_credibility, classification, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            agencyId, input.personId, input.orgId, input.caseId,
            input.body, input.source, input.confidence or 'medium',
            input.sourceReliability, input.infoCredibility,
            input.classification or 'internal', discordId,
        }
    )

    Repo.setNoteTags(id, tags)
    return id
end

--- Replaces a note's tags wholesale. Simpler than diffing, and a note has at
--- most a dozen.
function Repo.setNoteTags(noteId, tags)
    db().execute('DELETE FROM fpd_intel_note_tags WHERE note_id = ?', { noteId })

    for index = 1, #tags do
        db().execute(
            'INSERT IGNORE INTO fpd_intel_note_tags (note_id, tag) VALUES (?, ?)',
            { noteId, tags[index] }
        )
    end
end

function Repo.updateNote(agencyId, id, expectedVersion, input)
    local columns = {
        body = 'body', source = 'source', confidence = 'confidence',
        classification = 'classification',
        sourceReliability = 'source_reliability', infoCredibility = 'info_credibility',
        personId = 'person_id', orgId = 'org_id', caseId = 'case_id',
    }
    local order = {
        'body', 'source', 'confidence', 'classification',
        'sourceReliability', 'infoCredibility', 'personId', 'orgId', 'caseId',
    }

    local sets, values = {}, {}

    for index = 1, #order do
        local field = order[index]
        if input[field] ~= nil then
            sets[#sets + 1] = ('`%s` = ?'):format(columns[field])
            values[#values + 1] = input[field] ~= '' and input[field] or nil
        end
    end

    if #sets == 0 then return 0 end

    sets[#sets + 1] = '`version` = `version` + 1'
    values[#values + 1] = agencyId
    values[#values + 1] = id
    values[#values + 1] = expectedVersion

    return db().execute(
        ('UPDATE fpd_intel_notes SET %s WHERE agency_id = ? AND id = ? AND version = ?')
            :format(table.concat(sets, ', ')),
        values
    )
end

function Repo.deleteNote(agencyId, id)
    return db().execute('DELETE FROM fpd_intel_notes WHERE agency_id = ? AND id = ?', { agencyId, id })
end

--- PD-Span's `distinct_tags()`: every tag in use, most used first.
function Repo.tags(agencyId)
    return db().query(
        [[SELECT t.tag, COUNT(*) AS uses
            FROM fpd_intel_note_tags t
            JOIN fpd_intel_notes n ON n.id = t.note_id
           WHERE n.agency_id = ?
           GROUP BY t.tag
           ORDER BY uses DESC, t.tag
           LIMIT 100]],
        { agencyId }
    )
end

-- -----------------------------------------------------------------------------
-- Vehicles
-- -----------------------------------------------------------------------------

function Repo.vehiclesForPerson(personId)
    return db().query(
        [[SELECT id, plate, model, color, notes, person_id AS personId, version
            FROM fpd_intel_vehicles WHERE person_id = ? ORDER BY plate]],
        { personId }
    )
end

function Repo.createVehicle(agencyId, input, discordId)
    return db().insert(
        [[INSERT INTO fpd_intel_vehicles (agency_id, person_id, plate, model, color, notes, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?)]],
        { agencyId, input.personId, input.plate, input.model, input.color, input.notes, discordId }
    )
end

function Repo.deleteVehicle(agencyId, id)
    return db().execute('DELETE FROM fpd_intel_vehicles WHERE agency_id = ? AND id = ?', { agencyId, id })
end

-- -----------------------------------------------------------------------------
-- Cases
-- -----------------------------------------------------------------------------

local CASE_COLUMNS <const> = [[
    c.id, c.title, c.description, c.status, c.classification, c.version,
    c.created_by AS createdBy, c.created_at AS createdAt, c.updated_at AS updatedAt
]]

function Repo.listCases(agencyId, filter)
    local where = { 'c.agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        where[#where + 1] = 'c.status = ?'
        values[#values + 1] = filter.status
    end

    if filter.search then
        where[#where + 1] = '(LOWER(c.title) LIKE ? OR LOWER(c.description) LIKE ?)'
        values[#values + 1] = '%' .. filter.search .. '%'
        values[#values + 1] = '%' .. filter.search .. '%'
    end

    values[#values + 1] = filter.limit or 100

    return db().query(([[
        SELECT %s,
               (SELECT COUNT(*) FROM fpd_intel_case_links l
                 WHERE l.case_id = c.id AND l.person_id IS NOT NULL) AS personCount,
               (SELECT COUNT(*) FROM fpd_intel_case_links l
                 WHERE l.case_id = c.id AND l.org_id IS NOT NULL) AS orgCount,
               (SELECT COUNT(*) FROM fpd_intel_notes n WHERE n.case_id = c.id) AS noteCount
          FROM fpd_intel_cases c
         WHERE %s
         ORDER BY c.updated_at DESC
         LIMIT ?]]):format(CASE_COLUMNS, table.concat(where, ' AND ')), values)
end

function Repo.getCase(agencyId, id)
    return db().single(([[
        SELECT %s FROM fpd_intel_cases c
         WHERE c.agency_id = ? AND c.id = ?]]):format(CASE_COLUMNS), { agencyId, id })
end

function Repo.createCase(agencyId, input, discordId)
    return db().insert(
        [[INSERT INTO fpd_intel_cases (agency_id, title, description, status, classification, created_by)
          VALUES (?, ?, ?, ?, ?, ?)]],
        {
            agencyId, input.title, input.description, input.status or 'open',
            input.classification or 'internal', discordId,
        }
    )
end

function Repo.updateCase(agencyId, id, expectedVersion, input)
    local columns = {
        title = 'title', description = 'description',
        status = 'status', classification = 'classification',
    }
    local order = { 'title', 'description', 'status', 'classification' }

    local sets, values = {}, {}

    for index = 1, #order do
        local field = order[index]
        if input[field] ~= nil then
            sets[#sets + 1] = ('`%s` = ?'):format(columns[field])
            values[#values + 1] = input[field] ~= '' and input[field] or nil
        end
    end

    if #sets == 0 then return 0 end

    sets[#sets + 1] = '`version` = `version` + 1'
    values[#values + 1] = agencyId
    values[#values + 1] = id
    values[#values + 1] = expectedVersion

    return db().execute(
        ('UPDATE fpd_intel_cases SET %s WHERE agency_id = ? AND id = ? AND version = ?')
            :format(table.concat(sets, ', ')),
        values
    )
end

function Repo.deleteCase(agencyId, id)
    return db().execute('DELETE FROM fpd_intel_cases WHERE agency_id = ? AND id = ?', { agencyId, id })
end

--- Everyone and everything linked to a case, in one list the board can draw.
function Repo.caseLinks(caseId)
    return db().query(
        [[SELECT l.id, l.case_id AS caseId, l.person_id AS personId, l.org_id AS orgId,
                 l.role, l.target_kind AS targetKind,
                 p.name AS personName, p.alias AS personAlias, p.status AS personStatus,
                 o.name AS orgName, o.type AS orgType
            FROM fpd_intel_case_links l
            LEFT JOIN fpd_intel_persons p ON p.id = l.person_id
            LEFT JOIN fpd_intel_orgs o ON o.id = l.org_id
           WHERE l.case_id = ?
           ORDER BY l.target_kind, l.id]],
        { caseId }
    )
end

function Repo.addCaseLink(input, discordId)
    return db().insert(
        [[INSERT INTO fpd_intel_case_links (case_id, person_id, org_id, role, created_by)
          VALUES (?, ?, ?, ?, ?)]],
        { input.caseId, input.personId, input.orgId, input.role, discordId }
    )
end

function Repo.removeCaseLink(id)
    return db().execute('DELETE FROM fpd_intel_case_links WHERE id = ?', { id })
end

function Repo.caseLinksForPerson(personId)
    return db().query(
        [[SELECT l.id, l.case_id AS caseId, l.role, c.title, c.status
            FROM fpd_intel_case_links l
            JOIN fpd_intel_cases c ON c.id = l.case_id
           WHERE l.person_id = ?
           ORDER BY c.updated_at DESC]],
        { personId }
    )
end

-- -----------------------------------------------------------------------------
-- Memberships and associates
-- -----------------------------------------------------------------------------

function Repo.membershipsForPerson(personId)
    return db().query(
        [[SELECT m.org_id AS orgId, m.role, m.is_confirmed AS isConfirmed,
                 o.name AS orgName, o.type AS orgType, o.status AS orgStatus
            FROM fpd_intel_memberships m
            JOIN fpd_intel_orgs o ON o.id = m.org_id
           WHERE m.person_id = ?
           ORDER BY o.name]],
        { personId }
    )
end

function Repo.rosterForOrg(orgId)
    return db().query(
        [[SELECT m.person_id AS personId, m.role, m.is_confirmed AS isConfirmed,
                 p.name, p.alias, p.status
            FROM fpd_intel_memberships m
            JOIN fpd_intel_persons p ON p.id = m.person_id
           WHERE m.org_id = ?
           ORDER BY m.is_confirmed DESC, p.name, p.alias]],
        { orgId }
    )
end

function Repo.setMembership(input, discordId)
    return db().execute(
        [[INSERT INTO fpd_intel_memberships (person_id, org_id, role, is_confirmed, created_by)
          VALUES (?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE role = VALUES(role), is_confirmed = VALUES(is_confirmed)]],
        { input.personId, input.orgId, input.role, input.isConfirmed and 1 or 0, discordId }
    )
end

function Repo.removeMembership(personId, orgId)
    return db().execute(
        'DELETE FROM fpd_intel_memberships WHERE person_id = ? AND org_id = ?',
        { personId, orgId }
    )
end

--- Associates of a person, from either side of the stored pair.
function Repo.associatesForPerson(personId)
    return db().query(
        [[SELECT other.id AS personId, other.name, other.alias, other.status,
                 a.relationship, a.is_confirmed AS isConfirmed
            FROM fpd_intel_associates a
            JOIN fpd_intel_persons other
              ON other.id = IF(a.person_id = ?, a.associate_id, a.person_id)
           WHERE a.person_id = ? OR a.associate_id = ?
           ORDER BY other.name, other.alias]],
        { personId, personId, personId }
    )
end

--- `low` and `high` come from `service.orderPair`, satisfying the table's CHECK.
function Repo.setAssociate(low, high, relationship, isConfirmed, discordId)
    return db().execute(
        [[INSERT INTO fpd_intel_associates (person_id, associate_id, relationship, is_confirmed, created_by)
          VALUES (?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE relationship = VALUES(relationship), is_confirmed = VALUES(is_confirmed)]],
        { low, high, relationship, isConfirmed and 1 or 0, discordId }
    )
end

function Repo.removeAssociate(low, high)
    return db().execute(
        'DELETE FROM fpd_intel_associates WHERE person_id = ? AND associate_id = ?',
        { low, high }
    )
end

-- -----------------------------------------------------------------------------
-- Evidence
-- -----------------------------------------------------------------------------

function Repo.evidenceFor(target, id)
    local column = ({ person = 'person_id', org = 'org_id', ['case'] = 'case_id' })[target]
    if not column then return {} end

    return db().query(
        ([[SELECT id, storage_path AS storagePath, url, caption,
                  created_by AS createdBy, created_at AS createdAt
             FROM fpd_intel_evidence
            WHERE %s = ?
            ORDER BY created_at DESC]]):format(column),
        { id }
    )
end

function Repo.addEvidence(agencyId, input, discordId)
    return db().insert(
        [[INSERT INTO fpd_intel_evidence
              (agency_id, person_id, org_id, case_id, storage_path, url, caption, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            agencyId, input.personId, input.orgId, input.caseId,
            input.storagePath, input.url, input.caption, discordId,
        }
    )
end

function Repo.deleteEvidence(agencyId, id)
    return db().execute('DELETE FROM fpd_intel_evidence WHERE agency_id = ? AND id = ?', { agencyId, id })
end

-- -----------------------------------------------------------------------------
-- Global search (PD-Span's `search_all`)
-- -----------------------------------------------------------------------------

--- One round trip across every kind, capped per kind so no single kind can
--- crowd out the others.
function Repo.search(agencyId, term, perType)
    local like = '%' .. term .. '%'

    return db().query(
        [[  (SELECT 'person' AS kind, p.id, p.name AS title, p.alias AS subtitle,
                    p.status, p.updated_at AS updatedAt
               FROM fpd_intel_persons p
              WHERE p.agency_id = ? AND p.search_text LIKE ?
              ORDER BY p.updated_at DESC LIMIT ?)
          UNION ALL
            (SELECT 'organization', o.id, o.name, o.territory, o.status, o.updated_at
               FROM fpd_intel_orgs o
              WHERE o.agency_id = ? AND o.search_text LIKE ?
              ORDER BY o.updated_at DESC LIMIT ?)
          UNION ALL
            (SELECT 'vehicle', v.id, v.plate, CONCAT_WS(' ', v.color, v.model), NULL, v.updated_at
               FROM fpd_intel_vehicles v
              WHERE v.agency_id = ? AND v.search_text LIKE ?
              ORDER BY v.updated_at DESC LIMIT ?)
          UNION ALL
            (SELECT 'note', n.id, LEFT(n.body, 160), NULL, n.confidence, n.created_at
               FROM fpd_intel_notes n
              WHERE n.agency_id = ? AND LOWER(n.body) LIKE ?
              ORDER BY n.created_at DESC LIMIT ?)
          UNION ALL
            (SELECT 'case', c.id, c.title, c.description, c.status, c.updated_at
               FROM fpd_intel_cases c
              WHERE c.agency_id = ? AND (LOWER(c.title) LIKE ? OR LOWER(c.description) LIKE ?)
              ORDER BY c.updated_at DESC LIMIT ?)]],
        {
            agencyId, like, perType,
            agencyId, like, perType,
            agencyId, like, perType,
            agencyId, like, perType,
            agencyId, like, like, perType,
        }
    )
end

-- -----------------------------------------------------------------------------
-- Merging a duplicate person (PD-Span's `merge_people`)
-- -----------------------------------------------------------------------------

--- Moves everything attached to `dropId` onto `keepId`, then deletes the
--- duplicate. One transaction: a half-finished merge would scatter one person's
--- intelligence across two records with no way to tell which was which.
---
--- @param merged table from `service.mergePlan`
--- @return boolean committed
function Repo.mergePersons(agencyId, keepId, dropId, merged)
    return db().transaction({
        {
            query = [[UPDATE fpd_intel_persons
                         SET name = ?, alias = ?, description = ?, photo_path = ?, status = ?,
                             version = version + 1
                       WHERE agency_id = ? AND id = ?]],
            values = {
                merged.name, merged.alias, merged.description, merged.photoPath, merged.status,
                agencyId, keepId,
            },
        },

        -- Straight re-points: these have no uniqueness to collide on.
        { query = 'UPDATE fpd_intel_notes SET person_id = ? WHERE person_id = ?', values = { keepId, dropId } },
        { query = 'UPDATE fpd_intel_vehicles SET person_id = ? WHERE person_id = ?', values = { keepId, dropId } },
        { query = 'UPDATE fpd_intel_evidence SET person_id = ? WHERE person_id = ?', values = { keepId, dropId } },

        -- Memberships: fold the flags where both belonged to the same
        -- organisation, then drop the duplicate rows before re-pointing the rest.
        {
            query = [[UPDATE fpd_intel_memberships k
                        JOIN fpd_intel_memberships d
                          ON d.person_id = ? AND d.org_id = k.org_id
                         SET k.is_confirmed = GREATEST(k.is_confirmed, d.is_confirmed),
                             k.role = COALESCE(k.role, d.role)
                       WHERE k.person_id = ?]],
            values = { dropId, keepId },
        },
        {
            query = [[DELETE FROM fpd_intel_memberships
                       WHERE person_id = ?
                         AND org_id IN (SELECT org_id FROM (
                               SELECT org_id FROM fpd_intel_memberships WHERE person_id = ?
                             ) AS kept)]],
            values = { dropId, keepId },
        },
        {
            query = 'UPDATE fpd_intel_memberships SET person_id = ? WHERE person_id = ?',
            values = { keepId, dropId },
        },

        -- Case links: drop the ones that would duplicate, move the rest.
        {
            query = [[DELETE FROM fpd_intel_case_links
                       WHERE person_id = ?
                         AND case_id IN (SELECT case_id FROM (
                               SELECT case_id FROM fpd_intel_case_links WHERE person_id = ?
                             ) AS kept)]],
            values = { dropId, keepId },
        },
        {
            query = 'UPDATE fpd_intel_case_links SET person_id = ? WHERE person_id = ?',
            values = { keepId, dropId },
        },

        -- Associates: re-point onto the kept record, in pair order, skipping a
        -- link to itself. Anything left pointing at the duplicate goes with it.
        {
            query = [[INSERT IGNORE INTO fpd_intel_associates
                          (person_id, associate_id, relationship, is_confirmed, created_by)
                      SELECT LEAST(?, other), GREATEST(?, other), relationship, is_confirmed, created_by
                        FROM (
                          SELECT IF(person_id = ?, associate_id, person_id) AS other,
                                 relationship, is_confirmed, created_by
                            FROM fpd_intel_associates
                           WHERE person_id = ? OR associate_id = ?
                        ) AS moved
                       WHERE other <> ?]],
            values = { keepId, keepId, dropId, dropId, dropId, keepId },
        },
        {
            query = 'DELETE FROM fpd_intel_associates WHERE person_id = ? OR associate_id = ?',
            values = { dropId, dropId },
        },

        { query = 'DELETE FROM fpd_intel_persons WHERE agency_id = ? AND id = ?', values = { agencyId, dropId } },
    })
end

FredPD.Repo.intel = Repo
