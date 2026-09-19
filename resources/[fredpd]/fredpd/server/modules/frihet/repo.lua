--- Frihetsberövande SQL (spec 7.9). Parameterized only (invariant 8).
---
--- The timestamps come back as epoch seconds rather than as strings, because
--- every clock in `frihet/service.lua` is arithmetic on them and a service that
--- had to parse a DATETIME would be a service that parsed it differently from
--- the way MariaDB wrote it. `UNIX_TIMESTAMP` does the conversion in the one
--- place that knows the column's type.
---
--- There is **no delete path** and **no update path for a stage column**. A
--- stage is written once, by the transition that takes it, and a frihetsberövande
--- whose gripande time could be edited afterwards is a detention whose statutory
--- deadline could be moved after it was missed.

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

--- Appendix D gives the `arrest` counter no format of its own, so this follows
--- the booking one: `F{YY}-{#####}`, with `F` for frihetsberövande. Kept here
--- with the module that owns the record, the way every other prefix is.
function Repo.numberPrefix()
    return ('F%s-'):format(os.date('%y')), 5
end

local SELECT <const> = [[
    SELECT f.id, f.agency_id AS agencyId, f.number, f.person_id AS personId,
           f.fu_id AS fuId, f.anmalan_id AS anmalanId, f.status,
           UNIX_TIMESTAMP(f.gripen_at)      AS gripenAt,
           f.gripen_by AS gripenBy, f.gripande_grund AS gripandeGrund,
           f.gripande_plats AS gripandePlats,
           UNIX_TIMESTAMP(f.underrattad_at) AS underrattadAt,
           UNIX_TIMESTAMP(f.anhallen_at)    AS anhallenAt,
           f.anhallen_by AS anhallenBy, f.anhallande_grund AS anhallandeGrund,
           UNIX_TIMESTAMP(f.framstallan_at) AS framstallanAt,
           f.framstallan_by AS framstallanBy,
           UNIX_TIMESTAMP(f.haktad_at)      AS haktadAt,
           f.haktad_by AS haktadBy, f.haktning_beslut AS haktningBeslut,
           UNIX_TIMESTAMP(f.frigiven_at)    AS frigivenAt,
           f.frigiven_by AS frigivenBy, f.frigiven_grund AS frigivenGrund,
           f.classification, f.version,
           p.person_number AS personNumber
      FROM fpd_frihetsberovande f
      JOIN fpd_persons p ON p.id = f.person_id
]]

function Repo.byId(id, agencyId)
    return FredPD.Core.db.single(
        SELECT .. ' WHERE f.id = ? AND f.agency_id = ?', { id, agencyId })
end

--- Everybody this agency is currently holding.
---
--- The default and the one that matters: it is the list a supervisor watches
--- the countdowns on, and `idx_fpd_frihet_open` answers it off a narrow index
--- rather than by scanning every detention the server has ever recorded.
function Repo.open(agencyId, limit)
    return FredPD.Core.db.query(
        SELECT .. [[ WHERE f.agency_id = ? AND f.status <> 'frigiven'
                     ORDER BY f.gripen_at LIMIT ?]],
        { agencyId, limit })
end

