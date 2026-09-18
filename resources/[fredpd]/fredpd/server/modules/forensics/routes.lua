--- Trace generation and collection (spec 8.3, 8.4, 8.11).
---
--- This file is where a client's *observation* becomes, or fails to become, a
--- fact. Everything section 11.3 lists as a banned pattern is a version of
--- letting that decision go the other way, so the shape here is deliberate:
---
---   * a sensor reports **what happened to it** -- "I fired", "I opened that
---     door" -- and never what exists, what type it is, or whose it is;
---   * the server decides, from its own state: the player's position from their
---     ped, the entity from the network id it resolves itself and the distance
---     to it, the weapon from the inventory bridge, the glove state from the
---     appearance bridge (8.3.2);
---   * the owner is the source player's hidden identifier, looked up here and
---     never returned (8.3.4, 8.11). The answer to a sensor call carries no
---     information at all about what was created;
---   * victim blood comes only from the server-side `weaponDamageEvent` pair,
---     which no client can send (8.3.3).
---
--- Collection does not define a route of its own. `evidence.collect` in the
--- evidence module is the officer's route -- it is the only path that writes an
--- item, an owner row and the first link of the custody chain, in one
--- transaction (8.6) -- and what it was missing was the grid to claim from.
--- This file supplies that claim and nothing more: one insert path, as there
--- has to be.

local route = FredPD.Core.route
local service = FredPD.Modules.forensics
local grid = FredPD.Forensics.grid
local config = grid.settings()

-- -----------------------------------------------------------------------------
-- What the server knows (8.3.2)
-- -----------------------------------------------------------------------------

--- Where a player actually is, according to the server.
---
--- Never a coordinate from the call. A client that could name the position
--- could lay a trail of somebody else's prints across the city.
---
--- @return vector3|nil
local function positionOf(src)
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end

    return GetEntityCoords(ped)
end

--- The character behind a server id, for the hidden identifier it carries.
---
--- Works for every player, not only officers: the criminal who left the print
--- is the point of the whole section, and they have no FredPD session.
local function identifierOf(src)
    local character = FredPD.Bridge.framework.getCharacter(src)
    return character and character.identifier or nil
end

--- The weapon the *server* believes this player is holding (8.3.2).
---
--- Read through a bridge, because naming the inventory resource anywhere else
--- would put it in two places (spec 3.8). Nil when no bridge is installed, and
--- every weapon-derived trace is refused in that case rather than invented: a
--- casing attributed to a serial nobody was carrying is worse than no casing.
---
--- @return table|nil { name, serial, isFirearm }
local function heldWeapon(src)
    local bridge = FredPD.Bridge and FredPD.Bridge.inventory
    if not bridge or not bridge.currentWeapon then return nil end

    return bridge.currentWeapon(src)
end

--- Is this player wearing gloves (8.2, 8.3.2)?
---
--- Gloves are what turn a fingerprint into a glove mark, so the answer decides
--- the type of the trace. A server with no appearance bridge answers "no",
--- which is the behaviour a server without glove support should have: prints
--- are left, and nobody is told a glove mark exists that no glove made.
local function wearingGloves(src)
    local bridge = FredPD.Bridge and FredPD.Bridge.appearance
    if not bridge or not bridge.wearingGloves then return false end

    return bridge.wearingGloves(src) == true
end

--- Resolves a network id to an entity this player is genuinely standing next to.
---
--- Three checks, all of them server-side (8.3.2): the id resolves, the entity
--- exists, and it is within reach of where the server says the player is. A
--- sensor reporting a vehicle on the other side of the map is not a sensor.
---
--- @return number|nil entity
--- @return vector3|nil its position
local function entityNear(netId, position)
    if type(netId) ~= 'number' then return nil end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end

    local at = GetEntityCoords(entity)
    local dx, dy, dz = at.x - position.x, at.y - position.y, at.z - position.z
    local range = config.entityRange

    if (dx * dx + dy * dy + dz * dz) > (range * range) then return nil end

    return entity, at
end

--- Server ids by ped handle, rebuilt at most once a second.
---
--- `weaponDamageEvent` names its victims by network id, and turning one back
--- into a player means comparing against every player's ped. At 200 players
--- under sustained fire that is the kind of loop spec 12.1 budgets against, so
--- the map is built once per second and shared by every event in between.
local pedOwners = { at = -1000, map = {} }

