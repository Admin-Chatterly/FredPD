--- Booking routes (spec 7.9): cell assignment and the property inventory,
--- where the gripande/anhållande/häktning chain `frihet` records stops.
---
--- This module only ever *reads* `frihet` -- through `FredPD.Repo.frihet` and
--- `FredPD.Modules.frihet`, never `frihet`'s own repo internals -- the same
--- boundary every other module in this suite keeps (spec 3.4: a module calls
--- another module through its `service.lua`, and reads its rows through its
--- `repo.lua`, never reaching past either).
---
--- `booking.book` only proceeds when `Frihet.isOpen` says the chain is still
--- live (`status ~= 'frigiven'`): a person may be booked while gripen,
--- anhållen, framställd or häktad -- every stage short of release -- and never
--- once `frihet.frigiv` has already let them go. That is the same predicate
--- `frihet/service.lua` uses for its own "still being held" question
--- (`Frihet.isOpen`), read here rather than re-derived, so this module cannot
--- drift from what `frihet` itself considers "in custody".

local route = FredPD.Core.route
local repo = FredPD.Repo.booking
local service = FredPD.Modules.booking
local access = FredPD.Repo.access
local frihetService = FredPD.Modules.frihet
local personsRepo = FredPD.Repo.persons

--- `evidence/repo.lua` loads after this file (fxmanifest.lua), so `FredPD.
--- Repo.evidence` is read here at call time rather than captured as a
--- module-load local -- the same reason `config` below is read inside the
--- handler rather than at the top of the file.

--- The access record type. `arrest` is already allowlisted in
--- `access/repo.lua`'s `RECORD_TYPES`.
local BOOKING <const> = 'arrest'

local function readable(session, id)
    local row = repo.byId(id, session.agencyId)
    if not row then return nil, route.refuse(FredPD.ErrorCode.NOT_FOUND) end

    local allowed = access.read(session, BOOKING, row)
    if not allowed then return nil, route.refuse(FredPD.ErrorCode.RESTRICTED) end

    return allowed
end

--- Where a player actually is, according to the server -- never a coordinate
--- from the call. Mirrors `forensics/routes.lua`'s own `positionOf`; not
--- shared with it, the same as neither shares it with `forensics/gsr.lua`,
--- because each is four lines of natives with no state to hold in common.
local function positionOf(src)
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end

    return GetEntityCoords(ped)
end

-- -----------------------------------------------------------------------------
-- Reads
-- -----------------------------------------------------------------------------

route.define({
    name = 'booking.list',
    perm = 'booking.view',
    schema = 'BookingList',
    handler = function(session, input)
        local found = repo.list(session.agencyId, { open = input.open }, input.limit or 50)

        return { bookings = access.filterSearch(session, BOOKING, found) }
    end,
})

route.define({
    name = 'booking.get',
    perm = 'booking.view',
    schema = 'BookingGet',
    handler = function(session, input)
        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        row.property = repo.propertyFor(row.id, session.agencyId)

        return { booking = row }
    end,
})

-- -----------------------------------------------------------------------------
-- Intake
-- -----------------------------------------------------------------------------

route.define({
    name = 'booking.book',
    perm = 'booking.intake',
    schema = 'BookingBook',
    writes = true,
    sensitive = true,
    audit = 'booking.booked',
    subjectType = BOOKING,
    auditDetail = function(input) return { frihetId = input.frihetId } end,
    handler = function(session, input)
        local err, fields = service.validateBook(input)
        if err then return route.refuse(err, fields) end

        local frihet = FredPD.Repo.frihet.byId(input.frihetId, session.agencyId)
        if not frihet then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { frihetId = 'unknown' }) end

        if repo.byFrihetId(frihet.id, session.agencyId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { frihetId = 'already_booked' })
        end

        -- Only a chain the frihet module itself still considers "in custody"
        -- may be booked -- see the module header for why this reads
        -- `Frihet.isOpen` rather than re-deriving the check.
        if not frihetService.isOpen(frihet) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { frihetId = 'not_in_custody' })
        end

        -- The person id is the chain's own, never the client's (invariant 1).
        input.personId = frihet.personId

        local row = repo.book(input, session)
        if not row then return route.refuse(FredPD.ErrorCode.INTERNAL) end

        -- A server-local event, never a broadcast (invariant 5): the contract
        -- an external jail-bridge resource listens for, per spec 14, so it
        -- can hand out a sentence. Nothing in this suite listens for it yet.
        TriggerEvent('fredpd:arrestBooked', {
            personId = row.personId,
            agencyId = session.agencyId,
            discordId = session.discordId,
            frihetId = input.frihetId,
            bookingId = row.id,
        })

        return { id = row.id, number = row.number, booking = row }
    end,
})

