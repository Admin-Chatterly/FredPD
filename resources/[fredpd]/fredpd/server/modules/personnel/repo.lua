--- Personnel SQL (spec 7.22-7.24). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D: `IA{YY}-{#####}`, for the disciplinary file.
function Repo.numberPrefix()
    return ('IA%s-'):format(os.date('%y')), 5
end

-- -----------------------------------------------------------------------------
-- Roster
-- -----------------------------------------------------------------------------

local OFFICER_SELECT <const> = [[
    SELECT id, discord_id AS discordId, agency_id AS agencyId, identifier,
           callsign, badge_number AS badgeNumber, division,
           UNIX_TIMESTAMP(hire_date) AS hireDate, name, active
      FROM fpd_officers
]]

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(OFFICER_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

function Repo.byDiscordId(discordId, agencyId)
    return FredPD.Core.db.single(
        OFFICER_SELECT .. ' WHERE discord_id = ? AND agency_id = ?', { discordId, agencyId })
end

function Repo.roster(agencyId, filter, limit)
    local clauses = { 'agency_id = ?' }
    local values = { agencyId }

    if filter.active ~= nil then
        clauses[#clauses + 1] = 'active = ?'
        values[#values + 1] = filter.active and 1 or 0
    end

    if filter.division then
        clauses[#clauses + 1] = 'division = ?'
        values[#values + 1] = filter.division
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        OFFICER_SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY active DESC, callsign, name LIMIT ?',
        values)
end

--- The Discord roles this officer currently holds, for display only
--- (invariant 2 -- context, never a grant). A missing sync row (never
--- resolved, or the outage window in spec 4.2) reads as no roles rather than
--- an error: the roster still renders, just without a rank label.
function Repo.discordRoles(discordId)
    local row = FredPD.Core.db.single(
        'SELECT roles FROM fpd_discord_members WHERE discord_id = ?', { discordId })

    if not row or not row.roles then return {} end

    local ok, decoded = pcall(json.decode, row.roles)
    if not ok or type(decoded) ~= 'table' then return {} end

    return decoded
end

--- `fpd_officers` predates this module and carries no `version` column, so
--- there is no optimistic-concurrency check here the way every other write in
--- this suite has one. Two supervisors editing the same roster row at once is
--- a rare, low-stakes race (a badge number, not a legal decision), unlike
--- everything else this module touches.
function Repo.updateRoster(id, agencyId, input)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_officers SET badge_number = ?, division = ? WHERE id = ? AND agency_id = ?]],
        { input.badgeNumber, input.division, id, agencyId })
end

function Repo.setActive(id, agencyId, active)
    return FredPD.Core.db.execute(
        'UPDATE fpd_officers SET active = ? WHERE id = ? AND agency_id = ?',
        { active and 1 or 0, id, agencyId })
end

-- -----------------------------------------------------------------------------
-- Shift log
-- -----------------------------------------------------------------------------

function Repo.openShift(officerId, agencyId)
    return FredPD.Core.db.single(
        [[SELECT id, UNIX_TIMESTAMP(started_at) AS startedAt, callsign
            FROM fpd_personnel_shift_log
           WHERE officer_id = ? AND agency_id = ? AND ended_at IS NULL
           ORDER BY id DESC LIMIT 1]],
        { officerId, agencyId })
end

function Repo.startShift(officerId, agencyId, callsign)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_personnel_shift_log (agency_id, officer_id, callsign)
          VALUES (?, ?, ?)]],
        { agencyId, officerId, callsign })
end

function Repo.endShift(id, officerId, agencyId)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_personnel_shift_log SET ended_at = CURRENT_TIMESTAMP(3)
           WHERE id = ? AND officer_id = ? AND agency_id = ? AND ended_at IS NULL]],
        { id, officerId, agencyId })
end

function Repo.shiftLog(officerId, agencyId, limit)
    return FredPD.Core.db.query(
        [[SELECT id, UNIX_TIMESTAMP(started_at) AS startedAt,
                 UNIX_TIMESTAMP(ended_at) AS endedAt, callsign
            FROM fpd_personnel_shift_log
           WHERE officer_id = ? AND agency_id = ?
           ORDER BY started_at DESC LIMIT ?]],
        { officerId, agencyId, limit })
end

-- -----------------------------------------------------------------------------
-- Equipment
-- -----------------------------------------------------------------------------

function Repo.assignEquipment(officerId, session, input)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_personnel_equipment
              (agency_id, officer_id, firearm_id, item_key, serial, assigned_by)
          VALUES (?, ?, ?, ?, ?, ?)]],
        { session.agencyId, officerId, input.firearmId, input.itemKey, input.serial, session.discordId })
end

function Repo.returnEquipment(id, officerId, agencyId)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_personnel_equipment SET returned_at = CURRENT_TIMESTAMP(3)
           WHERE id = ? AND officer_id = ? AND agency_id = ? AND returned_at IS NULL]],
        { id, officerId, agencyId })