local function playerForEntity(entity)
    local now = GetGameTimer()

    if now - pedOwners.at > 1000 then
        local map = {}
        local players = GetPlayers()

        for index = 1, #players do
            local src = tonumber(players[index])
            local ped = src and GetPlayerPed(src) or 0

            if ped ~= 0 then map[ped] = src end
        end

        pedOwners = { at = now, map = map }
    end

    return pedOwners.map[entity]
end

--- How many shots each player has fired, for the casing sampling in 8.2.
---
--- Kept per player and never reset while they are connected, so the rate is one
--- casing per N shots across a magazine, a firefight and a night -- not one per
--- N shots per weapon, which reloading would game.
local shotCounts = {}

-- -----------------------------------------------------------------------------
-- What a sensor may report (8.3.1)
-- -----------------------------------------------------------------------------

--- The observations a client is allowed to make, and what the server does with
--- each.
---
--- Every entry is a function of things the server looked up itself. The client's
--- contribution is the *kind* -- which moment happened -- and at most a network
--- id, which is checked before it is used.
---
--- `limit` is a hard per-player, per-kind ceiling on top of the route's own
--- (8.3.2). One ceiling for the route would let a client spend its whole budget
--- on the cheapest kind and fill the grid with it, which is the denial-of-service
--- entry in 11.1.
---
--- A rule answers a trace, or nil. Nil is an ordinary outcome and not an error:
--- four shots in five leave no casing, and a call that legitimately creates
--- nothing must look exactly like one that does (8.11).
local RULES <const> = {
    --- A shot. Casings are sampled, never one per shot (8.2, 12.2).
    shot = {
        limit = { per = 150, window = 30 },
        make = function(src, _input, position)
            local weapon = heldWeapon(src)
            if not weapon or not weapon.serial then return nil end

            local count = (shotCounts[src] or 0) + 1
            shotCounts[src] = count

            if not service.sampleShot(count, config) then return nil end

            return {
                type = 'casing',
                x = position.x,
                y = position.y,
                z = position.z,
                -- A casing carries the gun, not the shooter (8.3.4).
                owner = { weaponSerial = weapon.serial },
            }
        end,
    },

    --- A reload. The magazine lands where the player is standing; the game's own
    --- dropped-magazine position is a client-side detail and is not asked for.
    reload = {
        limit = { per = 20, window = 30 },
        make = function(src, _input, position)
            local weapon = heldWeapon(src)
            if not weapon or not weapon.serial then return nil end

            return {
                type = 'magazine',
                x = position.x,
                y = position.y,
                z = position.z,
                -- Both, and legitimately: the magazine is the weapon's, and the
                -- thumb that loaded it was bare unless they wore gloves (8.2).
                owner = {
                    weaponSerial = weapon.serial,
                    identifier = not wearingGloves(src) and identifierOf(src) or nil,
                },
            }
        end,
    },

    --- Touching a surface: a door, a register, a safe, an ATM.
    surface = {
        limit = { per = 30, window = 30 },
        make = function(src, input, position)
            local identifier = identifierOf(src)
            if not identifier then return nil end

            local at = position

            if input.netId then
                local _, entityAt = entityNear(input.netId, position)
                if not entityAt then return nil end
                at = entityAt
            end

            return {
                type = wearingGloves(src) and 'glove_mark' or 'print',
                x = at.x,
                y = at.y,
                z = at.z,
                owner = { identifier = identifier },
                part = input.doorIndex,
            }
        end,
    },

    --- Entering or leaving a vehicle, per door (8.2). The vehicle has to exist
    --- and be within reach; the door index is recorded and never trusted for
    --- anything the server would otherwise have to check.
    vehicle_door = {
        limit = { per = 30, window = 30 },
        make = function(src, input, position)
            local identifier = identifierOf(src)
            if not identifier then return nil end

            local _, at = entityNear(input.netId, position)
            if not at then return nil end

            return {
                type = wearingGloves(src) and 'glove_mark' or 'print',
                x = at.x,
                y = at.y,
                z = at.z,
                owner = { identifier = identifier },
                part = input.doorIndex,
            }
        end,
    },

    --- Drinking, eating, smoking: touch DNA on the thing they handled (8.2).
    --- Gloves do not help here -- saliva is not a fingerprint.
    item_use = {
        limit = { per = 15, window = 30 },
        make = function(src, _input, position)
            local identifier = identifierOf(src)
            if not identifier then return nil end

            return {
                type = 'dna_touch',
                x = position.x,
                y = position.y,
                z = position.z,
                owner = { identifier = identifier },
            }
        end,
    },

    --- Lockpicking and vehicle break-ins leave tool marks that a lab can match
    --- to the tool (8.2). The tool is read from server-side inventory state, the
    --- same way a weapon is, and its serial is what the mark carries.
    tool = {
        limit = { per = 20, window = 30 },
        make = function(src, input, position)
            local tool = heldWeapon(src)
            if not tool or not tool.serial then return nil end

            local at = position

            if input.netId then
                local _, entityAt = entityNear(input.netId, position)
                if not entityAt then return nil end
                at = entityAt
            end

            return {
                type = 'tool_mark',
                x = at.x,
                y = at.y,
                z = at.z,
                owner = { weaponSerial = tool.serial },
            }
        end,
    },
}

