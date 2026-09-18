--- Gunshot residue (spec 8.2, 8.10).
---
--- Every other trace in section 8 is something left *in the world*, which is why
--- the grid exists. GSR is not: 8.2 puts it on "shooter's hands and clothes", so
--- it travels with the player, it has no position, nobody can walk up to it and
--- it can never be streamed. Putting it in the grid would mean a row that had to
--- follow a ped around and be re-celled every time they moved -- 200 players
--- worth of that is exactly what 12.1 budgets against -- so it lives here, as
--- one flag and one timestamp per player.
---
--- Three rules, and they are the same three the grid has:
---
---   * **Nothing here reaches a client.** There is no push, no state bag and no
---     event in this file. Whether a suspect has residue on their hands is the
---     answer to a swab taken by an officer with a GSR kit, computed on the
---     server and written into an evidence row (8.11). A player who could read
---     it off their own client would know to go and wash.
---   * **Decay is read, not swept.** The grid sweeps because it walks cells that
---     nobody may be standing in; this is at most one entry per connected player
---     and is only ever read when somebody swabs somebody, which is a handful of
---     times an hour on a busy server. A timer would be a loop that exists to
---     delete rows nobody was going to look at.
---   * **The arithmetic is in `service.lua`.** `Forensics.gsrLevel` is what
---     decides the number; this file owns the table and the clock, so busted can
---     prove the curve without a running server (spec 3.4).
---
--- Washing (8.10) clears it outright. That is the one destruction method in 8.2
--- with no residual trace of its own, and deliberately: the counter-mechanic for
--- residue is that it decays on its own anyway, so a suspect who washes has
--- bought hours, not deniability -- the casings they left are still on the
--- ground.

FredPD = FredPD or {}
FredPD.Forensics = FredPD.Forensics or {}

local GSR = {}

local service = FredPD.Modules.forensics

--- The settings the grid already resolved, rather than merging the server's
--- overrides onto the defaults a second time. Two merges are two tables that
--- drift apart the first time somebody configures forensics.
local config = FredPD.Forensics.grid.settings()

--- src -> unix seconds of their most recent shot.
---
--- One number per player who has fired, and nothing else. Not a level: the level
--- is derived from the clock at the moment somebody asks, so a mark taken during
--- a resource freeze or a long pause decays honestly instead of holding still.
local marks = {}

--- This player just fired (8.2).
---
--- Re-marking replaces the timestamp rather than adding to a total. Firing again
--- puts fresh residue on hands that already had some; it does not make the
--- residue twice as strong, and a level that climbed with every shot would make
--- an emptied magazine readable hours after a single shot was not.
function GSR.mark(src)
    if not src then return end

    marks[src] = os.time()
end

--- Has this player got residue on them, and how much (8.2)?
---
--- Server-side callers only -- the GSR kit's route, and the lab through it. The
--- level is the sample quality the analysis works from, so it is the difference
--- between an identification and "insufficient for comparison" (8.7).
---
--- An expired mark is dropped as it is read. That is the whole of the cleanup:
--- the table only ever holds players who have fired, and every entry in it is
--- either still live or gets removed the next time anybody looks at it or the
--- player disconnects.
---
--- @param src number
--- @return boolean present
--- @return number level 0..100
function GSR.present(src)
    local markedAt = marks[src]
    if not markedAt then return false, 0 end

    local level = service.gsrLevel(markedAt, os.time(), config)

    if level <= 0 then
        marks[src] = nil
        return false, 0
    end

    return true, level
end

--- Washed at a sink or a shower (8.10).
---
--- Answers whether there was anything to wash off, which is what the route turns
--- into the difference between "you scrub your hands" and a refusal. It is read
--- through `present`, not off the table, so a player washing residue that had
--- already decayed to nothing is told the same thing as one who never fired --
--- otherwise the sink becomes a detector that tells a suspect whether the swab
--- would have found anything.
---
--- @param src number
--- @return boolean whether there was residue to remove
function GSR.clear(src)
    local present = GSR.present(src)

    marks[src] = nil

    return present
end

--- Forgets a player. Called on drop, so the table is bounded by the number of
--- players connected since the last restart who have fired, and not by that
--- number for the life of the resource.
function GSR.forget(src)
    marks[src] = nil
end

AddEventHandler('playerDropped', function()
    GSR.forget(source)
end)

FredPD.Forensics.gsr = GSR
