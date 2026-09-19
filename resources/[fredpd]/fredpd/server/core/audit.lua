--- The audit log (invariant 11).
---
--- Append-only: this module writes, and nothing anywhere updates or deletes a
--- row. Denied attempts are recorded too -- an officer who tried to open a
--- restricted record and was refused is exactly what an audit log is for.
---
--- What goes in `detail` is what changed, never the contents of the record.
--- A log that copies the record defeats the access control on the record.

FredPD = FredPD or {}
FredPD.Core = FredPD.Core or {}

local Audit = {}

local db = nil

local function database()
    db = db or FredPD.Core.db
    return db
end

--- Records an action.
---
--- @param entry table
---   action      string  e.g. 'placement.created'
---   discordId   string|nil  the actor; nil for server-initiated work
---   agencyId    string|nil
---   subjectType string|nil  what was acted on
---   subjectId   string|nil
---   outcome     string|nil  'ok' (default), 'denied' or 'error'
---   detail      table|nil   what changed
function Audit.write(entry)
    local detail = entry.detail and json.encode(entry.detail) or nil

    database().insert(
        [[INSERT INTO fpd_audit_log
              (action, discord_id, agency_id, subject_type, subject_id, outcome, detail)
          VALUES (?, ?, ?, ?, ?, ?, ?)]],
        {
            entry.action,
            entry.discordId,
            entry.agencyId,
            entry.subjectType,
            entry.subjectId,
            entry.outcome or 'ok',
            detail,
        }
    )
end

--- Convenience for the refusal path, so denials are as easy to log as successes
--- and therefore actually get logged.
function Audit.denied(session, action, reason, subjectType, subjectId)
    Audit.write({
        action = action,
        discordId = session and session.discordId or nil,
        agencyId = session and session.agencyId or nil,
        subjectType = subjectType,
        subjectId = subjectId,
        outcome = 'denied',
        detail = { reason = reason },
    })
end

FredPD.Core.audit = Audit
