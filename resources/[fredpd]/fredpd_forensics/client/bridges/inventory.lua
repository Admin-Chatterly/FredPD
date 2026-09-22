--- ox_inventory bridge: an item was used (spec 8.2, 3.8).
---
--- The only file in `fredpd_forensics` that names ox_inventory. Everything else
--- in this resource reports "an item was used" and does not know or care which
--- one -- `client/sensors.lua`'s `itemUsed` export is what every such bridge
--- calls, and it is the reason `dna_touch` and `drug_residue` sat fully wired on
--- the server (`forensics/routes.lua`'s `RULES.item_use`) and unreachable in
--- play: nothing ever called it, because no bridge to the event that fires when
--- an item is used shipped until this file.
---
--- ## Which event, and why it is read defensively
---
--- `ox_inventory:usedItem` is the client-side notification ox_inventory raises
--- whenever a registered usable item is consumed, for every item and not only
--- ones this resource defined -- the same reason the core's own
--- `server/bridges/inventory.lua` reads `Search`-or-`GetItem` and a boolean-or-
--- count removal result: which exact shape a live server's ox_inventory answers
--- with has moved between versions, and a bridge that assumed one shape and
--- broke silently on another would look identical to no items ever being used
--- at all. So the item name is read defensively -- a bare string argument, or a
--- table carrying one under `name` or `item` -- and a payload that carries
--- neither is treated as "nothing usable to report", the same way an unreadable
--- item count in the core bridge is treated as "cannot confirm", never as a
--- reason to invent a name.
---
--- ## What the name is worth, and what it is not
---
--- The name travels to the server as part of the sensor call and nothing else
--- changes: `RULES.item_use` still builds the trace from the server's own
--- position and identifier, exactly as before this file existed (8.3.2). All the
--- name adds is which of two outcomes 8.2 already describes for the same
--- moment -- touch DNA, or drug residue when the name matches something an
--- operator listed in `config/server.lua`'s `forensics.drugItems` (empty by
--- default, because which of your items are drugs is a property of your item
--- list and not of FredPD). A client that reports a name that is not what it
--- actually used only ever picks between those two labels on a trace that would
--- have been created either way -- it grants nothing, and it does not decide
--- whether anything is created at all.
local sensors = FredPDForensics.Client.sensors

local function itemName(a, b)
    if type(a) == 'string' then return a end

    if type(a) == 'table' then
        if type(a.name) == 'string' then return a.name end
        if type(a.item) == 'string' then return a.item end
    end

    if type(b) == 'string' then return b end

    return nil
end

RegisterNetEvent('ox_inventory:usedItem', function(a, b)
    sensors.itemUsed(itemName(a, b))
end)