end

function Repo.equipmentFor(officerId, agencyId)
    return FredPD.Core.db.query(
        [[SELECT id, firearm_id AS firearmId, item_key AS itemKey, serial,
                 UNIX_TIMESTAMP(assigned_at) AS assignedAt, assigned_by AS assignedBy,
                 UNIX_TIMESTAMP(returned_at) AS returnedAt
            FROM fpd_personnel_equipment
           WHERE officer_id = ? AND agency_id = ?
           ORDER BY returned_at IS NULL DESC, assigned_at DESC]],
        { officerId, agencyId })
end

-- -----------------------------------------------------------------------------
-- Certifications
-- -----------------------------------------------------------------------------

function Repo.issueCertification(officerId, session, input)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_personnel_certification
              (agency_id, officer_id, cert_key, issued_by, expires_at)
          VALUES (?, ?, ?, ?, FROM_UNIXTIME(?))]],
        { session.agencyId, officerId, input.certKey, session.discordId, input.expiresAt })
end

function Repo.revokeCertification(id, officerId, agencyId, discordId)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_personnel_certification SET revoked_at = CURRENT_TIMESTAMP(3), revoked_by = ?
           WHERE id = ? AND officer_id = ? AND agency_id = ? AND revoked_at IS NULL]],
        { discordId, id, officerId, agencyId })
end

function Repo.certificationsFor(officerId, agencyId)
    return FredPD.Core.db.query(
        [[SELECT id, cert_key AS certKey, UNIX_TIMESTAMP(issued_at) AS issuedAt,
                 issued_by AS issuedBy, UNIX_TIMESTAMP(expires_at) AS expiresAt,
                 UNIX_TIMESTAMP(revoked_at) AS revokedAt
            FROM fpd_personnel_certification
           WHERE officer_id = ? AND agency_id = ?
           ORDER BY revoked_at IS NULL DESC, issued_at DESC]],
        { officerId, agencyId })
end

--- Whether this officer holds an active certification of this kind, for
--- other modules to use as a context condition (spec 7.23).
function Repo.hasActiveCertification(officerId, agencyId, certKey, now)
    local rows = FredPD.Core.db.query(
        [[SELECT UNIX_TIMESTAMP(expires_at) AS expiresAt, UNIX_TIMESTAMP(revoked_at) AS revokedAt
            FROM fpd_personnel_certification
           WHERE officer_id = ? AND agency_id = ? AND cert_key = ?]],
        { officerId, agencyId, certKey })

    for index = 1, #rows do
        if FredPD.Modules.personnel.certificationIsActive(rows[index], now) then return true end
    end

    return false
end

-- -----------------------------------------------------------------------------
-- The disciplinary file
-- -----------------------------------------------------------------------------

local DISCIPLINE_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, number, officer_id AS officerId,
           category, summary, classification, compartment,
           created_by AS createdBy, UNIX_TIMESTAMP(created_at) AS createdAt,
           UNIX_TIMESTAMP(closed_at) AS closedAt, outcome_key AS outcomeKey, version
      FROM fpd_personnel_discipline
]]

function Repo.disciplineById(id, agencyId)
    return FredPD.Core.db.single(DISCIPLINE_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

function Repo.disciplineForOfficer(officerId, agencyId)
    return FredPD.Core.db.query(
        DISCIPLINE_SELECT .. ' WHERE officer_id = ? AND agency_id = ? ORDER BY created_at DESC',
        { officerId, agencyId })
end

function Repo.openDiscipline(officerId, session, input)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'ia_case', session.agencyId)
    local base = #values

    values[base + 1] = session.agencyId
    values[base + 2] = officerId
    values[base + 3] = input.category
    values[base + 4] = input.summary
    values[base + 5] = session.discordId

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'ia_case', session.agencyId, nil, { {
            query = [[INSERT INTO fpd_personnel_discipline
                          (number, agency_id, officer_id, category, summary, created_by)
                      VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?, ?)]],
            values = values,
        } }))

    if not committed then return nil end

    return FredPD.Core.db.single(
        DISCIPLINE_SELECT .. ' WHERE agency_id = ? AND officer_id = ? AND created_by = ? ORDER BY id DESC LIMIT 1',
        { session.agencyId, officerId, session.discordId })
end

function Repo.closeDiscipline(id, agencyId, input, expectedVersion)
    return FredPD.Core.db.execute(
        [[UPDATE fpd_personnel_discipline
             SET closed_at = CURRENT_TIMESTAMP(3), outcome_key = ?, version = version + 1
           WHERE id = ? AND agency_id = ? AND version = ? AND closed_at IS NULL]],
        { input.outcomeKey, id, agencyId, expectedVersion })
end

FredPD.Repo.personnel = Repo
