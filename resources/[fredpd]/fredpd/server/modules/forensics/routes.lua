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
---   * victim blood comes only from the `weaponDamageEvent` pair the server
---     receives itself, and never from a sensor call (8.3.3). That is not the
---     same as "no client can send it", and reading it that way is how the
---     handler below went unchecked for a round: the event is raised by the
---     shooter's own client and every field in the payload is theirs. What the
---     server takes from it is the *sender*; the victim, the position, the
---     identifier and the weapon are all resolved here, and a hit further off
---     than a shot carries is refused. See the handler for what that buys and
---     what it does not.
---
--- Collection does not define a route of its own. `evidence.collect` in the
--- evidence module is the officer's route -- it is the only path that writes an
--- item, an owner row and the first link of the custody chain, in one
--- transaction (8.6) -- and what it was missing was somewhere to claim from.
--- This file supplies the claims and nothing more: `claimTrace` for a trace
--- lying in the grid, `claimGsr` for the residue on a suspect's hands, and one
--- insert path behind both, as there has to be.

local route = FredPD.Core.route
local service = FredPD.Modules.forensics
local grid = FredPD.Forensics.grid
local config = grid.settings()

--- For the identity scan's custody gate (8.8). Both load before this file
--- (`fxmanifest.lua`), so reading them once here is safe.
local frihetService = FredPD.Modules.frihet
local frihetRepo = FredPD.Repo.frihet
local personsRepo = FredPD.Repo.persons

--- Residue is the one trace in 8.2 that is not in the world, so it is not in the
--- grid: it sits on the shooter and travels with them. Bound at load, which is
--- safe because `fxmanifest.lua` loads `gsr.lua` before this file and says so --
--- the shot sensor below marks a shooter and the washing route clears them.
local gsr = FredPD.Forensics.gsr

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

