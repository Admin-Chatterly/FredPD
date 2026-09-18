--- Appearance bridge (spec 3.8, row "appearance": illenium-appearance or
--- equivalent -- "Gloves, footwear, clothing descriptors").
---
--- Section 8 asks this file two questions and no others:
---
---   * were the hands that touched that surface covered? Gloves are what turn a
---     fingerprint into a glove mark (8.2), so the answer picks the trace type.
---     This is the one the sensors ask today;
---   * what is on their feet? A footwear impression is worth something only
---     because it is later compared against a suspect's shoes (8.2, row
---     "Footwear impressions"). `Appearance.footwear` answers it, but nothing
---     calls it yet: no sensor creates a trace of type `footwear`, so the reader
---     is here ahead of the mechanic rather than serving one.
---
--- Both are read on the server. The client is never asked, for the same reason
--- it is never asked about the weapon: a player who could answer "I wore gloves"
--- could erase their own prints from every scene in the city (8.3.2, 11.3).
---
--- There is no single appearance resource on FiveM, so this file tries the ones
--- a server is likely to be running and takes the first that answers. They are
--- named here and nowhere else in the codebase, which is the whole point of a
--- bridge: swapping the server's clothing resource is a change to this file.

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}

local Appearance = {}

--- The resources this bridge knows how to read, tried in order.
---
--- Each entry lists the export names that version of the resource might use to
--- hand back a saved appearance. Forks rename these, so a candidate is a list of
--- spellings rather than one, and a spelling that does not exist simply fails
--- its pcall and the next is tried.
local CANDIDATES <const> = {
    { resource = 'illenium-appearance', getters = { 'getPedAppearance', 'getAppearance' } },
    { resource = 'fivem-appearance', getters = { 'getPedAppearance', 'getAppearance' } },
    { resource = 'esx_skin', getters = { 'getPlayerSkin', 'GetPlayerSkin' } },
}

--- GTA's clothing component ids. Gloves have no component of their own: they are
--- drawn as part of the arms component, which is why `wearingGloves` has to
--- compare a drawable rather than read a flag.
local COMPONENT_ARMS <const> = 3
local COMPONENT_FEET <const> = 6

--- The configured resource, when the server runs something this file does not
--- list. `FredPD.Config.server.appearance` is optional: an absent section means
--- "try the candidates above", which is the normal install.
local function configured()
    return (FredPD.Config and FredPD.Config.server and FredPD.Config.server.appearance) or {}
end

local function candidates()
    local settings = configured()
    if type(settings.resource) ~= 'string' then return CANDIDATES end

    -- A configured resource replaces the list rather than joining it: an
    -- operator who named one meant that one, and falling through to another
    -- would read a stale appearance from a resource they stopped using.
    return { {
        resource = settings.resource,
        getters = type(settings.getters) == 'table' and settings.getters
            or { 'getPedAppearance', 'getAppearance' },
    } }
end

--- The raw appearance table for a player, from whichever resource answers.
---
--- Every call is a pcall around a resource FredPD does not own. An appearance
--- resource that errors must leave a print rather than take down the sensor
--- route that asked (8.3.2).
---
--- Deliberately not cached, although an appearance changes only when a player
--- changes clothes. A cache would be read stale for its lifetime, and stale in
--- the direction that matters: an officer who has just taken their gloves off
--- would go on leaving glove marks instead of the prints they are actually
--- leaving. The callers are already bounded by the per-kind sensor limits in
--- routes.lua, so the export call is a few per player per minute at worst
--- (12.1), which is cheaper than being wrong about who touched what.
---
--- @return table|nil
local function rawAppearance(src)
    local list = candidates()

    for index = 1, #list do
        local candidate = list[index]

        if GetResourceState(candidate.resource) == 'started' then
            local getters = candidate.getters

            for spelling = 1, #getters do
                local ok, result = pcall(function()
                    return exports[candidate.resource][getters[spelling]](nil, src)
                end)

                if ok and type(result) == 'table' then return result end
            end
        end
    end

    return nil
end