-- -----------------------------------------------------------------------------
-- Ten-print capture (8.8's "ten-print cards from booking")
-- -----------------------------------------------------------------------------

route.define({
    name = 'booking.tenPrint.capture',
    perm = 'booking.intake',
    schema = 'BookingTenPrintCapture',
    -- Spec 1.4: ten-print capture is limited to the booking terminal, the
    -- same access-point pattern `evidence.intake` (`property_terminal`) and
    -- `lab.analysis.start` (`lab_terminal`) already use -- checked here, not
    -- taken on the client's word for which placement it is using (3.10).
    context = { onDuty = true, accessPoint = 'booking_terminal' },
    writes = true,
    sensitive = true,
    audit = 'booking.tenPrint.captured',
    subjectType = BOOKING,
    auditDetail = function(input) return { number = input.number } end,
    handler = function(session, input)
        local booking = repo.byNumber(input.number, session.agencyId)
        if not booking then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { number = 'unknown' }) end

        if booking.releasedAt then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { number = 'already_released' })
        end

        -- The officer's own position and the target's are both read off the
        -- server's own peds, never off the call (8.3.2) -- the same range
        -- check `forensics.evidence.collect`'s swab path uses for a
        -- `targetId`, at the same distance (`collectRange`): standing at the
        -- terminal with the arrestee is what "capture" means here, not a
        -- claim about who the arrestee is.
        local at = positionOf(input.targetId)
        if not at then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { targetId = 'unreachable' }) end

        local here = positionOf(session.src)
        if not here then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local range = FredPD.Forensics.grid.settings().collectRange
        local dx, dy, dz = at.x - here.x, at.y - here.y, at.z - here.z

        if (dx * dx + dy * dy + dz * dz) > (range * range) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'out_of_range' })
        end

        local character = FredPD.Bridge.framework.getCharacter(input.targetId)
        local identifier = character and character.identifier or nil
        if not identifier then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'no_character' })
        end

        -- A ten-print names a person, and this booking already names one
        -- (`frihet.personId`, carried onto the booking at `booking.book`
        -- time, never the client's). A different live identifier at the
        -- terminal than the one already on this person's file is a
        -- conflict, never a silent takeover of somebody else's identity
        -- (`Repo.identifierConflict`'s own header explains why).
        if personsRepo.identifierConflict(session.agencyId, booking.personId, identifier) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'identity_mismatch' })
        end

        -- Filling this in is what "identified" (0005's own comment on
        -- `fpd_persons.identifier`) means; a no-op once it already matches.
        --
        -- `identifierConflict` above is not proof by itself: `await`ing this
        -- statement yields, so a second call for the same booking (two
        -- officers, or two different nearby targets resolved a moment apart)
        -- can read `identifier IS NULL` at the same time this one did, pass
        -- the same check, and then race on the write. Only one `UPDATE`
        -- actually sets it; the loser matches zero rows and, unchecked,
        -- would carry straight on to file a print under the wrong
        -- identifier while still reporting success -- exactly the silent
        -- takeover `identifierConflict` exists to refuse. Re-reading after a
        -- zero-row update is the only way to tell "lost the race to a
        -- different identifier" apart from "already exactly this one".
        -- An arrestee booked as unidentified (`field.person.unidentified`) was
        -- recorded, out of sight, as the character arrested (0028). Only that
        -- character's prints may be taken against this booking: otherwise an
        -- officer could print a bystander at the terminal and learn who they
        -- are, or bind them to the arrestee's record.
        local pending = personsRepo.pendingIdentityMatches(session.agencyId, booking.personId, identifier)
        if pending == false then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'identity_mismatch' })
        end

        -- The prints belong to somebody already on file under another record
        -- -- an arrestee who would not show ID was booked as an unidentified
        -- person (`field.person.unidentified`). That is an identification,
        -- which is what the ten-print is for: the reference is filed below as
        -- usual, and the officer is told who the prints say this is. The
        -- identifier is not moved onto the booking's record, which
        -- `uq_fpd_persons_identifier` would refuse anyway; joining the two
        -- records is a supervisor's decision on the Records screen.
        local onFile = personsRepo.byIdentifier(session.agencyId, identifier)

        if onFile and onFile ~= booking.personId then
            -- Only for the arrestee the arrest recorded. Any other booking
            -- whose person has no identifier would otherwise answer who a
            -- bystander printed at the terminal is -- so it is refused, as
            -- `uq_fpd_persons_identifier` refused it before this branch existed.
            if pending ~= true then
                return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'identity_mismatch' })
            end

            if not FredPD.Repo.evidence.fileFingerprintReference(session.agencyId, identifier, session.discordId) then
                return route.refuse(FredPD.ErrorCode.INTERNAL)
            end

            personsRepo.markBiometricOnFile(session.agencyId, onFile, 'fingerprint', session.discordId)
            personsRepo.clearPendingIdentity(session.agencyId, booking.personId)

            -- Both records, whether or not the officer may read the second:
            -- the supervisor who joins them works from this (invariant 11).
            FredPD.Core.audit.write({
                action = 'booking.tenPrint.identified',
                discordId = session.discordId,
                agencyId = session.agencyId,
                subjectType = 'person',
                subjectId = tostring(onFile),
                detail = { number = booking.number, bookingPersonId = booking.personId, identifiedPersonId = onFile },
            })

            local known = personsRepo.readPerson(session, onFile)

            return {
                number = booking.number,
                -- Only when the officer may read that record; otherwise the
                -- capture is filed and nothing about the other record is said.
                identifiedAs = known and known.personNumber or nil,
            }
        end

        if personsRepo.setIdentifierIfUnset(session.agencyId, booking.personId, identifier) == 0
            and personsRepo.identifierConflict(session.agencyId, booking.personId, identifier)
        then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'identity_mismatch' })
        end

        if not FredPD.Repo.evidence.fileFingerprintReference(session.agencyId, identifier, session.discordId) then
            return route.refuse(FredPD.ErrorCode.INTERNAL)
        end

        personsRepo.markBiometricOnFile(session.agencyId, booking.personId, 'fingerprint', session.discordId)
        personsRepo.clearPendingIdentity(session.agencyId, booking.personId)

        return { number = booking.number }
    end,
})