--- Is this person currently held under a live gripande/anhållande/
--- framställande/häktning chain (8.8's gate on the identity scan)?
---
--- Reads `frihet` the same way `booking/routes.lua` already does -- through
--- `FredPD.Repo.frihet` and `FredPD.Modules.frihet.isOpen`, never `frihet`'s
--- own internals -- so this module cannot drift from what `frihet` itself
--- considers "in custody". A handful of rows, newest first: in practice a
--- person has at most one open chain, but nothing enforces that as a
--- uniqueness constraint, so this checks rather than assumes it.
local function custodyOpenFor(agencyId, personId)
    local chains = frihetRepo.list(agencyId, { personId = personId }, 5)

    for index = 1, #chains do
        if frihetService.isOpen(chains[index]) then return true end
    end

    return false
end

--- The share of a grid cell this player's traces are counted against (12.2).
---
--- One value per player, which is the property the per-cell cap needs and the
--- one `ownerKey` deliberately does not have: a print is filed under a character
--- identifier, a casing under a weapon serial with no identifier at all, and a
--- magazine under both (8.3.4), so a cap counting owners would give one client
--- three shares of every cell and a fourth for every further weapon -- enough to
--- fill a cell and refuse everybody else's evidence a place to land.
---
--- The character identifier when there is one, so a player who changes weapons,
--- reconnects on a new server id or swaps clothes keeps the same share. The
--- server id is the fallback for a player the framework cannot resolve: it is
--- stable while they are connected, which is as long as they can generate
--- anything, and it is prefixed so it can never collide with an identifier.
---
--- It never leaves the server. Nothing in `Evidence.renderData` carries it and
--- no route returns it (8.11).
local function sourceKeyFor(src)
    return identifierOf(src) or ('@' .. tostring(src))
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
--- Since the sensor route became public (ADR-013, and see the route below) these
--- ceilings are not a second line of defence -- they are the only one. There is
--- no permission in front of them, no session, no duty check and no context
--- condition: between a hostile client looping `kind = 'surface'` and the grid
--- there is the route's limit and then the kind's, and nothing else at all.
--- Every number in this table is load-bearing and none of them may be raised
--- without asking what it would cost to have it spent in full.
---
--- A rule answers a trace, or nil. Nil is an ordinary outcome and not an error:
--- four shots in five leave no casing, and a call that legitimately creates
--- nothing must look exactly like one that does (8.11).
local RULES <const> = {
    --- A shot. Casings are sampled, never one per shot (8.2, 12.2).
    shot = {
        limit = { per = 150, window = 30 },
        make = function(src, _input, position)
            -- Residue first, and unconditionally (8.2). It is not sampled the
            -- way casings are: sampling decides how much brass ends up littering
            -- the ground, while residue is one state per player that firing
            -- either created or refreshed -- so every one of the four shots in
            -- five that leave no casing still leaves residue on the hands that
            -- fired them. It does not wait on the weapon read either: a server
            -- with no inventory bridge cannot say which gun it was, and residue
            -- does not carry a gun. The per-kind limit above is what bounds how
            -- often a client can set it.
            gsr.mark(src)

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

    --- Drinking, eating, smoking, handling drugs: touch DNA on the thing they
    --- handled, or drug residue when the item was one (8.2). Gloves do not help
    --- against either -- saliva is not a fingerprint and residue is not a print
    --- either.
    ---
    --- The item name is the client's word, same as a door index is, and is
    --- worth exactly as little: it decides which of the two labels this trace
    --- gets, both of which the server would have created from the fact of the
    --- call alone. Its own list of drug items -- `config.drugItems`, empty by
    --- default -- is what a name is checked against, and anything else,
    --- including no name at all, is touch DNA, which is what this rule always
    --- produced before drug residue existed as an outcome.
    item_use = {
        limit = { per = 15, window = 30 },
        make = function(src, input, position)
            local identifier = identifierOf(src)
            if not identifier then return nil end

            local drugItems = config.drugItems or {}
            local isDrug = type(input.itemName) == 'string' and drugItems[input.itemName] == true

            return {
                type = isDrug and 'drug_residue' or 'dna_touch',
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

    -- Who is generating, for the per-cell share (`service.sourceKeyOf`). Read
    -- here from the caller the server resolved, never from the rule's output:
    -- the owner a rule chooses is deliberately not one value per player -- a
    -- casing carries a weapon serial and no identifier (8.3.4) -- so counting
    -- the share by owner would hand one client several shares of every cell.
    trace.sourceKey = sourceKeyFor(src)

    grid.place(trace)

    return true
end

-- -----------------------------------------------------------------------------
-- The sensor route (8.3.1)
-- -----------------------------------------------------------------------------

--- The sensor route, open to every player (8.3.1, 8.3.4, ADR-013).
---
--- Public, and it has to be. M3 shipped this with `perm =
--- 'forensics.trace.report'`, which meant `route.define` opened a session first
--- and `FredPD.Core.session.open` only opens one for a player with an
--- `fpd_officers` row -- so every criminal in the city got `no_session` and left
--- no prints, no casings and no blood behind them. 8.3.4 says the owner of a
--- trace is whoever left it, and `identifierOf` above says in as many words that
--- it works for every player because the criminal is the point of the section.
--- The comment was right and the route was wrong.
---
--- What that costs is every check `route.define` performs, and each one is worth
--- naming so nobody restores one by reflex:
---
---   * **no permission and no session.** That is the fix, not a side effect.
---   * **no staleness tier.** There was nothing to refuse here anyway: a stale
---     Discord snapshot must not stop the world from leaving traces in it (4.2),
---     and nothing on this path writes to the database -- collection does, and
---     collection is an officer's route with a session behind it.
---   * **no audit row.** An audit entry is attributed to a `discordId` and a
---     public caller has no session to take one from, so there is nothing to
---     attribute one to. It would have been wrong with a session too: every shot
---     fired in the city as an audit row is a log nobody can read, which is not
---     a control (invariant 11). The grid keeps totals for the health screen,
---     and what comes out of a trace is audited when it is collected.
---
--- Which leaves the limits below, and the per-kind ones in `RULES`, as the whole
--- of what stands between a client and the grid.
route.public({
    name = 'forensics.observe',
    schema = 'ForensicsObserve',
    -- The route's own ceiling, above the per-kind ones. Generous, because the
    -- kinds are what actually bound this; a client that reaches this has already
    -- been refused by every kind budget it spent.
    limit = { per = 300, window = 60 },
    handler = function(src, input)
        observe(src, input.kind, input)

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

--- How far a hit may be from the shooter before the server stops believing it.
---
--- The event's `hitGlobalIds` are network ids chosen by the sender's client, so
--- without a bound a modified client can name players anywhere on the map and
--- have their blood -- their hidden identifier, at their own coordinates --
--- written into the grid by somebody else's gun. That is the framing 11.3 warns
--- about, reachable forty times per ten seconds.
---
--- `entityRange` is the wrong number to bound it with: six metres is the reach a
--- *sensor* may name an entity at, and a rifle shot crosses thirty times it, so
--- reusing it here would delete blood from every shooting that was not a scuffle.
--- This is the other kind of bound -- the longest engagement the game's weapons
--- can actually produce -- and its job is only to keep a hit inside the fight it
--- claims to belong to. It is not a marksmanship model, and a client can still
--- name a bystander standing near its victim; what it takes away is the whole
--- map.
local MAX_HIT_METRES <const> = 250.0

--- How close the attacker has to be standing to the blood they just drew for
--- it to be plausible that they stepped in it (8.2, "footwear... through
--- blood").
---
--- This is the one footwear trigger this file implements, and it is
--- deliberately narrower than 8.2's full list. "Walking on soft ground or
--- snow" needs the server to know what a player is standing on, which nothing
--- server-side can answer without either trusting a client's word for its own
--- material or polling every connected player's position against the world
--- forever -- the first is the class of claim 11.3 bans and the second is the
--- always-running cost 12.1's "0.00 ms with the MDT closed" budget exists to
--- refuse. "Through blood" is different: the server already knows exactly
--- where blood was just placed, from its own event, so checking who was close
--- enough to have stepped in it costs one distance check on a hit that was
--- going to run anyway. A melee attacker or a close-range shooter is inside
--- this; a sniper forty metres off is not, correctly -- they were never near
--- the blood to walk through it.
local FOOTWEAR_RANGE_METRES <const> = 2.0

--- Blood, and the bullet that drew it, from `weaponDamageEvent`.
---
--- 8.3.3 is explicit that this pair may never come from a *sensor* claim, and it
--- does not have to: `weaponDamageEvent` reaches the server with both ends of
--- the exchange in it. The attacker is the sender, which the server resolved and
--- which no payload field can move.
---
--- Everything else in `data` is the sender's client talking, and is treated that
--- way: the hit ids are checked for type, resolved to entities the server looks
--- up itself, required to be players (`playerForEntity` maps a ped handle to a
--- server id from the server's own table), and required to be inside
--- `MAX_HIT_METRES` of where the server says the attacker is standing. The
--- position, the identifier and the weapon are all read here and none of them
--- are in the payload at all.
---
--- What is still the client's word is whether a hit happened and how hard: a
--- sender that reports a hit on the player standing next to it gets that
--- player's blood on the ground. Short of simulating ballistics on the server
--- there is no cure for that, and the rate limit plus the distance bound is what
--- keeps it to a nuisance rather than a framing tool.
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

    -- Where the server says the shooter is. Nothing is written when it cannot
    -- say, because every hit below is measured against it.
    local from = positionOf(attacker)
    if not from then return end

    local weapon = heldWeapon(attacker)

    for index = 1, #hits do
        local netId = hits[index]
        -- A network id, and a number before it is one: the payload is the
        -- sender's and `NetworkGetEntityFromNetworkId` raises on a string. A
        -- raise inside a game-event handler is not caught by a route wrapper,
        -- because this is not a route.
        local entity = type(netId) == 'number' and NetworkGetEntityFromNetworkId(netId) or 0

        if entity ~= 0 and DoesEntityExist(entity) then
            local at = GetEntityCoords(entity)
            local dx, dy, dz = at.x - from.x, at.y - from.y, at.z - from.z
            local victim = playerForEntity(entity)
            local identifier = victim and identifierOf(victim)

            -- Only players, and only players the shooter could plausibly have
            -- hit. An NPC has no hidden identifier, so their blood could never
            -- be matched to anything and would be a row the lab returns "no
            -- profile" for, forever; a player on the other side of the map was
            -- not in this exchange at all, whatever the payload says.
            if identifier and (dx * dx + dy * dy + dz * dz) <= (MAX_HIT_METRES * MAX_HIT_METRES) then
                -- The blood is the victim's and the share is the attacker's:
                -- the person generating traces here is the one pulling the
                -- trigger, and a cap that counted the victim's share would let
                -- a shooter spend other people's (8.3.3, 12.2).
                grid.place({
                    type = 'blood',
                    x = at.x,
                    y = at.y,
                    z = at.z,
                    owner = { identifier = identifier },
                    sourceKey = sourceKeyFor(attacker),
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
                        sourceKey = sourceKeyFor(attacker),
                    })
                end

                -- Footwear, when the attacker was close enough to the blood
                -- to have stepped in it (see `FOOTWEAR_RANGE_METRES`). The
                -- attacker's own identifier, not the victim's: this is a
                -- print of whoever was standing there, and that is the
                -- person who just landed the hit.
                local attackerIdentifier = identifierOf(attacker)

                if attackerIdentifier then
                    local fx, fy, fz = at.x - from.x, at.y - from.y, at.z - from.z

                    if (fx * fx + fy * fy + fz * fz) <= (FOOTWEAR_RANGE_METRES * FOOTWEAR_RANGE_METRES) then
                        grid.place({
                            type = 'footwear',
                            x = at.x,
                            y = at.y,
                            z = at.z,
                            owner = { identifier = attackerIdentifier },
                            sourceKey = sourceKeyFor(attacker),
                        })
                    end
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
-- Live identity scan (8.8) -- the fingerprint scanner's second action
-- -----------------------------------------------------------------------------

--- Who is standing at the scanner, if their prints are already on file.
---
--- Deliberately narrower than a database hit against a hashed profile: the
--- server already knows exactly who this live character is (`identifierOf`
--- reads it straight off the ped, the same as every sensor in this file), so
--- there is no comparison to make and no fingerprint value this route ever
--- needs to touch -- only whether a reference for that exact identifier has
--- ever been filed (`hasFingerprintReference`, an equality check the
--- database does).
---
--- Refuses on a free subject rather than answering "no match": a live scan
--- discloses whether a specific person has a criminal fingerprint record,
--- which is an identity disclosure, not a records search, and every other
--- disclosure this suite makes at that level sits behind a procedural
--- condition (a warrant, a court decision, or here, that the subject is
--- already held under an open custody chain) rather than an on-duty
--- officer's discretion alone.
route.define({
    name = 'forensics.identity.scan',
    perm = 'forensics.identity.scan',
    context = { onDuty = true },
    schema = 'ForensicsIdentityScan',
    sensitive = true,
    audit = 'forensics.identity.scanned',
    subjectType = 'person',
    -- Section 11's whole point is a check on the officer, not on the person
    -- scanned: a live scan is an identity disclosure gated on custody, and
    -- an oversight reader has to be able to ask, from the log alone, who was
    -- scanned and whether it was a legitimate custody -- both the target and
    -- the match, not just whether the call happened. `targetId` is an
    -- ephemeral session id, not stored identity, so it costs nothing extra
    -- to keep; `personId` is only present at all once a match already
    -- disclosed it to the officer, so this is not a second copy of anything
    -- the officer did not already see.
    auditDetail = function(input, result) return {
        targetId = input.targetId,
        match = result.match == true,
        personId = (result.person and result.person.id) or nil,
    } end,
    handler = function(session, input)
        local at = positionOf(input.targetId)
        if not at then return route.refuse(FredPD.ErrorCode.NOT_FOUND, { targetId = 'unreachable' }) end

        local here = positionOf(session.src)
        if not here then return route.refuse(FredPD.ErrorCode.NOT_FOUND) end

        local dx, dy, dz = at.x - here.x, at.y - here.y, at.z - here.z
        if (dx * dx + dy * dy + dz * dz) > (config.collectRange * config.collectRange) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'out_of_range' })
        end

        local identifier = identifierOf(input.targetId)
        if not identifier then return { match = false } end

        local personId = personsRepo.byIdentifier(session.agencyId, identifier)
        if not personId then return { match = false } end

        if not custodyOpenFor(session.agencyId, personId) then
            return route.refuse(FredPD.ErrorCode.CONFLICT, { targetId = 'not_detained' })
        end

        if not FredPD.Repo.evidence.hasFingerprintReference(session.agencyId, identifier) then
            return { match = false }
        end

        -- The same access-checked path every other read of a person goes
        -- through (invariant 4): a match against somebody sealed beyond this
        -- officer's clearance answers restricted, never a name.
        local person, visibility = personsRepo.readPerson(session, personId)
        if not person then
            return route.refuse(
                visibility == 'missing' and FredPD.ErrorCode.NOT_FOUND or FredPD.ErrorCode.RESTRICTED)
        end

        return {
            match = true,
            person = {
                id = person.id,
                personNumber = person.personNumber,
                firstName = person.firstName,
                lastName = person.lastName,
            },
        }
    end,
})

-- -----------------------------------------------------------------------------
-- Destroying evidence (8.10) -- which is not a police feature
-- -----------------------------------------------------------------------------

--- `fredpd_forensics/client/destroy.lua` is the caller, and 8.10 is the reason
--- this is a `route.public`: destruction is "available to every player through
--- ox_target, subject only to item and context rules. Police-only restrictions
--- must never block criminal gameplay (a bug in the reference script)." A
--- criminal has no `fpd_officers` row, therefore no session, therefore no
--- permission -- so a permission here would not restrict the feature, it would
--- delete it for everybody it was written for.
---
--- Three rules hold this route together.
---
---   1. **The answer is always empty.** `{}` whether it destroyed six traces,
---      one or none. A count is the oracle 8.11 forbids: a player could wipe a
---      door handle they never touched and be told how many people had, or scrub
---      a pavement to learn whether anybody bled on it -- evidence they were
---      never streamed, learned from an action anyone may take.
---   2. **One refusal may be distinguished, and it is about their pockets.**
---      `conflict` means "you have no item", which is the one thing the player
---      can already see for themselves, and the client maps exactly that code to
---      that message. Everything else is a generic failure, deliberately, so
---      that no refusal carries a fact about the world.
---   3. **Nothing is destroyed until the cost is paid.** The item is checked and
---      removed first; a refusal leaves the world untouched, and the timed action
---      the client already spent is the only thing lost.
---
--- One audit row, and only the one there is somebody to sign. A criminal has no
--- session and no `discordId`, so there is nothing to attribute a row to and
--- none is written (ADR-013) -- that is the case this whole tier exists for. An
--- officer destroying evidence is the opposite case, and the server can tell
--- them apart: `auditDestruction` below writes a row when, and only when, the
--- caller turns out to hold a session. The grid's `destroyed` counter is what a
--- server watching its evidence disappear reads for everybody else (12.3), and
--- it is a total with no player and no trace in it.

--- The actions that spend no item, and the two different reasons they do not.
---
--- `wash` and `pickup` cost nothing by design (8.10, 8.1.5: "costs time and
--- items"). A sink is a sink and a hand is a hand, and charging for them would
--- make walking back for your own casings something only a prepared player could
--- do.
---
--- `weapon` costs nothing because it *does* nothing. `ACTIONS.weapon` below is
--- an empty function and says why: the prints and the touch DNA a weapon carries
--- are not modelled anywhere, so there is no state for a kit to take off it.
--- 8.10 asks for a wiping kit on weapons and the action is kept for it, but the
--- half of the mechanic that exists is the timed one -- the eight seconds the
--- client counts out -- and that is now the whole of what it costs. Spending a
--- kit on a documented no-op is charging for nothing, which is the one thing
--- worse than a mechanic that is not finished. When a seized weapon starts
--- carrying recoverable trace, `weapon` comes back out of this table and the
--- `destroyItems.weapon` name -- still configured, and read by nothing while
--- this entry stands -- starts being spent again.
---
--- Everything else spends an item, and an action that is not in here and has no
--- configured item name cannot be paid for -- see `spend`.
local FREE <const> = { wash = true, pickup = true, weapon = true }

--- The item an action spends, or nil when its name is not configured.
---
--- The names live in `Forensics.defaults.destroyItems` and are overridden per
--- server under `forensics.destroyItems` in `config/server.lua`; `settings()` is
--- the merge of the two and is the table read here. There is deliberately no
--- second copy in this file: two tables of item names drift apart the first time
--- somebody configures one of them, and the one that is wrong is always the one
--- nobody is reading.
---
--- `wipe` and `weapon` are the same kit by default -- 8.2 names one wiping kit
--- for surfaces and for weapons -- but that is the configuration's decision and
--- not this file's. `weapon` is not asked for here today: it is in `FREE` above
--- for as long as wiping a weapon has nothing to remove, so the only name this
--- function is ever called with in the product is `wipe` or `clean`.
local function itemFor(action)
    local configured = config.destroyItems
    if type(configured) ~= 'table' then return nil end

    local name = configured[action]

    return type(name) == 'string' and name or nil
end

--- Spends what the action costs, before anything is destroyed.
---
--- `hasItem` and then `removeItem`, and it is the second one that decides:
--- anything checked before the client's progress bar could have been dropped
--- during it, so a check that passed is not a payment. `removeItem` answering
--- false is a refusal, never a free wipe (8.1.5).
---
--- No inventory bridge is also a refusal. That is the bridge's own documented
--- stance -- unknown answers false, because a server that cannot spend a kit
--- must not be able to wipe a scene for nothing -- and the client's message for
--- it, "you have no item", is as close to the truth as a player needs.
---
--- A costed action with no configured item name is refused for the same reason
--- and reads to the player the same way. It is the one case where refusing is
--- the *unsafe-looking* answer and still the right one: a server that has
--- emptied `destroyItems` has broken its own configuration, and the alternative
--- is a wiping kit that costs nothing at all.
---
--- @param src number
--- @param action string
--- @return boolean whether the cost was paid
local function spend(src, action)
    if FREE[action] then return true end

    local item = itemFor(action)
    if not item then return false end

    local bridge = FredPD.Bridge and FredPD.Bridge.inventory
    if not bridge or not bridge.removeItem or not bridge.hasItem then return false end

    if not bridge.hasItem(src, item, 1) then return false end

    return bridge.removeItem(src, item, 1) == true
end

--- Writes the one audit row this route can write (invariant 11).
---
--- Destruction is open to every player and most of its callers have no identity
--- at all, so there is usually nothing to attribute a row to. When there *is* --
--- the caller holds a FredPD session, which means they are an officer -- the
--- audit log is exactly the place that belongs: an officer wiping a scene down
--- is the act the log exists for, and the row names them and the action and
--- nothing else. Not which traces went, not how many, not whose: the log is read
--- by more people than the scene was worked by (8.11).
---
--- It lives here, outside the handler, because a `route.public` handler may not
--- name `FredPD.Core.session` -- `tools/wiring-check.ts` reads the handler body
--- and fails the build on it, and the claim it protects (a public handler holds
--- a server id and no identity, so it cannot reach a record) is still true of
--- the handler: this function reaches no record either. It reads one field off a
--- session that may not exist and writes an append-only row.
---
--- Silent when there is no session, which is the ordinary case.
---
--- The session a player *already has*, and never one opened for them.
--- `Session.get` opens on first use and does not cache a miss, so for a caller
--- with no `fpd_officers` row -- which is who this route is for -- it costs a
--- framework character lookup and a blocking `SELECT` on `fpd_officers` every
--- single call, thirty a minute per player, returning nothing and remembering
--- nothing. That is the shape `server/main.lua` rate-limits ahead of the session
--- lookup rather than behind it (11.1, 12.1). `Session.all()` is the same
--- non-opening read the grid's `isPrivileged` uses, and it answers the question
--- this function actually asks: is the caller an officer who is already here.
---
--- @param src number
--- @param action string the action that was carried out
local function auditDestruction(src, action)
    local session = FredPD.Core.session.all()[src]
    if not session then return end

    FredPD.Core.audit.write({
        action = 'forensics.destroyed',
        discordId = session.discordId,
        agencyId = session.agencyId,
        detail = { action = action },
    })
end

--- What a wiping kit takes off a surface (8.2, 8.10).
---
--- 8.2's "Removed or reduced by" column names the wiping kit for exactly two
--- types: latent fingerprints, and the glove marks and fibers left instead of
--- them. Those two, and no others.
---
--- Blood is not in here and must not be: 8.10 says cleaning leaves something
--- luminol still finds, and `Grid.wipeAround` deletes the row outright. A wiping
--- kit that removed blood would destroy the one trace in the spec with a named
--- counter-mechanic, silently, and the officer with the luminol would find
--- nothing where the model says they should find a quarter of a profile.
---
--- `tool_mark` is not in here either, and used to be. 8.2 removes tool marks and
--- broken glass by **repair**, not by wiping -- a crowbar's serrations are cut
--- into the door frame and a cloth does not lift them out. Wiping them away for
--- the price of one kit deleted the only trace tying a burglar's tool to the
--- scene and left 8.7's tool comparison with nothing to run on.
local WIPEABLE <const> = { print = true, glove_mark = true }

--- How far one wiping kit reaches from its centre, in metres
--- (`Forensics.defaults.wipeRadius`, overridable under `forensics` in
--- `config/server.lua`).
---
--- `entityRange` used to stand here, and it is the wrong number twice over: it
--- is the reach the *sensor* side accepts an observation from, six metres, and
--- it was being spent again on top of the six metres `entityNear` had already
--- allowed between the player and the entity. A client naming any networked car
--- six metres away cleared every print within six metres of it -- twelve from
--- where the server said the caller stood, four times the three metres an
--- officer needs to bag one of them, and a block at a time by hopping between
--- parked cars. A cloth reaches as far as an arm does.
local wipeRadius = config.wipeRadius

--- What cleaning chemicals work on (8.2).
local CLEANABLE <const> = { blood = true }

--- What a hand picks up off the ground (8.2, 8.10).
---
--- `bullet` is absent for the reason the client file gives: 8.2 says a bullet is
--- dug out, which is a recovery action with a tool. The server keeps its own
--- copy of this set rather than trusting the prompt that was drawn, because a
--- prompt is a client's claim and this is the list that decides.
local PICKABLE <const> = { casing = true, magazine = true }

--- Is this trace within `range` of where the server says the player is (8.3.2)?
local function within(item, position, range)
    local dx, dy, dz = item.x - position.x, item.y - position.y, item.z - position.z

    return (dx * dx + dy * dy + dz * dz) <= (range * range)
end

--- A point on the line from the player to `at`, no further away than `limit`.
---
--- What this is for is reach that stacks. Anything a client names -- a car, a
--- door -- has already been allowed to be `entityRange` away from the player,
--- and using its position as the centre of a radius adds that radius on top:
--- the two ranges sum, and the total is the one a player actually exploits. So
--- the centre is pulled back along the same line until the whole affected
--- sphere fits inside one range of where the server says the player is.
---
--- Returns `at` itself when it is already inside the limit, and the player's own
--- position when the two coincide -- there is no direction to move along then,
--- and the player is the honest answer either way.
---
--- @param position vector3 the server's copy of where the player is
--- @param at vector3 where the thing they named is
--- @param limit number metres
--- @return table|vector3 a point with x, y and z
local function clampToward(position, at, limit)
    local dx, dy, dz = at.x - position.x, at.y - position.y, at.z - position.z
    local distance = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))

    if distance <= limit then return at end
    if distance == 0 then return position end

    local scale = limit / distance

    return {
        x = position.x + (dx * scale),
        y = position.y + (dy * scale),
        z = position.z + (dz * scale),
    }
end

--- The sink and shower models 8.2 destroys residue at, as model hashes.
---
--- The set is the server's, and it decides -- but only for a sink the server can
--- resolve, which today means a networked one. `READY.wash` below says plainly
--- what that does and does not cover, and it is worth reading before this list
--- is trusted as a gate.
---
--- **There are two of these lists and nothing keeps them in step.** This one is
--- read from `forensics.washModels` in `config/server.lua` (a Lua table of model
--- names, which replaces this default whole rather than adding to it, because a
--- server that names its own sinks has said which sinks it has). The other is in
--- `fredpd_forensics/client/destroy.lua`, which decides which prompt is *drawn*
--- and reads the replicated convar `fredpd:forensics:washModels`, comma
--- separated. Neither is derived from the other, and an operator who configures
--- one has silently changed half of washing: set only the convar and the server
--- refuses the new sink; set only `forensics.washModels` and no prompt is drawn
--- at the sinks it accepts. Until one source feeds both, a server that changes
--- either must change both. Neither is documented in the `forensics` block of
--- `config/server.lua`, which is a gap this file cannot close from here.
---
--- Names are hashed once at load because `GetEntityModel` answers a hash, and
--- folded to unsigned because the two natives disagree about the sign: `joaat`
--- answers an unsigned 32-bit value and `GetEntityModel` a signed int32, so four
--- of the twelve names below (`prop_sink_01`, `prop_sink_02`,
--- `prop_shower_glass01`, `v_ilev_shwr2` -- every one with the high bit set)
--- were stored under one number and looked up under another, and washing at them
--- could not be made to work. `server/bridges/appearance.lua` carries the same
--- fold and the same warning.
---
--- A model name is not a world position, so this is not a placement (3.10): the
--- same sink model is a sink wherever it stands, including in a house nobody
--- configured.
local DEFAULT_WASH_MODELS <const> = {
    'prop_sink_01', 'prop_sink_02', 'prop_sink_03',
    'prop_sink_04', 'prop_sink_05', 'prop_sink_06',
    'v_res_mbsink', 'v_res_fa_sink1', 'v_ilev_bs_sink',
    'prop_shower_rail', 'prop_shower_glass01', 'v_ilev_shwr2',
}

local WASH_MODELS <const> = (function()
    local configured = config.washModels
    local names = type(configured) == 'table' and configured or DEFAULT_WASH_MODELS
    local hashes = {}

    for index = 1, #names do
        local name = names[index]

        -- Both branches folded into the unsigned range, and the lookup in
        -- `READY.wash` folded the same way. A configured numeric hash may have
        -- been copied out of either native, so it gets the same treatment as a
        -- name.
        if type(name) == 'string' then
            hashes[joaat(name) % 0x100000000] = true
        elseif type(name) == 'number' then
            hashes[name % 0x100000000] = true
        end
    end

    return hashes
end)()

--- Checks that run *before* the item is spent, per action.
---
--- Refusing here leaves both the world and the player's pockets untouched, which
--- is the order 11.3 asks for: nothing is charged for an action that was never
--- going to happen. An action with no entry needs no such check.
local READY = {}

--- Something has to be in their hands, and the server says what (8.3.2).
---
--- Read through the inventory bridge exactly as the generation pipeline reads
--- it; nothing about the weapon comes from the call. An empty-handed player is
--- refused before they pay for a kit they would have rubbed on nothing.
function READY.weapon(src)
    return heldWeapon(src) ~= nil
end

--- The kit has to have a sane reach configured before anybody pays for it.
---
--- `wipeRadius` comes from `Forensics.defaults` and is a number on every server
--- that has not gone out of its way to make it something else. A server that has
--- is refused here, before the kit is spent, rather than having this file invent
--- a radius of its own: a second default is how the two drift apart, and a wipe
--- at a guessed radius is exactly the bug this route was repaired for.
---
--- A type check alone was not that. `ACTIONS.wipe` pulls the centre of the
--- sphere back to `entityRange - wipeRadius` from the player so that the whole
--- of it fits inside their own reach, and that subtraction floors at zero: at a
--- configured radius above `entityRange` the clamp collapses to the player's own
--- position and the oversized sphere is then used from there. Thirty metres
--- configured is thirty metres wiped, ten times `collectRange`, from a check
--- that reported the configuration was fine. So the band is checked and not
--- merely the type: positive, and no wider than the reach every other entity
--- rule in this file is measured against.
function READY.wipe()
    return type(wipeRadius) == 'number'
        and wipeRadius > 0
        and wipeRadius <= config.entityRange
end

--- A named sink has to be a sink -- and an unnamed one cannot be checked at all.
---
--- 8.2 destroys residue by "washing at sinks and showers", and this is as much
--- of that as a server can enforce today. Read both halves before changing it,
--- because both have already shipped as bugs.
---
--- **When the call names an entity**, all three checks apply, every time: the
--- network id resolves, the entity is within reach of where the server says the
--- player is (8.3.2), and its model is in the set above. That is the honest
--- gate, and it is the one that works for sinks a resource spawns as networked
--- objects.
---
--- **When the call names nothing**, the wash is allowed. That is not a gate and
--- is not dressed up as one. The reason is that the props 8.2 actually means are
--- part of the map: `prop_sink_01` and the rest are static, `NetworkGetEntityIs
--- Networked` is false for them, they have no network id for any client to send,
--- and there is no server native that can look one up from a position. Requiring
--- an id therefore does not make washing stricter, it deletes it: the only wash
--- prompt in the game is `ox_target:addModel` over exactly that list of map
--- props (`fredpd_forensics/client/destroy.lua`), so every wash in the product
--- sent no id, was refused after the player had stood through nine seconds of
--- progress bar, and `gsr.clear` became unreachable -- with residue then ending
--- only by decay, which is half of 8.2's row and none of 8.10's [M] mechanic.
---
--- So what stands between a player and washing in a field is the client's own
--- prompt, and invariant 4 is explicit that a client-side control is not a
--- control. This is a known, stated hole and not a claim: a player with a
--- modified client can clear their own residue anywhere, which costs them the
--- nine seconds and no item, and is a smaller exploit than the one the strict
--- version created (nobody can wash at all). Closing it properly needs a change
--- neither this file nor the satellite can make alone -- a networked stand-in
--- object at each sink, a `placement` kind for washing points (3.10), or a
--- server-verifiable claim in `ForensicsDestroy` -- and that is a spec decision,
--- recorded in the report rather than invented here.
function READY.wash(_src, input, position)
    if input.netId == nil then return true end

    local entity = entityNear(input.netId, position)
    if not entity then return false end

    -- Folded unsigned to match how the set was built. `GetEntityModel` answers a
    -- signed int32 and `joaat` an unsigned one.
    return WASH_MODELS[GetEntityModel(entity) % 0x100000000] == true
end

--- The five actions of 8.10. Each one has already been paid for.
---
--- None of them returns anything, and the counts the grid answers are read by
--- nobody on purpose (8.11). They take the *server's* position, and where an
--- entity is involved they take the entity's -- never a coordinate from the
--- call, which does not carry one.
local ACTIONS = {}

--- The wiping kit on a surface: blind, and it has to be.
---
--- The prints on a door handle are invisible, so a player wiping one is acting
--- on a place and not on a trace they can see -- there is no key and there must
--- not be one. What is bounded instead is the reach, and it is bounded once:
--- `wipeRadius` is how far the cloth goes, and the centre is pulled back along
--- the line to the player until the whole sphere fits inside `entityRange` of
--- them. The two ranges no longer add up -- naming a car at the far edge of
--- `entityRange` now wipes a sphere that still ends where the player's own reach
--- ends, instead of one that ends twice as far out. That holds because
--- `READY.wipe` has already refused a `wipeRadius` wider than `entityRange`:
--- above it the subtraction below floors at zero, the clamp collapses to the
--- player's own position and the oversized sphere is used from there, which is
--- the sentence above stopping being true.
---
--- A network id that resolves to nothing near them falls back to the player's
--- own position rather than refusing. The two cases are the same case a second
--- apart: an unnetworked map prop never had an id, and a car that has driven off
--- no longer has one that resolves. Both leave somebody scrubbing where they
--- stand, and the fallback can never reach further than the player is, so it
--- buys a client nothing that sending no id at all would not.
function ACTIONS.wipe(_src, input, position)
    local at = position

    if input.netId then
        local _, entityAt = entityNear(input.netId, position)

        if entityAt then
            at = clampToward(position, entityAt, math.max(config.entityRange - wipeRadius, 0))
        end
    end

    grid.wipeAround(at.x, at.y, at.z, wipeRadius, WIPEABLE)
end

--- The wiping kit on a weapon -- and what that does and does not model.
---
--- Nothing is removed from the grid here, and that is not an oversight. The
--- prints and the touch DNA a weapon carries are on the *item*: they are not
--- traces lying in the world, they have no position, they are not streamed and
--- there is nothing in the grid that represents them. Where they would be
--- recovered is when the firearm is seized and submitted -- 8.5's firearm box,
--- 8.7's comparison -- and that path does not read a wiped flag off the weapon
--- yet, because there is nowhere on an ox_inventory item's metadata that FredPD
--- owns to put one (8.1.2 keeps item metadata to references and seal state).
---
--- So what a player buys today is the eight seconds the client counts out, and
--- the effect is exactly nothing. It used to be the eight seconds *and* a wiping
--- kit, which is the part that had to go: 8.10 says the mechanic costs time and
--- items, and charging the item for a documented no-op is taking a kit off a
--- player in exchange for a progress bar. `weapon` is therefore in `FREE` above
--- and `spend` never looks its item name up -- the time cost stands, the item
--- cost waits for the model, and the two come back together.
---
--- What the player still cannot tell from the outside is that anything is
--- missing: the action answers `{}` like the other four (8.11) and the client
--- draws the prompt, runs the bar and says "done". Telling them would be honest
--- and it is not a leak -- a refusal that fires every time, for every player,
--- discloses nothing about the world -- but it is not a change this file can
--- make on its own: the message would be a new key in both `locales/*.json`, a
--- refusal `fredpd_forensics/client/destroy.lua` maps to it, and probably a
--- prompt that stops being drawn at all. It is written down in the report
--- instead of being half-done here.
---
--- When a seized weapon starts carrying recoverable prints, this function is
--- where the flag is cleared -- and until then nothing here should pretend
--- otherwise by deleting a casing or a trace the weapon has nothing to do with.
function ACTIONS.weapon()
end

--- Cleaning chemicals on a named pool of blood (8.10).
---
--- `Grid.clean` marks and does not delete: the pool stays where it is, invisible
--- to the eye, findable with luminol, and worth a quarter of the DNA it was
--- worth before. Everything below refuses by doing nothing and answering `{}`
--- (8.11): a key that names no trace, a key that names something that is not
--- blood, and a trace across the street all look identical from the client, and
--- the first of them is the ordinary case where somebody else cleaned it first.
---
--- The type check is the server's and not the prompt's, and it is not a
--- formality: `Grid.clean` makes a trace latent, and `powder`, `luminol` and the
--- forensic light between them reveal a fixed set of types. Cleaning a casing
--- would therefore not destroy it -- it would hide it from every tool in the
--- game, permanently, for the price of one bottle.
---
--- Two more refusals, one of them the visibility check `FredPD.Evidence
--- .claimTrace` makes below, and they are here for a sharper reason than
--- tidiness. `Grid.clean` sets `revealed = false`, and this route is public: with
--- no visibility check, any player -- no session, no permission, no kit anybody
--- can see -- could spend one bottle to un-reveal a pool of blood an officer's
--- luminol had just found, and keep doing it for as long as they had bottles.
--- The officer's tool would appear to stop working. So a trace that has already
--- been cleaned is left alone (cleaning it twice changes nothing anyway), and a
--- latent trace nobody has revealed is left alone (it has not been found, so
--- there is nothing to hide).
---
--- Both refuse by doing nothing at all, after the bottle has been spent. That is
--- deliberate and it is the second half of the same rule: refusing *before* the
--- cost would make this route answer one thing where blood had been revealed and
--- another where it had not, which is the oracle 8.11 forbids -- and it is worth
--- more to a suspect than the bottle is. A key that names no trace, a key that
--- names a casing, a trace across the street, one somebody else cleaned first
--- and one the powder has never touched all cost the same and all answer `{}`.
function ACTIONS.clean(_src, input, position)
    if not input.traceKey then return end

    local item = grid.peek(input.traceKey)
    if not item then return end

    if not CLEANABLE[item.type] then return end
    if item.cleaned then return end
    if item.latent and not item.revealed then return end
    if not within(item, position, config.collectRange) then return end

    grid.clean(input.traceKey)
end

--- Washing at a sink or a shower (8.2, 8.10).
---
--- Residue is on the player, so there is nothing in the world to name and no key
--- to send; whose hands these are comes from the source of the call and from
--- nowhere else. `READY.wash` has run by here, which means either the call named
--- a sink the server resolved and recognised, or it named nothing -- the
--- ordinary case for a map prop, and the hole `READY.wash` documents. Either
--- way the only question left here is whose hands, and that one the call cannot
--- answer.
---
--- Whether there was any residue to wash off is deliberately dropped on the
--- floor. `gsr.clear` answers it because the server needs the difference; a
--- player who learned it would have a detector that told them whether a swab
--- would have found anything, which is the same oracle rule 1 above is about.
function ACTIONS.wash(src)
    gsr.clear(src)
end

--- Picking casings and magazines up off the ground (8.10).
---
--- Two paths, and the distance check is the same one in both, measured against
--- the server's copy of where the player is (8.3.2). With a key, the trace it
--- names has to be a type a hand picks up and has to be within `collectRange`.
--- Without one -- the case where the brass was never inside the player's
--- streaming range, so no key for it ever reached them -- everything pickable
--- within that same reach goes, blind, exactly as wiping is blind.
---
--- Nothing is minted into an inventory, here or anywhere on this path. An item
--- handed out per casing picked up would be the duplication path 11.3 warns
--- about, and the mechanic 8.10 describes is making the evidence stop existing,
--- not acquiring it.
---
--- Both paths destroy rather than collect, and the counter they move says so.
--- `Grid.take` is collection -- it is what `claimTrace` calls when an officer
--- bags something -- and the keyed path here used to call it, so a criminal
--- pocketing their own brass was counted on the admin health screen as officers
--- bagging it (12.3). That counter is the only signal this route produces at
--- all for a caller with no session, so a counter that reads the wrong way is
--- the whole of what a server sees.
function ACTIONS.pickup(_src, input, position)
    if input.traceKey then
        local item = grid.peek(input.traceKey)
        if not item then return end

        if not PICKABLE[item.type] then return end
        if not within(item, position, config.collectRange) then return end

        grid.destroy(input.traceKey)

        return
    end

    grid.takeNear(position.x, position.y, position.z, config.collectRange, PICKABLE)
end

route.public({
    name = 'forensics.destroy',
    schema = 'ForensicsDestroy',
    -- The only ceiling there is, so it is set against what a client that skips
    -- the progress bar could do rather than against what a player does. The
    -- fastest action is `pickup` at three seconds on the client, which is twenty
    -- a minute at a sprint down a shooting scene picking brass up; thirty a
    -- minute leaves that honest player alone and still holds a client that has
    -- removed the bar to thirty grid walks a minute instead of thousands. Each
    -- of those walks is `cellsAround` at a few metres -- one or four cells --
    -- so the cost of a spent budget is bounded by the reach and not by how much
    -- evidence exists in the city (12.1).
    limit = { per = 30, window = 60 },
    handler = function(src, input)
        -- Where they are, from their ped. Every range below is measured from
        -- this and never from anything in `input`, which carries no coordinate
        -- for exactly that reason.
        local position = positionOf(src)
        if not position then return route.refuse(FredPD.ErrorCode.CONTEXT) end

        local action = input.action
        local ready = READY[action]

        -- Not `conflict`: the client maps that one code to "you have no item",
        -- and an empty-handed wipe or a sink that is not there is a different
        -- thing entirely. Anything but `conflict` reaches the player as the same
        -- generic failure, which is the point (8.11).
        if ready and not ready(src, input, position) then
            return route.refuse(FredPD.ErrorCode.CONTEXT)
        end

        if not spend(src, action) then
            return route.refuse(FredPD.ErrorCode.CONFLICT)
        end

        -- The enum in `ForensicsDestroy` is the allowlist, so this is never nil
        -- for anything a client can send. An action added to the schema and not
        -- to `ACTIONS` raises inside `route.public`'s pcall, which prints it and
        -- answers `internal` -- loud in the console, generic to the player, and
        -- never a silent success that charged somebody for nothing.
        ACTIONS[action](src, input, position)

        -- The one row there is somebody to sign. What it records is that the
        -- action was carried out and paid for -- not that anything was
        -- destroyed, and the difference is worth stating because internal
        -- affairs reads this log and the log is append-only (invariant 11). A
        -- refusal *above* leaves no row: the action never ran. A refusal
        -- *inside* the action leaves one, because every one of those is silent
        -- by design (8.11) -- a wipe over a clean pavement, a clean on a key
        -- that names nothing, a pickup with no brass in reach, and `weapon`,
        -- which by construction destroys nothing at all until a seized firearm
        -- carries recoverable trace. Reporting which of those happened would
        -- put in the audit log exactly the oracle the response withholds, so
        -- the row says who and which action and stops there.
        auditDestruction(src, action)

        -- Empty, always. See rule 1 above.
        return {}
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
--- **The second return value is how the caller puts it back.** `evidence.collect`
--- writes the item, the owner row and the first custody link in one transaction
--- (8.6), and a transaction can fail after the trace has already left the world:
--- a deadlock, a dropped connection, a constraint. Without a way back that loses
--- the only casing at a homicide to a database hiccup. So this hands over a
--- one-shot closure around `Grid.restore`, which files the *same table* again --
--- its original key, its `createdAt`, its revealed and cleaned state -- rather
--- than `Grid.place`, which would mint a new key, reset the age and clear the
--- reveal, so a restored latent print would come back younger and invisible.
---
--- One-shot because one take is one restore. `Grid.restore` refuses a key the
--- grid already holds, so a second call could not duplicate the trace anyway;
--- the flag is here so that the second call is a no-op that answers false rather
--- than a refusal that looks like a failed restore.
---
--- Between the take and the restore the trace is genuinely not in the world, so
--- a second officer standing over it is told "not found" for as long as the
--- insert takes. That is correct and it is the cheap end of the trade: the
--- alternative is holding the trace in the grid across a database round trip so
--- that two officers can both claim it and one of them writes a row for evidence
--- the other one also bagged. **Nobody should widen that window** by claiming
--- later, restoring earlier, or reserving instead of taking.
---
--- `outdoors` is whatever the grid stored on the trace. `Grid.place` sets it
--- from a server-side interior test on the position it filed the trace at; a
--- client never supplies it, here or anywhere. It is half of
--- `evidence.qualityAfter`'s weather term (8.1.4), and the other half is
--- `raining`, which is **not** in this shape and is not invented here: nothing
--- on this server tracks weather. It is client state in FiveM, FredPD has no
--- bridge to a weather resource that could answer it server-side, and asking the
--- collecting officer's client would be letting a client decide how good the
--- evidence against them is (invariant 1). So the
--- term stays inert -- a print left on a car door in a thunderstorm still decays
--- by age alone -- and `outdoors` is carried because it is the half that has a
--- source of truth, not because the term works yet.
---
--- @param src number
--- @param traceKey string the opaque key that came with render data
--- @return table|nil claim
--- @return function|nil restore -- puts the trace back, exactly as it was;
---   answers true when the grid took it back. Present whenever a claim is.
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

    local restored = false

    local function restore()
        if restored then return false end
        restored = true

        return grid.restore(taken)
    end

    return {
        type = taken.type,
        quality = taken.quality,
        ageSeconds = math.max(os.time() - (taken.createdAt or 0), 0),
        decayPerHour = service.decayPerHour(taken.type, config),
        outdoors = taken.outdoors,
        cleaned = taken.cleaned,
        owner = taken.owner,
    }, restore
end

--- Hands the residue on a person over to collection, and takes it off them.
---
--- The other half of 8.2's residue row. `gsr.mark` is called on every shot and
--- `gsr.clear` on every wash; this is the only thing in the product that reads
--- what either of them wrote. 8.2 collects residue with a "GSR kit" and analyses
--- it as "GSR analysis"; this is the kit's end of that, and `evidence.collect`
--- is the officer's route on top of it -- the same one that bags a casing,
--- taking a `targetId` where a swab has no `traceKey` to give it (spec 8.2: "the
--- swab has no route of its own").
---
--- `fredpd_forensics/client/collect.lua` is what calls this route with a
--- `targetId`: an ox_target option registered on every other player
--- (`addGlobalPlayer`, not the sphere zones a streamed trace gets, because
--- residue is never in the grid), which runs a swab action and posts the
--- swabbed player's server id. That is the only caller `gsr.present` has, and
--- it is the whole of what makes residue readable, decay observable and a
--- wash meaningful to check afterward.
---
--- The shape is `claimTrace`'s, exactly, because the route that writes the item
--- is the same one and it must not learn where its claim came from. What differs
--- is where the numbers come from:
---
---   * `quality` is the *level* `gsr.present` computes from how long ago they
---     fired (`Forensics.gsrLevel`), so a suspect swabbed at the scene is a
---     better sample than one swabbed an hour later -- which is the difference
---     between an identification and "insufficient for comparison" (8.7);
---   * `ageSeconds` is therefore zero, and deliberately. The age of a trace is
---     what `evidence.qualityAfter` decays the quality by, and this quality has
---     already been decayed by the same clock. Counting the hour twice would
---     charge the sample for it once at the swab and again at the insert;
---   * `owner` is the *target's* hidden identifier, never the officer's. That is
---     the whole value of the sample, and it never leaves the server (8.11).
---
--- Four silent refusals, all answering nil so the route can answer "not found"
--- and none of them can be told apart -- a swab that reports *why* it found
--- nothing is a residue detector anybody with the permission could walk around
--- pointing at people:
---   * no such player, or an officer or a target the server cannot place,
---     because either of them without a ped is somebody who is not there;
---   * the officer is not standing next to them, measured against the server's
---     copy of both positions (8.3.2) and never against anything in the call;
---   * no residue, or residue that has decayed to nothing;
---   * a target the framework has no character for, so the sample could never be
---     attributed to anybody and the lab would answer "no profile" forever.
---
--- Clearing is the last thing that happens and it is what makes the claim
--- destructive, exactly as `Grid.take` is for a trace: two officers cannot swab
--- the same hands, because the second one finds nothing. It is also why this is
--- not a "read" that anything else may call casually.
---
--- **There is no second return value here, and no restore.** `claimTrace` hands
--- `evidence.collect` a way to put its trace back when the insert does not
--- commit; a swab has nothing to hand over, because `gsr.mark` is the only
--- writer of the residue table and it stamps the clock at the moment it is
--- called. Re-marking a target whose insert failed would give them residue that
--- was fresher than the residue they actually had -- a better sample than the
--- truth, invented by a failed write (invariant 1) -- so nothing is put back and
--- a failed swab loses the sample. That is a real hole and it is smaller than it
--- reads: residue decays from the shot and not from the swab, so the suspect
--- still has some for as long as the curve says, and a second swab takes it. It
--- closes when `gsr.lua` gains a restore that files the original timestamp;
--- nothing on this side can fabricate one.
---
--- @param src number the officer taking the swab
--- @param targetSrc number the player being swabbed
--- @return table|nil claim, and no restore -- see above
FredPD.Evidence.claimGsr = function(src, targetSrc)
    if type(targetSrc) ~= 'number' then return nil end

    local position = positionOf(src)
    if not position then return nil end

    local at = positionOf(targetSrc)
    if not at then return nil end

    local dx, dy, dz = at.x - position.x, at.y - position.y, at.z - position.z
    local range = config.collectRange

    if (dx * dx + dy * dy + dz * dz) > (range * range) then return nil end

    -- The level, and deliberately NOT whether there was one. A swab that
    -- refused when it found nothing would be an oracle: the difference between
    -- "swab taken" and a refusal is the lab's answer, delivered at the prompt,
    -- free, repeatable and to anyone holding the collection permission rather
    -- than to somebody who may read a lab result. That is exactly what 8.11
    -- forbids, and the note on `GSR.clear` spells out the same trap for washing.
    --
    -- So an empty swab is a swab. It becomes an item, it enters the chain of
    -- custody, it queues like any other sample, and the lab is what reports
    -- there was no residue -- which is a real and useful finding, and the answer
    -- a defence asks for. `Evidence.searchResult` already reads a zero level as
    -- no result and says so in its own comment; this is what makes that case
    -- arise.
    local _, level = gsr.present(targetSrc)

    local identifier = identifierOf(targetSrc)
    if not identifier then return nil end

    gsr.clear(targetSrc)

    return {
        type = 'gsr',
        quality = level,
        ageSeconds = 0,
        decayPerHour = service.decayPerHour('gsr', config),
        -- Residue is on a pair of hands, not on the ground: there is no weather
        -- on it and nobody has scrubbed it. Present so the shape matches, false
        -- because both of them are.
        outdoors = false,
        cleaned = false,
        owner = { identifier = identifier },
    }
end

AddEventHandler('playerDropped', function()
    shotCounts[source] = nil
end)
