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
        [[UPDATE fpd_officers SET badge_number = ?, division = ?, callsign = COALESCE(?, callsign)
           WHERE id = ? AND agency_id = ?]],
        { input.badgeNumber, input.division, input.callsign, id, agencyId })
end

--- Another officer in the agency already holding this callsign,
--- case-insensitively (the board and radio text do not tell case apart).
function Repo.callsignTaken(callsign, agencyId, exceptId)
    return FredPD.Core.db.scalar(
        [[SELECT id FROM fpd_officers
           WHERE agency_id = ? AND LOWER(callsign) = LOWER(?) AND id <> ?
           LIMIT 1]],
        { agencyId, callsign, exceptId }) ~= nil
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
-- Loadouts (0026): a named equipment set, assignable to an officer
-- -----------------------------------------------------------------------------

local LOADOUT_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, name, created_by AS createdBy,
           UNIX_TIMESTAMP(created_at) AS createdAt, version
      FROM fpd_personnel_loadout
]]

function Repo.loadouts(agencyId)
    return FredPD.Core.db.query(LOADOUT_SELECT .. ' WHERE agency_id = ? ORDER BY name', { agencyId })
end

function Repo.loadoutById(id, agencyId)
    return FredPD.Core.db.single(LOADOUT_SELECT .. ' WHERE id = ? AND agency_id = ?', { id, agencyId })
end

function Repo.loadoutItemKeys(loadoutId)
    local rows = FredPD.Core.db.query(
        'SELECT item_key AS itemKey FROM fpd_personnel_loadout_item WHERE loadout_id = ? ORDER BY item_key',
        { loadoutId })

    local out = {}
    for index = 1, #rows do out[index] = rows[index].itemKey end

    return out
end

--- The loadout assigned to this officer, if any -- read through the officer
--- row rather than a reverse lookup, since `fpd_officers.loadout_id` is
--- where the assignment actually lives.
function Repo.officerLoadout(officerId, agencyId)
    return FredPD.Core.db.single(
        [[SELECT l.id, l.name FROM fpd_officers o
            JOIN fpd_personnel_loadout l ON l.id = o.loadout_id
           WHERE o.id = ? AND o.agency_id = ?]],
        { officerId, agencyId })
end

