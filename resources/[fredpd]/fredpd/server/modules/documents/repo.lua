--- Printed documents SQL (0039). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

--- Writes a printed document and gives it its number, in one transaction with
--- the counter (13.1).
---
--- Read back as this officer's newest print of this record. That is only
--- unambiguous because `document.print` holds a lock per officer and record
--- around the call: a second caller of this function must hold the same lock,
--- or two prints could come back as one row.
---
--- @param document table { kind, subjectId, title, classification, payload (JSON string) }
--- @return table|nil { id, number }
function Repo.insert(document, session)
    local counters = FredPD.Core.counters
    local service = FredPD.Modules.documents
    local agency = FredPD.Core.agencies.get(session.agencyId)
    local prefix, width = service.numberPrefix(agency and agency.shortName or session.agencyId, counters.year())

    local values = counters.numberValues(prefix, width, 'document', session.agencyId)
    local base = #values
    values[base + 1] = session.agencyId
    values[base + 2] = document.kind
    values[base + 3] = document.subjectId
    values[base + 4] = document.title
    values[base + 5] = document.classification or 'internal'
    values[base + 6] = document.payload
    values[base + 7] = session.discordId

    local committed = db().transaction(counters.transaction('document', session.agencyId, nil, {
        {
            query = [[INSERT INTO fpd_documents
                          (number, agency_id, kind, subject_id, title, classification, payload, printed_by)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?, ?, ?)]],
            values = values,
        },
    }))

    if not committed then return nil end

    return db().single(
        [[SELECT id, number FROM fpd_documents
           WHERE agency_id = ? AND printed_by = ? AND kind = ? AND subject_id = ?
           ORDER BY id DESC LIMIT 1]],
        { session.agencyId, session.discordId, document.kind, document.subjectId })
end

function Repo.setMedia(id, agencyId, mediaRef)
    return db().execute('UPDATE fpd_documents SET media_ref = ? WHERE id = ? AND agency_id = ?',
        { mediaRef, id, agencyId })
end

--- A document whose copy could not be handed over is not a document anybody
--- holds: taken out again, the audit row saying it was attempted.
function Repo.remove(id, agencyId)
    return db().execute('DELETE FROM fpd_documents WHERE id = ? AND agency_id = ?', { id, agencyId })
end

FredPD.Repo.documents = Repo
