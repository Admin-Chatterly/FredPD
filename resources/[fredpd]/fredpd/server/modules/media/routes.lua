--- Photographs of people, through the gateway (spec 7.3, 7.9, 3.7; ADR-019).
---
--- An upload is three steps, and the server owns the first and the last:
---
---   1. **begin** (`person.photo.begin`, or `booking.mugshot.begin` at the
---      booking terminal): the person is read through the access check, the
---      gateway is asked for a single-use upload link for an image, and the
---      ledger (`fpd_media`, 0038) records who asked, for whom, and what kind.
---   2. The NUI puts the bytes at that link. The gateway re-encodes them as a
---      fresh JPEG or refuses them (`gateway/src/media/image.ts`).
---   3. **commit** (`person.photo.commit`): only a ref this server issued, to
---      this officer, still pending and inside its lifetime, whose file the
---      gateway actually holds, is attached to the person -- whose record is
---      read again, because access can change between the two.
---
--- The ref is never a URL (invariant 9). A reader gets a link, signed for a
--- few minutes, only on a photograph they may read (`persons/routes.lua`).

local route = FredPD.Core.route
local repo = FredPD.Repo.media
local service = FredPD.Modules.media

local function gateway()
    return FredPD.Bridge.gateway.service
end

--- The person, read through the access check, answered as the person routes
--- answer: a stub says restricted, anything else not found.
local function readablePerson(session, personId)
    local person, visibility = FredPD.Repo.persons.readPerson(session, personId)
    if person then return person end

    return nil, route.refuse(visibility == 'stub' and FredPD.ErrorCode.RESTRICTED or FredPD.ErrorCode.NOT_FOUND,
        { personId = 'unknown' })
end

local Api = {}

--- Step 1 for a person's photograph, for any route that has already decided
--- the officer may take this kind of it.
---
--- @return table|nil `{ mediaRef, uploadUrl, expiresAt }`
--- @return table|nil a refusal
function Api.beginPhoto(session, personId, kind)
    local _, refusal = readablePerson(session, personId)
    if refusal then return nil, refusal end

    if not gateway().isEnabled() then
        return nil, route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'gateway_off' })
    end

    local ok, token = gateway().requestUploadToken('image')
    if not ok or not service.isRef(token.mediaRef) or type(token.uploadUrl) ~= 'string' then
        return nil, route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'gateway_unavailable' })
    end

    repo.begin(token.mediaRef, session.agencyId, 'person_photo', personId, kind, session.discordId)

    return { mediaRef = token.mediaRef, uploadUrl = token.uploadUrl, expiresAt = token.expiresAt }
end

--- Whether this session could take a photograph for a record right now, for
--- the screen to offer the button. The routes decide for themselves.
function Api.canCapture(session)
    return gateway().isEnabled() and FredPD.Core.perms.satisfies(session.permissions, 'rms.person.photo.upload')
end

--- The signed links a reader gets for one photograph they may read.
function Api.links(mediaRef)
    return gateway().downloadUrl(mediaRef, false), gateway().downloadUrl(mediaRef, true)
end

FredPD.Modules.mediaApi = Api

route.define({
    name = 'person.photo.begin',
    perm = 'rms.person.photo.upload',
    schema = 'PersonPhotoBegin',
    writes = true,
    limit = { per = 10, window = 60 },
    handler = function(session, input)
        -- A mugshot is taken at the booking terminal, of the person standing
        -- there (`booking.mugshot.begin`), never from the record.
        if input.kind == 'mugshot' then
            return route.refuse(FredPD.ErrorCode.INVALID, { kind = 'not_allowed' })
        end

        local result, refusal = Api.beginPhoto(session, input.personId, input.kind)
        if not result then return refusal end

        return result
    end,
})

route.define({
    name = 'person.photo.commit',
    -- The baseline every officer who can read a record holds; the permission
    -- the photograph was begun under is asked again below.
    perm = 'rms.person.view',
    schema = 'PersonPhotoCommit',
    writes = true,
    limit = { per = 10, window = 60 },
    audit = 'person.photo.added',
    subjectType = 'person',
    auditDetail = function(input, result)
        return {
            mediaRef = input.mediaRef,
            kind = type(result) == 'table' and result.kind or nil,
            photoId = type(result) == 'table' and result.photoId or nil,
        }
    end,
    handler = function(session, input)
        if not service.isRef(input.mediaRef) then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { mediaRef = 'unknown' })
        end

        -- Only a ref this server issued, to this officer, still waiting.
        local pending = repo.pending(input.mediaRef, session.agencyId, session.discordId, service.PENDING_SECONDS)
        if not pending or pending.purpose ~= 'person_photo' then
            return route.refuse(FredPD.ErrorCode.NOT_FOUND, { mediaRef = 'unknown' })
        end

        if not FredPD.Core.perms.satisfies(session.permissions, service.permissionFor(pending.photoKind)) then
            return route.refuse(FredPD.ErrorCode.FORBIDDEN)
        end

        local _, refusal = readablePerson(session, pending.subjectId)
        if refusal then return refusal end

        -- The file itself: asking for a download token is how the gateway
        -- says whether it holds one (404 otherwise).
        local stored = gateway().requestDownloadToken(input.mediaRef)
        if not stored then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { mediaRef = 'not_uploaded' })
        end

        local photoId = repo.commitPhoto(
            input.mediaRef, session.agencyId, pending.subjectId, pending.photoKind, session.discordId)
        if not photoId then return route.refuse(FredPD.ErrorCode.CONFLICT) end

        return { id = pending.subjectId, photoId = photoId, kind = pending.photoKind }
    end,
})