function Repo.list(agencyId, filter, limit)
    local clauses = { 'f.agency_id = ?' }
    local values = { agencyId }

    if filter.status then
        clauses[#clauses + 1] = 'f.status = ?'
        values[#values + 1] = filter.status
    end

    if filter.personId then
        clauses[#clauses + 1] = 'f.person_id = ?'
        values[#values + 1] = filter.personId
    end

    if filter.fuId then
        clauses[#clauses + 1] = 'f.fu_id = ?'
        values[#values + 1] = filter.fuId
    end

    values[#values + 1] = limit

    return FredPD.Core.db.query(
        SELECT .. ' WHERE ' .. table.concat(clauses, ' AND ')
            .. ' ORDER BY f.created_at DESC LIMIT ?',
        values)
end

function Repo.charges(frihetId)
    return FredPD.Core.db.query([[
        SELECT fb.id, fb.brott_id AS brottId, fb.stage,
               b.code, b.balk, b.kapitel, b.paragraf, b.label_key AS labelKey,
               b.grad, b.boter,
               b.fangelse_min_months AS fangelseMinMonths,
               b.fangelse_max_months AS fangelseMaxMonths
          FROM fpd_frihet_brott fb
          JOIN fpd_brott b ON b.id = fb.brott_id
         WHERE fb.frihet_id = ?
         ORDER BY fb.id]], { frihetId })
end

--- The custody log, with each entry's author named rather than numbered.
---
--- The join is the point. `logged_by` is a Discord snowflake, and a snowflake
--- drawn in a "By" column tells an officer nothing and puts an account
--- identifier on the face of a custody record -- a document a defence lawyer
--- reads. `fpd_officers` already holds the callsign and the display name
--- command staff set.
---
--- LEFT, not INNER: an entry written by somebody since removed from the roster
--- must still appear. The log is append-only (7.9) and a row that vanished
--- because its author left is the one gap that matters in it. The NUI falls
--- back to the callsign, then to nothing.
---
--- **Scoped by agency**, which is not optional here. `fpd_officers` is unique
--- on `(discord_id, agency_id)`, so an officer on two agencies' rosters --
--- ordinary on a server running a police department and a sheriff's office --
--- matches twice, and an unscoped join would silently duplicate every entry
--- they wrote. A custody log that shows the same meal twice is a custody log
--- nobody can testify from.
function Repo.log(frihetId, agencyId)
    return FredPD.Core.db.query([[
        SELECT l.id, l.kind, l.note,
               o.callsign AS loggedByCallsign, o.name AS loggedByName,
               UNIX_TIMESTAMP(l.logged_at) AS loggedAt
          FROM fpd_frihet_log l
          LEFT JOIN fpd_officers o
                 ON o.discord_id = l.logged_by AND o.agency_id = ?
         WHERE l.frihet_id = ?
         ORDER BY l.logged_at, l.id]], { agencyId, frihetId })
end

--- Records a gripande, and allocates the number under the counter lock.
---
--- `gripen_at` is `CURRENT_TIMESTAMP(3)` and not a value from input: the moment
--- a person was arrested is the instant every statutory deadline in this module
--- is measured from, and a client that could choose it could move a deadline it
--- had already missed (invariant 1).
function Repo.gripande(input, session)
    local prefix, width = Repo.numberPrefix()
    local counters = FredPD.Core.counters

    local values = counters.numberValues(prefix, width, 'arrest', session.agencyId)
    local base = #values

    -- By index: `fu_id` and `anmalan_id` are nil on a gripande made before any
    -- paperwork exists, which is most of them, and a nil appended to an oxmysql
    -- values list shifts every parameter after it.
    values[base + 1] = session.agencyId
    values[base + 2] = input.personId
    values[base + 3] = input.fuId
    values[base + 4] = input.anmalanId
    values[base + 5] = session.discordId
    values[base + 6] = input.grund
    values[base + 7] = input.plats
    values[base + 8] = input.classification or 'internal'

    local committed = FredPD.Core.db.transaction(counters.transaction(
        'arrest', session.agencyId, nil, {
            {
                query = [[INSERT INTO fpd_frihetsberovande
                              (number, agency_id, person_id, fu_id, anmalan_id,
                               status, gripen_at, gripen_by, gripande_grund,
                               gripande_plats, classification)
                          VALUES (]] .. counters.numberSql() .. [[, ?, ?, ?, ?,
                                  'gripen', CURRENT_TIMESTAMP(3), ?, ?, ?, ?)]],
                values = values,
            },
        }))

    if not committed then return nil end

    return FredPD.Core.db.single(
        SELECT .. ' WHERE f.agency_id = ? AND f.gripen_by = ? ORDER BY f.id DESC LIMIT 1',
        { session.agencyId, session.discordId })
end

--- The columns each transition stamps.
---
--- A table rather than four near-identical statements, so this set and
--- `Frihet.nextStatus`'s can be read against each other -- and so a fifth stage
--- cannot be added to one without the absence being obvious in the other.
local STAMPS <const> = {
    anhallen = {
        at = 'anhallen_at', by = 'anhallen_by', grund = 'anhallande_grund',
    },
    framstalld = {
        at = 'framstallan_at', by = 'framstallan_by',
    },
    haktad = {
        at = 'haktad_at', by = 'haktad_by',
    },
    frigiven = {
        at = 'frigiven_at', by = 'frigiven_by', grund = 'frigiven_grund',
    },
}

--- Takes a decision in the chain.
---
--- The timestamp is always `CURRENT_TIMESTAMP(3)` for the reason `gripande`
--- gives. The version in the WHERE is the optimistic lock: two prosecutors
--- deciding on the same detention in the same second is not a race anybody
--- should resolve by last-write-wins.
---
--- @return number rows affected; 0 means the version moved
function Repo.decide(id, agencyId, toStatus, discordId, grund, expectedVersion)
    local stamp = STAMPS[toStatus]
    assert(stamp, 'no stamp for status: ' .. tostring(toStatus))

    local sets = {
        '`status` = ?',
        ('`%s` = CURRENT_TIMESTAMP(3)'):format(stamp.at),
        ('`%s` = ?'):format(stamp.by),
        '`version` = `version` + 1',
    }

    local values = { toStatus, discordId }

    if stamp.grund then
        sets[#sets + 1] = ('`%s` = ?'):format(stamp.grund)
        values[#values + 1] = grund
    end

    -- The court's decision is recorded alongside the status, because "häktad"
    -- and "the court refused and released them" are both outcomes of the same
    -- hearing and a row that recorded only the first would be silent about the
    -- second.
    if toStatus == 'haktad' then
        sets[#sets + 1] = '`haktning_beslut` = ?'
        values[#values + 1] = 'haktad'
    end

    values[#values + 1] = id
    values[#values + 1] = agencyId
    values[#values + 1] = expectedVersion

    return FredPD.Core.db.execute(
        ('UPDATE fpd_frihetsberovande SET %s WHERE id = ? AND agency_id = ? AND version = ?')
            :format(table.concat(sets, ', ')),
        values)
end

--- Records that the gripne was told what they are suspected of (RB 24:9).
---
--- Written once. `underrattad_at IS NULL` in the WHERE rather than an
--- `ON DUPLICATE`: the question asked afterwards is when they were first told,
--- and a second call that moved the timestamp later would answer it wrongly in
--- the direction that flatters the department.
function Repo.underratta(id, agencyId)
    return FredPD.Core.db.execute([[
        UPDATE fpd_frihetsberovande
           SET underrattad_at = CURRENT_TIMESTAMP(3), version = version + 1
         WHERE id = ? AND agency_id = ? AND underrattad_at IS NULL]],
        { id, agencyId })
end

--- Replaces what somebody is held for, as one unit.
function Repo.replaceCharges(frihetId, charges, discordId)
    local statements = {
        {
            query = 'DELETE FROM fpd_frihet_brott WHERE frihet_id = ?',
            values = { frihetId },
        },
    }

    for index = 1, #charges do
        statements[#statements + 1] = {
            query = [[INSERT INTO fpd_frihet_brott (frihet_id, brott_id, stage, created_by)
                      VALUES (?, ?, ?, ?)]],
            values = {
                frihetId, charges[index].brottId,
                charges[index].stage or 'fullbordat', discordId,
            },
        }
    end

    return FredPD.Core.db.transaction(statements)
end

--- Appends to the custody log. There is no update and no delete.
function Repo.addLog(frihetId, kind, note, discordId)
    return FredPD.Core.db.insert(
        'INSERT INTO fpd_frihet_log (frihet_id, kind, note, logged_by) VALUES (?, ?, ?, ?)',
        { frihetId, kind, note, discordId })
end

FredPD.Repo.frihet = Repo
