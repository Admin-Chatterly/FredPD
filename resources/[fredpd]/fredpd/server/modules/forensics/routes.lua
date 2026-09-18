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
--- transaction (8.6) -- and what it was missing was somewhere to claim from.
--- This file supplies the claims and nothing more: `claimTrace` for a trace
--- lying in the grid, `claimGsr` for the residue on a suspect's hands, and one
--- insert path behind both, as there has to be.

local route = FredPD.Core.route
local service = FredPD.Modules.forensics
local grid = FredPD.Forensics.grid
local config = grid.settings()

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

--- The two actions that cost nothing (8.10, 8.1.5: "costs time and items").
---
--- A sink is a sink and a hand is a hand, and charging for them would make
--- walking back for your own casings something only a prepared player could do.
--- Everything else spends an item, and an action that is not in here and has no
--- configured item name cannot be paid for -- see `spend`.
local FREE <const> = { wash = true, pickup = true }

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
--- not this file's.
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
--- @param src number
--- @param action string the action that was carried out
local function auditDestruction(src, action)
    local session = FredPD.Core.session.get(src)
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
--- The set is the server's, not the client's, and that is the whole point of it.
--- `fredpd_forensics` has a list of the same models, but it decides which prompt
--- to *draw*; a list on a client cannot gate a check on a server, and while the
--- wash route accepted "no entity" as "no sink to check" the honest client's own
--- prompt was the only thing standing between a player and washing in a field.
---
--- Names are hashed once at load because `GetEntityModel` answers a hash. A
--- server whose map has other sinks lists them under `forensics.washModels` in
--- `config/server.lua` -- a list of model names, which replaces this one whole
--- rather than adding to it, because a server that names its own sinks has said
--- which sinks it has. A model name is not a world position, so this is not a
--- placement (3.10): the same sink model is a sink wherever it stands, including
--- in a house nobody configured.
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

        if type(name) == 'string' then
            hashes[joaat(name)] = true
        elseif type(name) == 'number' then
            hashes[name] = true
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

--- The kit has to have a reach configured before anybody pays for it.
---
--- `wipeRadius` comes from `Forensics.defaults` and is a number on every server
--- that has not gone out of its way to make it something else. A server that has
--- is refused here, before the kit is spent, rather than having this file invent
--- a radius of its own: a second default is how the two drift apart, and a wipe
--- at a guessed radius is exactly the bug this route was just repaired for.
function READY.wipe()
    return type(wipeRadius) == 'number'
end

--- A sink in a field is not a sink.
---
--- 8.2 destroys residue by "washing at sinks and showers", so an entity the
--- server can resolve, that is within reach of where the server says the player
--- is (8.3.2), and whose model is in the set above. All three, every time.
---
--- A missing network id used to be read as "there is nothing to check", which
--- made this a gate that gated nothing: the honest client sends no id for an
--- unnetworked map prop, so `{ action = 'wash' }` with no id was the ordinary
--- call and it washed anywhere in the world -- in a field, in a car, mid-chase.
--- The two cases genuinely are indistinguishable from here, which is why the
--- lenient one cannot be kept: the only way to tell a player standing at a sink
--- from a player standing in a field is to make them name the sink.
---
--- What that costs is stated plainly, because it is a real cost and the next
--- reader should not have to discover it: a map prop is not networked and has no
--- network id, so washing at one is refused until the client can name it. Until
--- then washing works at the sinks and showers a resource spawns as networked
--- objects, and residue decays on its own everywhere else (8.2: "Washing at
--- sinks and showers, **time**"). A wash that works everywhere is not a smaller
--- version of the mechanic, it is the absence of it.
function READY.wash(_src, input, position)
    local entity = entityNear(input.netId, position)
    if not entity then return false end

    return WASH_MODELS[GetEntityModel(entity)] == true
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
--- ends, instead of one that ends twice as far out.
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
--- So what a player buys today is the kit and the twelve seconds, and the effect
--- is exactly nothing. That is the honest version of the half-built mechanic:
--- the action is offered because 8.10 lists it, it costs what 8.10 says it
--- costs, and it answers `{}` like the other four, so a player cannot tell from
--- the outside that the model behind it is missing. When a seized weapon starts
--- carrying recoverable prints, this function is where the flag is cleared --
--- and until then nothing here should pretend otherwise by deleting a casing or
--- a trace the weapon has nothing to do with.
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
--- nowhere else. `READY.wash` has already checked that they are standing at a
--- sink or a shower the server resolved and recognised, so by here the only
--- question left is whose hands.
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

        -- The one row there is somebody to sign, written after the act and
        -- never before it: a refusal above leaves no row, because nothing was
        -- destroyed. Silent for every caller without a session, which is most
        -- of them and is the point of this tier.
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

--- Hands the residue on a person over to collection, and takes it off them.
---
--- The other half of 8.2's residue row. `gsr.mark` has been called on every shot
--- since M3 and `gsr.clear` on every wash, and until now nothing read either:
--- `GSR.present` had no caller in the product at all, so residue was write-only,
--- the decay curve was unobservable and washing destroyed a state nothing could
--- ever have asked about. 8.2 collects it with a "GSR kit" and analyses it as
--- "GSR analysis"; this is the kit's end of that, and `evidence.collect` is the
--- officer's route on top of it -- the same one that bags a casing, taking a
--- `targetId` where a swab has no `traceKey` to give it.
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
--- @param src number the officer taking the swab
--- @param targetSrc number the player being swabbed
--- @return table|nil
FredPD.Evidence.claimGsr = function(src, targetSrc)
    if type(targetSrc) ~= 'number' then return nil end

    local position = positionOf(src)
    if not position then return nil end

    local at = positionOf(targetSrc)
    if not at then return nil end

    local dx, dy, dz = at.x - position.x, at.y - position.y, at.z - position.z
    local range = config.collectRange

    if (dx * dx + dy * dy + dz * dz) > (range * range) then return nil end

    local present, level = gsr.present(targetSrc)
    if not present then return nil end

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
