--- Placement SQL (spec 3.10). Parameterized only (invariant 8).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

local SELECT <const> = [[
    SELECT id, kind, agency_id AS agencyId, interaction, model,
           x, y, z, heading, radius, label_key AS labelKey, enabled
      FROM fpd_placements
]]

--- Converts MySQL's 0/1 into a real boolean, so callers never compare to 0.
local function normalize(row)
    if not row then return nil end
    row.enabled = row.enabled == 1 or row.enabled == true
    return row
end

function Repo.all()
    local rows = FredPD.Core.db.query(SELECT .. ' ORDER BY kind, id')

    for index = 1, #rows do normalize(rows[index]) end
    return rows
end

function Repo.byId(id)
    return normalize(FredPD.Core.db.single(SELECT .. ' WHERE id = ?', { id }))
end

function Repo.create(input, discordId)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_placements
              (kind, agency_id, interaction, model, x, y, z, heading, radius, label_key, created_by)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        {
            input.kind,
            input.agencyId,
            input.interaction,
            input.model,
            input.x,
            input.y,
            input.z,
            input.heading or 0.0,
            input.radius or 1.5,
            input.labelKey,
            discordId,
        }
    )
end

--- Updates only the fields present in `input`.
---
--- Built from a fixed allowlist of columns rather than from the input's keys,
--- so the column names can never come from a client (invariant 8).
function Repo.update(id, input)
    local columns = {
        kind = 'kind',
        interaction = 'interaction',
        model = 'model',
        x = 'x',
        y = 'y',
        z = 'z',
        heading = 'heading',
        radius = 'radius',
        labelKey = 'label_key',
        enabled = 'enabled',
    }

    local assignments = {}
    local values = {}

    -- Fixed order, so the generated statement is deterministic and reviewable.
    local order = { 'kind', 'interaction', 'model', 'x', 'y', 'z', 'heading', 'radius', 'labelKey', 'enabled' }

    for index = 1, #order do
        local field = order[index]

        if input[field] ~= nil then
            assignments[#assignments + 1] = ('`%s` = ?'):format(columns[field])
            values[#values + 1] = input[field]
        end
    end

    if #assignments == 0 then return 0 end

    values[#values + 1] = id

    return FredPD.Core.db.execute(
        ('UPDATE fpd_placements SET %s WHERE id = ?'):format(table.concat(assignments, ', ')),
        values
    )
end

function Repo.delete(id)
    return FredPD.Core.db.execute('DELETE FROM fpd_placements WHERE id = ?', { id })
end

FredPD.Repo.placements = Repo