--- Turns one observation into nothing, or into a trace in the grid.
---
--- Everything a *client* can cause comes through here, so there is one place to
--- read to know what a client can cause. The damage handler below does not:
--- blood and the bullet beside it are built from the server's own event and
--- from the victim rather than the caller, and 8.3.3 is explicit that they must
--- never be reachable from an observation at all.
---
--- @param src number
--- @param kind string a key of `RULES`
--- @param input table the validated call, or a table the server built itself
--- @return boolean accepted -- whether the observation was allowed, which is not
---   the same as whether anything was created
local function observe(src, kind, input)
    local rule = RULES[kind]
    if not rule then return false end

    -- The hard per-kind limit (8.3.2). Separate from the route's own ceiling and
    -- checked with the same limiter, so a client that loops one kind is stopped
    -- by the kind's budget rather than by the route's.
    if not FredPD.Core.ratelimit.take(src, 'forensics.observe:' .. kind, rule.limit) then
        return false
    end

    local position = positionOf(src)
    if not position then return false end

    local trace = rule.make(src, input, position)
    if not trace then return true end

    grid.place(trace)

    return true
end

-- -----------------------------------------------------------------------------
-- The sensor route (8.3.1)
-- -----------------------------------------------------------------------------

route.define({
    name = 'forensics.observe',
    perm = 'forensics.trace.report',
    schema = 'ForensicsObserve',
    -- The route's own ceiling, above the per-kind ones. Generous, because the
    -- kinds are what actually bound this; a client that reaches this has already
    -- been refused by every kind budget it spent.
    limit = { per = 300, window = 60 },
    -- Not `writes`. A stale permission snapshot must not stop the world leaving
    -- traces in it (4.2): read-only mode exists to stop a session *acting* on
    -- records during an outage, and refusing here would not restrict an outage's
    -- damage, it would erase evidence that a crime happened during one. Nothing
    -- is written to the database on this path -- collection does that, and
    -- collection is a write.
    writes = false,
    -- No audit entry, on purpose. Every shot fired in the city would be an audit
    -- row, and an audit log nobody can read is not a control (invariant 11). The
    -- grid keeps totals for the health screen instead, and the item that comes
    -- out of a trace is audited when it is collected.
    handler = function(session, input)
        observe(session.src, input.kind, input)

        -- Deliberately empty. Whether a casing was left, whether the print was
        -- a glove mark, whether anything exists at all -- none of it is the
        -- client's to know (8.11). What exists reaches them as render data on
        -- the next streaming tick, or it does not reach them.
        return {}
    end,
})

-- -----------------------------------------------------------------------------
-- Victim blood, from the server's own event (8.3.3)
-- -----------------------------------------------------------------------------