-- -----------------------------------------------------------------------------
-- Property inventory
-- -----------------------------------------------------------------------------

route.define({
    name = 'booking.property.add',
    perm = 'booking.intake',
    schema = 'BookingPropertyAdd',
    writes = true,
    audit = 'booking.property.added',
    subjectType = BOOKING,
    auditDetail = function(input) return { bookingId = input.bookingId } end,
    handler = function(session, input)
        local err, fields = service.validatePropertyAdd(input)
        if err then return route.refuse(err, fields) end

        local booking = repo.byId(input.bookingId, session.agencyId)
        if not booking then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        if booking.releasedAt then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { bookingId = 'already_released' })
        end

        local id = repo.addProperty(input.bookingId, session, input)

        return { id = id }
    end,
})

route.define({
    name = 'booking.property.release',
    perm = 'booking.release',
    schema = 'BookingPropertyRelease',
    writes = true,
    audit = 'booking.property.released',
    subjectType = BOOKING,
    auditDetail = function(input) return { id = input.id, bookingId = input.bookingId } end,
    handler = function(session, input)
        if repo.releaseProperty(input.id, input.bookingId, session.agencyId, session.discordId) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = input.id }
    end,
})

-- -----------------------------------------------------------------------------
-- Release from custody
-- -----------------------------------------------------------------------------

route.define({
    name = 'booking.release',
    perm = 'booking.release',
    schema = 'BookingRelease',
    writes = true,
    sensitive = true,
    audit = 'booking.released',
    subjectType = BOOKING,
    auditDetail = function(input) return { id = input.id, releaseReasonKey = input.releaseReasonKey } end,
    handler = function(session, input)
        local err, fields = service.validateRelease(input)
        if err then return route.refuse(err, fields) end

        local row, refusal = readable(session, input.id)
        if not row then return refusal end

        if row.releasedAt then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { _input = 'already_released' })
        end

        if repo.release(row.id, session.agencyId, session.discordId, input, input.version) == 0 then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        return { id = row.id }
    end,
})
