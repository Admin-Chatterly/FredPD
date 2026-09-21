--- Police chat SQL (spec 7.26). Append-only: this module inserts and selects,
--- and there is deliberately no update or delete (invariant 11).

FredPD = FredPD or {}
FredPD.Repo = FredPD.Repo or {}

local Repo = {}

function Repo.insert(session, body)
    return FredPD.Core.db.insert(
        [[INSERT INTO fpd_chat_messages (agency_id, discord_id, callsign, author_name, body)
          VALUES (?, ?, ?, ?, ?)]],
        { session.agencyId, session.discordId, session.callsign, session.name, body }
    )
end

--- Recent messages for the comms log, newest last so it reads like a transcript.
function Repo.recent(agencyId, limit)
    local rows = FredPD.Core.db.query(
        [[SELECT id, sent_at AS sentAt, callsign, author_name AS authorName, body
            FROM fpd_chat_messages
           WHERE agency_id = ?
           ORDER BY id DESC
           LIMIT ?]],
        { agencyId, limit }
    )

    -- Reverse in place: the query takes the newest by id, the reader wants them
    -- in the order they were said.
    for left = 1, math.floor(#rows / 2) do
        local right = #rows - left + 1
        rows[left], rows[right] = rows[right], rows[left]
    end

    return rows
end

FredPD.Repo.chat = Repo
