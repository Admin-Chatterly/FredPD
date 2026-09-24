--- The media ledger SQL (0038). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local function db()
    return FredPD.Core.db
end

--- Records an upload the server has just asked the gateway for.
function Repo.begin(mediaRef, agencyId, purpose, subjectId, photoKind, discordId)
    return db().insert(
        [[INSERT INTO fpd_media (media_ref, agency_id, purpose, subject_id, photo_kind, created_by)
          VALUES (?, ?, ?, ?, ?, ?)]],
        { mediaRef, agencyId, purpose, subjectId, photoKind, discordId })
end

--- A begun upload, still pending, begun by this officer in this agency, and
--- no older than `seconds`. Nothing else is ever committed.
function Repo.pending(mediaRef, agencyId, discordId, seconds)
    return db().single(
        [[SELECT media_ref AS mediaRef, purpose, subject_id AS subjectId, photo_kind AS photoKind
            FROM fpd_media
           WHERE media_ref = ? AND agency_id = ? AND created_by = ? AND status = 'pending'
             AND created_at >= DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? SECOND)]],
        { mediaRef, agencyId, discordId, seconds })
end

--- How many uploads this officer has begun and not committed, recently.
function Repo.pendingCount(agencyId, discordId, seconds)
    return db().scalar(
        [[SELECT COUNT(*) FROM fpd_media
           WHERE agency_id = ? AND created_by = ? AND status = 'pending'
             AND created_at >= DATE_SUB(CURRENT_TIMESTAMP(3), INTERVAL ? SECOND)]],
        { agencyId, discordId, seconds }) or 0
end

--- Marks a pending upload committed, once: the affected-row count is the
--- answer to "did this call commit it" (see `commitPhoto`).
--- @return boolean
function Repo.flip(mediaRef, agencyId)
    return db().execute(
        [[UPDATE fpd_media SET status = 'committed', committed_at = CURRENT_TIMESTAMP(3)
           WHERE media_ref = ? AND agency_id = ? AND status = 'pending']],
        { mediaRef, agencyId }) == 1
end

--- Puts a flip back when the record it was for could not be written.
function Repo.unflip(mediaRef, agencyId)
    return db().execute(
        [[UPDATE fpd_media SET status = 'pending', committed_at = NULL
           WHERE media_ref = ? AND agency_id = ? AND status = 'committed']],
        { mediaRef, agencyId })
end

--- Attaches an uploaded photograph to a person, once.
---
--- The ledger row is flipped on its own first, and its affected-row count is
--- the one answer to "did this call commit it": two commits of the same ref
--- racing each other wait on the row's lock, and the second changes nothing
--- and is refused -- rather than finding the first one's photo and reporting
--- it as its own. A photo row that then fails to write puts the flip back.
---
--- @return number|nil the photo's id, nil when another commit got there first
function Repo.commitPhoto(mediaRef, agencyId, personId, kind, discordId)
    local flipped = db().execute(
        [[UPDATE fpd_media SET status = 'committed', committed_at = CURRENT_TIMESTAMP(3)
           WHERE media_ref = ? AND agency_id = ? AND status = 'pending']],
        { mediaRef, agencyId })
    if flipped ~= 1 then return nil end

    local id = db().insert(
        [[INSERT INTO fpd_person_photos (agency_id, person_id, kind, media_ref, taken_at, created_by)
          VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP(3), ?)]],
        { agencyId, personId, kind, mediaRef, discordId })

    if not id then
        db().execute(
            [[UPDATE fpd_media SET status = 'pending', committed_at = NULL
               WHERE media_ref = ? AND agency_id = ? AND status = 'committed']],
            { mediaRef, agencyId })
        return nil
    end

    return id
end

FredPD.Repo.media = Repo
