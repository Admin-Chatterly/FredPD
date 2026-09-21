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
