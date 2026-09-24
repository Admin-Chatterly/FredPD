--- Inventory bridge: ox_inventory (spec 3.8).
---
--- Two jobs, and they are the same job seen from both ends of section 8.
---
--- Generating: 8.3.2 says the weapon behind a casing, a magazine, a bullet or a
--- tool mark is read "from ox_inventory's server state". Not from the sensor
--- call -- a client that could name the weapon could sign somebody else's gun
--- onto a casing at a scene it has never been to (11.3).
---
--- Destroying: 8.2 lists a wiping kit and cleaning chemicals as what removes a
--- trace. "Nothing is perfectly clean" (8.1.5) only holds if destruction costs
--- something, so the destruction route spends an item through this file before
--- it touches the grid.
---
--- Everything here returns nil or false when ox_inventory is not started. A
--- guess would be worse than a refusal in both directions: invented evidence on
--- the generating side, free evidence destruction on the other.

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}

local Inventory = {}

local RESOURCE <const> = 'ox_inventory'

local function available()
    return GetResourceState(RESOURCE) == 'started'
end

--- Calls an ox_inventory export, answering nil rather than erroring.
---
--- The export surface moves between ox_inventory versions and an absent export
--- must degrade to "unknown", not take down the sensor route that asked. The
--- leading `nil` is the `self` that the `exports[res]:Name()` call form passes.
local function tryExport(name, ...)
    if not available() then return nil end

    local ok, result = pcall(function(...)
        return exports[RESOURCE][name](nil, ...)
    end, ...)

    if not ok then return nil end
    return result
end

--- The item definition ox_inventory holds for an item name.
---
--- Read rather than guessed from the name, because what counts as a firearm is
--- a property of the server's item list: a server that adds WEAPON_RAYPISTOL or
--- renames its lockpick would be wrong under any name-prefix rule.
local function definition(name)
    if type(name) ~= 'string' then return nil end

    return tryExport('Items', name)
end

--- Is this item a gun rather than a lockpick, a crowbar or a grenade?
---
--- The discriminator is the item's ammo type: a firearm consumes ammunition, a
--- melee tool and a throwable do not. It decides whether a shot can leave a
--- bullet at the victim (8.2), so a wrong "yes" invents a round that was never
--- fired. Unknown therefore answers false -- the tool sensor still gets its
--- mark, and only the bullet is withheld.
local function isFirearm(name)
    local data = definition(name)
    if type(data) ~= 'table' then return false end

    if data.throwable then return false end

    return data.ammoname ~= nil
end

--- The weapon the *server* believes is in this player's hands (8.3.2).
---
--- ox_inventory tracks the equipped weapon slot server-side, which is the whole
--- reason section 8 reads it from here: the client is never asked, so a client
--- cannot answer.
---
--- `serial` comes from the slot's item metadata. It is the only thing a casing,
--- a magazine, a bullet or a tool mark carries about the weapon (8.3.4), and it
--- is what ballistics later matches a test fire against (8.7). A weapon with no
--- serial in its metadata yields a table with `serial = nil`, and the caller
--- refuses to create the trace rather than attributing it to nothing.
---
--- Returns nil, never a guess, when ox_inventory is missing or the player is
--- holding nothing: routes.lua turns nil into "no trace", which is the outcome
--- section 8.11 requires -- indistinguishable from a call that legitimately
--- created nothing.
---
--- The tool sensor calls this too. A lockpick or a crowbar held as a weapon item
--- comes back the same way, with `isFirearm` false, so one lookup serves both
--- the casing rule and the tool-mark rule.
---
--- @param src number server id
--- @return table|nil { name = string, serial = string|nil, isFirearm = boolean }
function Inventory.currentWeapon(src)
    local slot = tryExport('GetCurrentWeapon', src)
    if type(slot) ~= 'table' or type(slot.name) ~= 'string' then return nil end

    local metadata = slot.metadata
    local serial = type(metadata) == 'table' and metadata.serial or nil

    return {
        name = slot.name,
        serial = type(serial) == 'string' and serial or nil,
        isFirearm = isFirearm(slot.name),
    }
end

--- How many of an item this player carries, or nil when it cannot be read.
---
--- `Search(inv, 'count', item)` is the current spelling; `GetItem` with the
--- count flag is the older one. Trying both keeps the bridge working across the
--- ox_inventory versions a live server is actually running.
---
--- Nil and zero are different answers and both callers below depend on the
--- difference: zero is "carries none", nil is "this build will not say", and
--- only the second one makes a removal unverifiable.
---
--- @return number|nil
local function heldCount(src, item)
    local held = tryExport('Search', src, 'count', item)

    if type(held) ~= 'number' then
        held = tryExport('GetItem', src, item, nil, true)
    end

    if type(held) ~= 'number' then return nil end

    return held
