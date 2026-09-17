--- Motor pool SQL (spec 7.31). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

function Repo.fleetFor(agencyId)
    local rows = FredPD.Core.db.query(
        [[SELECT id, model, label_key AS labelKey, permission, certification, livery, enabled
            FROM fpd_fleet
           WHERE agency_id = ? AND enabled = 1
           ORDER BY sort_order, model]],
        { agencyId }
    )

    for index = 1, #rows do
        rows[index].enabled = rows[index].enabled == 1 or rows[index].enabled == true
    end

    return rows
end

--- Records a draw or a return.
---
--- A vehicle out for a whole shift is visible to command, which is the reason
--- this log exists at all (spec 7.31).
function Repo.log(action, session, model, plate, placementId)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_motorpool_log (action, agency_id, discord_id, model, plate, placement_id)
          VALUES (?, ?, ?, ?, ?, ?)]],
        { action, session.agencyId, session.discordId, model, plate, placementId }
    )
end

--- The most recent draw of a plate that has not been returned since.
---
--- Used to check a vehicle being returned actually came from the motor pool,
--- rather than being any emergency vehicle the officer found in the street.
function Repo.outstandingDraw(agencyId, plate)
    return FredPD.Core.db.single(
        [[SELECT id, model, discord_id AS discordId, occurred_at AS occurredAt
            FROM fpd_motorpool_log
           WHERE agency_id = ? AND plate = ?
           ORDER BY id DESC
           LIMIT 1]],
        { agencyId, plate }
    )
end

FredPD.Repo.garage = Repo
