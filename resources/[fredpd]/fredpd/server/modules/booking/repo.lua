--- Booking SQL (spec 7.9). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D: `B{YY}-{#####}`.
function Repo.numberPrefix()
    return ('B%s-'):format(os.date('%y')), 5
end

local BOOKING_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, frihet_id AS frihetId,
           person_id AS personId, cell,
           UNIX_TIMESTAMP(booked_at) AS bookedAt, booked_by AS bookedBy,
           UNIX_TIMESTAMP(released_at) AS releasedAt, released_by AS releasedBy,
           release_reason_key AS releaseReasonKey,
           classification, version
      FROM fpd_booking
]]

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(
        BOOKING_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

function Repo.byFrihetId(frihetId, agencyId)
    return FredPD.Core.db.single(
        BOOKING_SELECT .. ' WHERE frihet_id = ? AND agency_id = ?', { frihetId, agencyId })
end

--- @param filter table `{ open = true|nil }` -- `open` meaning still in
---   custody (`released_at IS NULL`)
function Repo.list(agencyId, filter, limit)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.open then
        clauses[#clauses + 1] = 'released_at IS NULL'
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        BOOKING_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY booked_at DESC LIMIT ?',
        values)
end

--- Books somebody in, and allocates the number under the counter lock --
--- exactly the shape `court/repo.lua`'s `Repo.decide` uses, mirrored here
--- because a booking's number is drawn from the same locked-counter machinery
--- as every other record in the suite (invariant 8, spec 13.1).
function Repo.book(input, session)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'booking', session.agencyId)
    local base = #values

    values[base + 1] = session.agencyId
    values[base + 2] = input.frihetId
    values[base + 3] = input.personId
    values[base + 4] = input.cell
    values[base + 5] = session.discordId
    values[base + 6] = input.classification or 'internal'

    local statements = {
        {
            query = [[INSERT INTO fpd_booking
                          (number, agency_id, frihet_id, person_id, cell,
                           booked_by, classification)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?, ?)]],
            values = values,
        },
    }

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'booking', session.agencyId, nil, statements))

    if not committed then return nil end

    return FredPD.Core.db.single(
        BOOKING_SELECT .. ' WHERE agency_id = ? AND frihet_id = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, input.frihetId })
end

-- -----------------------------------------------------------------------------
-- Property inventory
-- -----------------------------------------------------------------------------

function Repo.addProperty(bookingId, session, input)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_booking_property
              (agency_id, booking_id, item_label, quantity, logged_by)
          VALUES (?, ?, ?, ?, ?)]],
        { session.agencyId, bookingId, input.itemLabel, input.quantity or 1, session.discordId })
end

--- Scoped by `agency_id` directly, not through a join to `fpd_booking` --
--- this codebase's general preference for scoping every write by agency_id
--- directly (the migration header explains why the column is denormalized
--- onto this table for exactly this).
function Repo.releaseProperty(id, bookingId, agencyId, discordId)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_booking_property SET released_at = CURRENT_TIMESTAMP(3), released_by = ?
           WHERE id = ? AND agency_id = ? AND booking_id = ? AND released_at IS NULL]],
        { discordId, id, agencyId, bookingId })
end

function Repo.propertyFor(bookingId, agencyId)
    return FredPD.Core.db.query(
        [[SELECT id, item_label AS itemLabel, quantity,
                 UNIX_TIMESTAMP(logged_at) AS loggedAt, logged_by AS loggedBy,
                 UNIX_TIMESTAMP(released_at) AS releasedAt, released_by AS releasedBy
            FROM fpd_booking_property
           WHERE booking_id = ? AND agency_id = ?
           ORDER BY released_at IS NULL DESC, logged_at]],
        { bookingId, agencyId })
end

-- -----------------------------------------------------------------------------
-- Release from custody
-- -----------------------------------------------------------------------------

--- The same shape `court/repo.lua`'s `Repo.enterDisposition` takes --
--- `discordId` its own parameter rather than a field the route dug out of
--- `session` first, so the write and its author line up the same way there.
---
--- @return number rows affected; 0 means already released or the version moved
function Repo.release(id, agencyId, discordId, input, expectedVersion)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_booking
             SET released_at = CURRENT_TIMESTAMP(3), released_by = ?,
                 release_reason_key = ?, version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND released_at IS NULL]],
        { discordId, input.releaseReasonKey, id, agencyId, expectedVersion })
end

FredPD.Repo.booking = Repo