--- One clothing component, whatever shape the resource stores them in.
---
--- Three shapes are in the wild and all three mean the same thing:
---   * a list of `{ component_id = 3, drawable = 12, texture = 0 }`;
---   * a map keyed by component id;
---   * ESX's flat skin, where the arms are `arms` and `arms_2`.
--- Normalising here keeps the shape out of `wearingGloves` and `footwear`, so
--- adding a fourth is one function to change.
---
--- The list is tried *first*, and that order is the whole correctness of this
--- function. A list is indexable by number too, so in the shape
--- illenium-appearance and fivem-appearance actually return, `components[3]` is
--- the third garment in the list and not the arms -- a table with a numeric
--- `drawable`, so a keyed lookup cannot tell it apart from a genuine hit. Read
--- in that order the bridge would report whatever garment happens to sit at
--- index 3 as the player's sleeves, which is a glove verdict about the wrong
--- piece of clothing. The keyed branch therefore runs only when no entry in the
--- table named its own component id, which is exactly when the table is a map
--- and not a list.
---
--- Pure and native-free, and exported below as `Appearance.component` so the
--- three shapes can be covered by busted without a game running (spec 15).
---
--- @return table|nil { drawable = number, texture = number }
local function component(appearance, id, flatKey)
    if type(appearance) ~= 'table' then return nil end

    local components = appearance.components or appearance

    if type(components) == 'table' then
        -- A list carrying its own component ids.
        local positional = false

        for index = 1, #components do
            local entry = components[index]

            if type(entry) == 'table' and tonumber(entry.component_id) then
                positional = true

                if tonumber(entry.component_id) == id then
                    return {
                        drawable = tonumber(entry.drawable) or 0,
                        texture = tonumber(entry.texture) or 0,
                    }
                end
            end
        end

        -- Keyed by component id, and only when nothing above was positional.
        if not positional then
            local direct = components[id]

            if type(direct) == 'table' and tonumber(direct.drawable) then
                return { drawable = tonumber(direct.drawable), texture = tonumber(direct.texture) or 0 }
            end
        end
    end

    -- ESX's flat skin.
    if flatKey and tonumber(appearance[flatKey]) then
        return {
            drawable = tonumber(appearance[flatKey]),
            texture = tonumber(appearance[flatKey .. '_2']) or 0,
        }
    end

    return nil
end

--- Which arms drawables are gloves, for the ped model this player is wearing.
---
--- The list lives in `config/server.lua` and nowhere else, and this file keeps
--- no fallback of its own (8.2).
---
--- Gloves are arms drawables, and *which* drawables are gloved depends entirely
--- on the clothing pack a server runs -- the same number is a glove on one
--- server and a rolled-up sleeve on the next. A list guessed here would not
--- fail safely: every officer in a long-sleeved uniform would start leaving
--- glove marks, and the prints those touches should have left would never
--- exist. That is evidence destroyed by a guess, which is worse than the
--- absence this file degrades to instead.
---
--- `config/server.lua` does ship a starting list, for the two vanilla freemode
--- models only, so a stock install is not silently glove-blind. It is
--- configuration an operator owns and edits, not a default this bridge falls
--- back on: a server running a clothing pack replaces it, and a server whose
--- players are on some other ped model gets nil here and leaves prints.
---
--- Shape, in `config/server.lua`:
---   appearance = {
---       gloves = {
---           ['mp_m_freemode_01'] = { [12] = true, [13] = true },
---           ['mp_f_freemode_01'] = { [15] = true },
---       },
---   }
---
--- @return table|nil set of drawable -> true
local function gloveSet(src)
    local settings = configured()
    local gloves = settings.gloves
    if type(gloves) ~= 'table' then return nil end

    -- `GetEntityModel` answers on the server for a networked ped, so the model
    -- is read the same way everything else in section 8 is: from the server's
    -- own view of the player, never from the call.
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end

    -- Compared unsigned. A joaat hash reaches Lua signed from one native and
    -- unsigned from another, so the same model compares unequal unless both are
    -- folded into the same range first -- and the symptom would be gloves that
    -- silently never register on a correctly configured server.
    local model = GetEntityModel(ped) % 0x100000000

    for name, set in pairs(gloves) do
        if type(set) == 'table' and (joaat(name) % 0x100000000) == model then return set end
    end

    return nil