--- Blood, and the bullet that drew it, from `weaponDamageEvent`.
---
--- 8.3.3 is explicit that this pair may never come from a client claim, and it
--- does not have to: `weaponDamageEvent` fires on the server with both ends of
--- the exchange. The attacker is the sender, which the server resolved; the
--- victim is a network id the server resolves itself.
---
--- The blood is the *victim's* -- their hidden identifier, not the attacker's --
--- which is what makes it worth anything: it puts the victim at the scene, and
--- the bullet beside it puts the attacker's weapon there.
AddEventHandler('weaponDamageEvent', function(sender, data)
    local attacker = tonumber(sender)
    if not attacker or type(data) ~= 'table' then return end

    -- Sustained fire is one exchange and generates one trace per second's worth
    -- of it. Merging (8.3.5) already folds the rest into the first, but this
    -- stops the grid walk that merging costs.
    if not FredPD.Core.ratelimit.take(attacker, 'forensics.damage', { per = 40, window = 10 }) then
        return
    end

    -- The server cannot see the damage number for a hit that did not override
    -- the weapon's default, so an ordinary hit counts as one worth bleeding
    -- from and only an explicitly reduced one is measured against the threshold
    -- (8.2).
    local damage = data.overrideDefaultDamage and (data.weaponDamage or 0)
        or config.bloodDamageThreshold

    if damage < config.bloodDamageThreshold then return end

    local hits = data.hitGlobalIds
    if type(hits) ~= 'table' then return end

    local weapon = heldWeapon(attacker)

    for index = 1, #hits do
        local entity = NetworkGetEntityFromNetworkId(hits[index])

        if entity and entity ~= 0 and DoesEntityExist(entity) then
            local victim = playerForEntity(entity)
            local identifier = victim and identifierOf(victim)

            -- Only players. An NPC has no hidden identifier, so their blood
            -- could never be matched to anything and would be a row the lab
            -- returns "no profile" for, forever.
            if identifier then
                local at = GetEntityCoords(entity)

                grid.place({
                    type = 'blood',
                    x = at.x,
                    y = at.y,
                    z = at.z,
                    owner = { identifier = identifier },
                })

                -- The round that did it, recovered at the victim. Only from a
                -- firearm, and only when server-side inventory state says the
                -- attacker was holding one -- a fist leaves no bullet.
                if weapon and weapon.serial and weapon.isFirearm then
                    grid.place({
                        type = 'bullet',
                        x = at.x,
                        y = at.y,
                        z = at.z,
                        owner = { weaponSerial = weapon.serial },
                    })
                end
            end
        end
    end
end)

-- -----------------------------------------------------------------------------
-- Working a scene with tools (8.4)
-- -----------------------------------------------------------------------------

route.define({
    name = 'forensics.process',
    perm = 'forensics.tools.use',
    schema = 'ForensicsProcess',
    context = { onDuty = true },
    limit = { per = 30, window = 60 },
    audit = 'forensics.processed',
    auditDetail = function(input, result)
        -- The tool and how much it found. Not what was found, and not where:
        -- the audit log is read by more people than the scene is worked by.
        return { tool = input.tool, found = result.found }
    end,
    handler = function(session, input)
        local position = positionOf(session.src)
        if not position then return route.refuse(FredPD.ErrorCode.CONTEXT) end

        -- Where the officer is standing, at the radius the server chose. A
        -- client-supplied radius would turn a dusting brush into a citywide
        -- search for everything anyone has ever touched.
        local found = grid.reveal(
            position.x, position.y, position.z, config.processRadius, input.tool
        )

        return { found = found }
    end,
})

-- -----------------------------------------------------------------------------
-- Collection: the claim `evidence.collect` was waiting for (8.4, 8.5)
-- -----------------------------------------------------------------------------

FredPD.Evidence = FredPD.Evidence or {}

--- Hands a trace over to `evidence.collect`, and takes it out of the world.
---
--- Everything the officer's route needs to write the item and compute its
--- quality, and nothing that could be answered back to them. The owner in the
--- returned table is hidden truth: it goes into `fpd_evidence_owner` and never
--- into a response (8.1, 8.11).
---
--- Three refusals, all silent in the same way -- the route answers "not found",
--- because distinguishing them would tell a client which keys name real traces:
---   * no such trace, or somebody else collected it first;
---   * a latent trace nobody has processed yet: it has not been found, so it
---     cannot be collected (8.4);
---   * the officer is not standing next to it, measured against the server's
---     copy of where they are (8.3.2).
---
--- Taking is destructive, and is the last thing that happens: two officers
--- cannot collect the same casing, because the second one finds nothing.
---
--- @param src number
--- @param traceKey string the opaque key that came with render data
--- @return table|nil
FredPD.Evidence.claimTrace = function(src, traceKey)
    if type(traceKey) ~= 'string' then return nil end

    local position = positionOf(src)
    if not position then return nil end

    local item = grid.peek(traceKey)
    if not item then return nil end

    if item.latent and not item.revealed then return nil end

    local dx, dy, dz = item.x - position.x, item.y - position.y, item.z - position.z
    local range = config.collectRange

    if (dx * dx + dy * dy + dz * dz) > (range * range) then return nil end

    local taken = grid.take(traceKey)
    if not taken then return nil end

    return {
        type = taken.type,
        quality = taken.quality,
        ageSeconds = math.max(os.time() - (taken.createdAt or 0), 0),
        decayPerHour = service.decayPerHour(taken.type, config),
        outdoors = taken.outdoors,
        cleaned = taken.cleaned,
        owner = taken.owner,
    }
end

AddEventHandler('playerDropped', function()
    shotCounts[source] = nil
end)
