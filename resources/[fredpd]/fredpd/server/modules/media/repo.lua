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

--- Attaches an uploaded photograph to a person, once.
---
--- The ledger row is flipped first and the photo row is written only when
--- that flip changed a row (`ROW_COUNT()`, held in a session variable): two
--- commits of the same ref racing each other wait on the ledger row's lock,
--- and the second finds it already committed and writes nothing.
---
--- @return number|nil the photo's id
function Repo.commitPhoto(mediaRef, agencyId, personId, kind, discordId)
    local committed = db().transaction({
        {
            query = [[UPDATE fpd_media SET status = 'committed', committed_at = CURRENT_TIMESTAMP(3)
                       WHERE media_ref = ? AND agency_id = ? AND status = 'pending']],
            values = { mediaRef, agencyId },
        },
        { query = 'SET @fpd_media_flipped = ROW_COUNT()' },
        {
            query = [[INSERT INTO fpd_person_photos (agency_id, person_id, kind, media_ref, taken_at, created_by)
                      SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP(3), ? FROM DUAL WHERE @fpd_media_flipped = 1]],
            values = { agencyId, personId, kind, mediaRef, discordId },
        },
    })

    if not committed then return nil end

    return db().scalar(
        'SELECT id FROM fpd_person_photos WHERE media_ref = ? AND agency_id = ? AND person_id = ? LIMIT 1',
        { mediaRef, agencyId, personId })
end

FredPD.Repo.media = Repo