--- Creates a loadout and its items in one transaction (spec 11.2: more than
--- one table changes) -- a loadout committed with no items would issue
--- nothing at all, which is worse than the create simply failing.
---
--- @return number|nil id
function Repo.createLoadout(agencyId, name, itemKeys, discordId)
    if #itemKeys == 0 then return nil end

    local rows, values = {}, {}
    for index = 1, #itemKeys do
        rows[index] = '(LAST_INSERT_ID(), ?)'
        values[#values + 1] = itemKeys[index]
    end

    local committed = FredPD.Core.db.transaction({
        {
            query = 'INSERT INTO fpd_personnel_loadout (agency_id, name, created_by) VALUES (?, ?, ?)',
            values = { agencyId, name, discordId },
        },
        {
            query = ('INSERT INTO fpd_personnel_loadout_item (loadout_id, item_key) VALUES %s')
                :format(table.concat(rows, ', ')),
            values = values,
        },
    })

    if not committed then return nil end

    -- `name` is unique per agency, so this is the row this call just wrote.
    return FredPD.Core.db.scalar(
        'SELECT id FROM fpd_personnel_loadout WHERE agency_id = ? AND name = ?', { agencyId, name })
end

--- Deleting a loadout leaves the officers who were wearing it alone
--- (`ON DELETE SET NULL`) and their equipment history untouched -- see the
--- migration header.
function Repo.deleteLoadout(id, agencyId)
    return FredPD.Core.db.execute(
        'DELETE FROM fpd_personnel_loadout WHERE id = ? AND agency_id = ?', { id, agencyId })
end

function Repo.setOfficerLoadout(officerId, agencyId, loadoutId)
    return FredPD.Core.db.execute(
        'UPDATE fpd_officers SET loadout_id = ? WHERE id = ? AND agency_id = ?',
        { loadoutId, officerId, agencyId })
end

-- -----------------------------------------------------------------------------
-- Issue gates (0027)
-- -----------------------------------------------------------------------------

local ISSUE_GATE_SELECT <const> = [[
    SELECT id, agency_id AS agencyId, kind, item_key AS itemKey,
           required_group AS requiredGroup, required_discord_role AS requiredDiscordRole
      FROM fpd_personnel_issue_gate
]]

function Repo.issueGates(agencyId)
    return FredPD.Core.db.query(ISSUE_GATE_SELECT .. ' WHERE agency_id = ? ORDER BY kind, item_key', { agencyId })
end

function Repo.issueGateFor(agencyId, kind, itemKey)
    return FredPD.Core.db.single(
        ISSUE_GATE_SELECT .. ' WHERE agency_id = ? AND kind = ? AND item_key = ?',
        { agencyId, kind, itemKey })
end

--- Upserts the gate on one key: a second call replaces the first rather
--- than adding a competing row, since `uq_fpd_personnel_issue_gate` allows
--- exactly one gate per (agency, kind, item key).
function Repo.setIssueGate(agencyId, kind, itemKey, requiredGroup, requiredDiscordRole, discordId)
    return FredPD.Core.db.execute(
        [[INSERT INTO fpd_personnel_issue_gate
              (agency_id, kind, item_key, required_group, required_discord_role, created_by)
          VALUES (?, ?, ?, ?, ?, ?)
          ON DUPLICATE KEY UPDATE required_group = VALUES(required_group),
                                   required_discord_role = VALUES(required_discord_role),
                                   created_by = VALUES(created_by)]],
        { agencyId, kind, itemKey, requiredGroup, requiredDiscordRole, discordId })
end

function Repo.clearIssueGate(agencyId, kind, itemKey)
    return FredPD.Core.db.execute(
        'DELETE FROM fpd_personnel_issue_gate WHERE agency_id = ? AND kind = ? AND item_key = ?',
        { agencyId, kind, itemKey })
end

--- The two predicates `Personnel.gatingSatisfied` takes for one discord id,
--- built once per call rather than once per key -- the identical shape
--- `garage/routes.lua`'s `gateChecks` builds for a fleet draw, kept here
--- rather than in `routes.lua` so `applyDutyChange` below can use it too:
--- self-issue on going on duty is still an issuance, and the officer going
--- on duty is both the issuer and the recipient.
---
--- @return function(roleId): boolean, function(groupKey): boolean
function Repo.gateChecksFor(agencyId, discordId)
    local heldRoles = {}

    local roles = FredPD.Core.perms.memberRoles(discordId)
    for index = 1, #roles do heldRoles[tostring(roles[index])] = true end

    local groupsHeld = nil
    local function membership()
        groupsHeld = groupsHeld or FredPD.Core.perms.groupsFor(discordId, agencyId)
        return groupsHeld
    end

    local holdsDiscordRole = function(roleId) return heldRoles[tostring(roleId)] == true end
    local satisfiesGroup = function(groupKey) return membership()[groupKey] == true end

    return holdsDiscordRole, satisfiesGroup
end

-- -----------------------------------------------------------------------------
-- Duty-based auto issue/return (0026)
-- -----------------------------------------------------------------------------

function Repo.openItemKeysFor(officerId, agencyId)
    local rows = FredPD.Core.db.query(
        [[SELECT item_key AS itemKey FROM fpd_personnel_equipment
           WHERE officer_id = ? AND agency_id = ? AND returned_at IS NULL]],
        { officerId, agencyId })

    local out = {}
    for index = 1, #rows do out[index] = rows[index].itemKey end

    return out
end

--- One INSERT per item: a loadout is a handful of keys, never a bulk write,
--- and each row needs its own `assigned_by` -- the officer's own discord id,
--- because going on duty is their own act (the same reasoning
--- `personnel.shift.start` gives for reading `session.officerId` rather than
--- trusting an id in input).
function Repo.autoIssue(officerId, agencyId, discordId, itemKeys)
    for index = 1, #itemKeys do
        FredPD.Core.db.insert(
            [[INSERT INTO fpd_personnel_equipment (agency_id, officer_id, item_key, assigned_by)
              VALUES (?, ?, ?, ?)]],
            { agencyId, officerId, itemKeys[index], discordId })
    end
end

--- Closes every open row for these item keys -- every one the loadout
--- carries, not only the ones this module itself opened, because a supervisor
--- who hand-assigned the same item key while the officer was on duty meant it
--- to come back with the rest of the kit.
function Repo.autoReturn(officerId, agencyId, itemKeys)
    if #itemKeys == 0 then return end

    local placeholders, values = {}, { officerId, agencyId }
    for index = 1, #itemKeys do
        placeholders[index] = '?'
        values[#values + 1] = itemKeys[index]
    end

    FredPD.Core.db.execute(
        ([[UPDATE fpd_personnel_equipment SET returned_at = CURRENT_TIMESTAMP(3)
            WHERE officer_id = ? AND agency_id = ? AND returned_at IS NULL AND item_key IN (%s)]])
            :format(table.concat(placeholders, ', ')),
        values)
end

--- What `fredpd:dutyChanged` (`server/modules/personnel/events.lua`, fired
--- from `cad/events.lua`'s sign-on poll) resolves to. An officer with no
--- assigned loadout, or a loadout with no items, is untouched.
function Repo.applyDutyChange(officerId, agencyId, discordId, working)
    local loadout = Repo.officerLoadout(officerId, agencyId)
    if not loadout then return end

    local itemKeys = Repo.loadoutItemKeys(loadout.id)
    if #itemKeys == 0 then return end

    if working then
        -- Self-issue on going on duty is still an issuance (0027): the
        -- officer going on duty is both issuer and recipient, so a gated
        -- item they do not themselves hold the role or group for is
        -- skipped here rather than handed to them automatically -- the
        -- loadout is assigned to them, but that assignment does not by
        -- itself clear a gate a supervisor set on one of its items.
        local holdsDiscordRole, satisfiesGroup = Repo.gateChecksFor(agencyId, discordId)
        local Personnel = FredPD.Modules.personnel

        local eligible = {}
        for index = 1, #itemKeys do
            local key = itemKeys[index]
            local gate = Repo.issueGateFor(agencyId, 'equipment', key)

            if Personnel.gatingSatisfied(gate, holdsDiscordRole, satisfiesGroup) then
                eligible[#eligible + 1] = key
            end
        end

        local toIssue = Personnel.itemsToIssue(eligible, Repo.openItemKeysFor(officerId, agencyId))
        Repo.autoIssue(officerId, agencyId, discordId, toIssue)
    else
        Repo.autoReturn(officerId, agencyId, itemKeys)
    end
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