end

--- Does this player carry at least `count` of an item?
---
--- Asked before a destruction route starts its progress bar, so an officer with
--- no wiping kit is told at once rather than after the wait. It is not the
--- control: `removeItem` is, because anything checked before a timer can be
--- dropped during it.
---
--- Unknown answers false. A server with no inventory cannot spend a kit, so it
--- cannot wipe a scene either.
---
--- @param src number
--- @param item string
--- @param count number|nil defaults to 1
--- @return boolean
function Inventory.hasItem(src, item, count)
    if type(item) ~= 'string' then return false end

    local needed = tonumber(count) or 1
    local held = heldCount(src, item)

    if type(held) ~= 'number' then return false end

    return held >= needed
end

--- Spends the item, and says whether it was actually spent.
---
--- This is the one that decrements, and the only one the destruction route may
--- act on. Returning false when nothing was removed is what stops evidence
--- being destroyed for free: the caller refuses instead of wiping the grid on
--- the strength of a check that passed a progress bar ago (8.1.5).
---
--- The answer has to be all-or-nothing from the caller's side, and that is why
--- it is not simply `removed == true`. Not every ox_inventory build answers
--- `RemoveItem` with a boolean: several return nothing at all on success. On
--- those builds a bridge that read a missing return as failure would have
--- already decremented the item by the time it said "no", the route would refuse
--- on the strength of that "no", and the player would have paid a wiping kit for
--- a scene that is still there. That is the same class of bug as a free wipe,
--- pointing the other way.
---
--- So the count is read first -- too few is refused there, before anything is
--- asked of the inventory -- the boolean is believed when there is one, and a
--- build that answers anything else is resolved by reading the count back: the
--- item is spent if it actually went down. A build whose count cannot be read
--- either is refused *before* `RemoveItem` is called, so nothing is spent that
--- nobody could confirm -- and it costs the caller nothing, because `hasItem`
--- reads the same count and has already refused.
---
--- One case is left over and cannot be settled by anything here: a build with no
--- boolean whose count answered a moment ago and does not answer now, because
--- the player disconnected or ox_inventory stopped between the two reads. It is
--- answered false, which is the side to fail on -- the alternative is wiping a
--- scene on a payment nobody could confirm.
---
--- @param src number
--- @param item string
--- @param count number|nil defaults to 1
--- @return boolean removed
function Inventory.removeItem(src, item, count)
    if type(item) ~= 'string' then return false end

    local amount = tonumber(count) or 1
    if amount < 1 then return false end

    local before = heldCount(src, item)
    if type(before) ~= 'number' then return false end
    if before < amount then return false end

    local removed = tryExport('RemoveItem', src, item, amount)

    -- An explicit boolean is the build telling us what it did, either way.
    if type(removed) == 'boolean' then return removed end

    -- Anything else -- nil, a table, an export that threw -- is unknown, not
    -- failure. The inventory itself is the only thing that can settle it.
    local after = heldCount(src, item)
    if type(after) ~= 'number' then return false end

    return (before - after) >= amount
end

--- Is this item defined on this server? Asked before offering to give one:
--- ox_inventory refuses an item its list does not name.
function Inventory.knowsItem(item)
    return definition(item) ~= nil
end

--- Gives a player one item, with metadata (a printed document, 7.28).
---
--- @param src number
--- @param item string
--- @param metadata table|nil
--- @return boolean given -- false when the inventory is absent, the item is
---   undefined, or the player's inventory has no room
function Inventory.addItem(src, item, metadata)
    if type(item) ~= 'string' or not Inventory.knowsItem(item) then return false end

    if tryExport('CanCarryItem', src, item, 1, metadata) == false then return false end

    local added = tryExport('AddItem', src, item, 1, metadata)

    -- AddItem answers `true` (or a success flag first) when it placed the item.
    if type(added) == 'boolean' then return added end
    return added ~= nil and added ~= false
end

--- Startup check (spec 3.8).
---
--- Named mechanics, not a generic warning. An operator whose server generates no
--- evidence at all has no other way to find out why: every one of these fails
--- silently and correctly (a trace that cannot be attributed is not created,
--- 8.3.2), so the absence looks exactly like a quiet night.
function Inventory.verify()
    if not available() then
        print(('[fredpd] inventory bridge: %s is not started, so the server cannot read the weapon in a player\'s hands.')
            :format(RESOURCE))
        print('[fredpd] inventory bridge: shots leave no casings, reloads leave no magazines, hits leave no bullets'
            .. ' and lockpicking leaves no tool marks.')
        print('[fredpd] inventory bridge: no item can be spent either, so every destruction action that costs one'
            .. ' is refused rather than free. Actions that cost nothing are unaffected.')
        return false
    end

    return true
end

FredPD.Bridge.inventory = Inventory
