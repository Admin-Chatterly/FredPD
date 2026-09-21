--- ox_doorlock bridge: a door was used (spec 8.2, 3.8).
---
--- The only file in `fredpd_forensics` that names ox_doorlock. Everything else
--- in this resource reports "a surface was touched" and does not know what kind
--- of surface it was, which is what keeps the door resource swappable: a server
--- running something else writes a second file beside this one and changes
--- nothing anywhere.
---
--- ## Reporting only our own doors
---
--- ox_doorlock tells every client about every state change, because every
--- client has to draw the door in the right position. That broadcast is not a
--- sensor: on a busy server it says a door moved somewhere in the city several
--- times a minute, and the print belongs to whoever pressed the key, not to the
--- forty people who were told about it.
---
--- So the handler reports nothing unless the broadcast names the player who
--- caused it and that player is us. When the installed version does not carry a
--- source, this bridge is silent -- which is the right failure: a door sensor
--- that reports nothing loses evidence, and a door sensor that reports
--- everybody's doors puts a suspect's fingerprints on every lock in Los Santos.
---
--- The server decides the rest from its own state, as it does for every other
--- observation: where the player actually is, whether they were wearing gloves,
--- and therefore whether what they left was a fingerprint or a glove mark
--- (8.3.2). Nothing about the door goes up but the fact that one was used.

local sensors = FredPDForensics.Client.sensors

--- ox_doorlock's state broadcast.
---
--- `state` is deliberately ignored. Locking a door and unlocking it are the
--- same moment for this purpose -- a hand on a handle -- and a sensor that
--- reported only one of them would leave the better half of a burglary
--- untraceable.
RegisterNetEvent('ox_doorlock:setState', function(_id, _state, user)
    if user ~= cache.serverId then return end

    -- No network id: a door in the map is not a networked entity, so there is
    -- nothing for the server to resolve. It falls back to the player's own
    -- position, which is where the hand was.
    sensors.surfaceTouched(nil)
end)