end

--- Is this player wearing gloves (8.2, 8.3.2)?
---
--- False is the answer to every kind of "do not know": no appearance resource,
--- an appearance the resource would not hand over, no configured glove set for
--- this ped model. A server that cannot tell must leave prints, because a print
--- that should have been a glove mark is a trace an investigator can still work
--- with, and a glove mark no glove made is a lead pointing at nobody.
---
--- Some resources record gloves as their own field rather than as an arms
--- drawable. That answer is authoritative when it exists, so it is asked first
--- and needs no configuration.
---
--- @param src number server id
--- @return boolean
function Appearance.wearingGloves(src)
    local appearance = rawAppearance(src)
    if not appearance then return false end

    if type(appearance.gloves) == 'boolean' then return appearance.gloves end

    local set = gloveSet(src)
    if not set then return false end

    local arms = component(appearance, COMPONENT_ARMS, 'arms')
    if not arms then return false end

    return set[arms.drawable] == true
end

--- What is on this player's feet (8.2, row "Footwear impressions").
---
--- The drawable and texture together are the shoe: an impression lifted at a
--- scene would be compared against this pair, so both travel or neither is worth
--- storing. Nil when no appearance resource can answer, so that a caller can
--- create no impression rather than one that can never match anything.
---
--- No caller exists yet. Nothing in the suite creates a trace of type
--- `footwear`, so this function is a reader waiting for the sensor that will use
--- it; it is not part of any working mechanic today.
---
--- @param src number server id
--- @return table|nil { drawable = number, texture = number }
function Appearance.footwear(src)
    local appearance = rawAppearance(src)
    if not appearance then return nil end

    return component(appearance, COMPONENT_FEET, 'shoes')
end

--- Startup check (spec 3.8).
---
--- Two separate failures, reported separately, because they have different
--- fixes: no appearance resource at all, and an appearance resource whose glove
--- drawables are not listed in `config/server.lua` -- which, since that file
--- ships a list for the vanilla freemode models, means the section was emptied
--- or removed. Both are silent at runtime -- the traces they affect simply never
--- appear -- so this print is the only notice an operator gets.
function Appearance.verify()
    local list = candidates()
    local found

    for index = 1, #list do
        if GetResourceState(list[index].resource) == 'started' then
            found = list[index].resource
            break
        end
    end

    if not found then
        local names = {}
        for index = 1, #list do names[index] = list[index].resource end

        print(('[fredpd] appearance bridge: none of %s is started, so nothing can be read about what a player'
            .. ' is wearing. Touches always leave fingerprints and never glove marks.')
            :format(table.concat(names, ', ')))
        print('[fredpd] appearance bridge: set FredPD.Config.server.appearance.resource'
            .. ' if this server uses a different appearance resource.')
        return false
    end

    if type(configured().gloves) ~= 'table' then
        print(('[fredpd] appearance bridge: %s is started but FredPD.Config.server.appearance.gloves is not configured.')
            :format(found))
        print('[fredpd] appearance bridge: every touch leaves a fingerprint and no glove mark is ever created,'
            .. ' because which arms drawables are gloves depends on this server\'s clothing pack and is not guessed.')
        print('[fredpd] appearance bridge: config/server.lua ships a list for the vanilla freemode models --'
            .. ' restore it, or list the arms drawables your own clothing pack draws with gloves.')
        return false
    end

    return true
end

--- Exported for the spec, not for callers.
---
--- `component` is the only part of this bridge with no native in it, and it is
--- the part where being wrong is invisible: it answers with a garment either
--- way, and only the trace type downstream is different. `spec/bridges_spec.lua`
--- covers all three shapes through this handle. Nothing in the resource calls
--- it -- `wearingGloves` and `footwear` use the local directly.
Appearance.component = component

FredPD.Bridge.appearance = Appearance
