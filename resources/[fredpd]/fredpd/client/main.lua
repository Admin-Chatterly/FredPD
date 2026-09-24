--- NUI host.
---
--- The client sends intent only. It never decides what the player may see: the
--- server answers each route with what that session is allowed (invariant 1).

local isOpen = false

--- Shows or hides the NUI and moves keyboard and mouse focus with it.
---
--- `placement` is the placement the interface was opened from, when it was
--- opened from one at all. The NUI needs it because a route with an
--- `accessPoint` context condition -- `evidence.intake` at the property room
--- terminal (spec 8.6) -- takes a `placementId`, and the server then checks the
--- player is standing at that placement. The id is a *claim*, never a grant:
--- naming a terminal you are not at fails the check on the server.
---
--- Opening while already open is not a no-op, because the placement can have
--- changed. An officer who opens the MDT on the keybind and then walks up to
--- the property terminal fires the placement action with the interface already
--- up: returning early there would leave the NUI holding no placement at all,
--- and every intake would go on failing on `context` for no visible reason.
--- Closing while already closed really is nothing.
---
--- @param open boolean
--- @param placement table|nil
local function setOpen(open, placement, intent)
    if not open and not isOpen then return end

    isOpen = open
    SetNuiFocus(open, open)
    SendNUIMessage({
        type = open and 'fredpd:open' or 'fredpd:close',
        placementId = open and placement and placement.id or nil,
        placementKind = open and placement and placement.kind or nil,
        -- Where to land: `{ module, tab, term, type }` from a field action's
        -- "Open in MDT". Navigation only; the screen still asks the server.
        intent = open and intent or nil,
    })

    -- Closing the MDT hides the interface; it does not unmount it. `main.ts`
    -- answers `fredpd:close` by setting `hidden` on the root, so every Svelte
    -- component stays mounted and no teardown runs -- which is how the map's
    -- own unsubscribe, written as an `$effect` teardown, could never fire. One
    -- visit to the map then left the server sweeping positions and pushing them
    -- to this player every two seconds for the rest of the session, against a
    -- budget (12.1) that assumes a subscriber is somebody actually watching.
    --
    -- Said here rather than in the NUI because this is the one place that knows
    -- the MDT closed at all, and it is unconditional on purpose: a session that
    -- never opened the map is not subscribed, and unsubscribing is a no-op.
    if not open and FredPD.Client.cad then
        FredPD.Client.cad.unsubscribeMap()
    end
end

--- The NUI asks to be closed (Escape, or the title bar) rather than closing
--- itself, so focus and state always change in one place.
RegisterNUICallback('fredpd:close', function(_, cb)
    setOpen(false)
    cb({ ok = true })
end)

--- Routes the NUI is allowed to call.
---
--- One callback per name, rather than a single "call any route" proxy: spec
--- 11.2 bans the generic form, and this is the one place you can read what the
--- interface is able to reach. The route layer re-checks session, permission,
--- context, rate limit and schema regardless, so this is defence in depth --
--- but a proxy would also make that list unknowable.
---
--- The name is also the NUI callback name, because the web bridge addresses a
--- route as `https://fredpd/<route>`.
local NUI_ROUTES <const> = {
    'session.get',
    'chat.history',
    'admin.rolemap.list',
    'admin.rolemap.create',
    'admin.rolemap.delete',
    'admin.health',
    'placement.list',
    'placement.update',
    'placement.delete',

    -- Intelligence (spec 10).
    'intel.search',
    'intel.tags',
    'intel.note.list',
    'intel.note.create',
    'intel.note.update',
    'intel.note.delete',
    'intel.person.list',
    'intel.person.get',
    'intel.person.create',
    'intel.person.update',
    'intel.person.delete',
    'intel.person.merge',
    'intel.person.linkMaster',
    'intel.org.list',
    'intel.org.get',
    'intel.org.create',
    'intel.org.update',
    'intel.org.delete',
    'intel.case.list',
    'intel.case.get',
    'intel.case.create',
    'intel.case.update',
    'intel.case.delete',
    'intel.case.link.add',
    'intel.case.link.remove',
    'intel.membership.set',
    'intel.membership.remove',
    'intel.associate.set',
    'intel.associate.remove',
    'intel.vehicle.create',
    'intel.vehicle.delete',
    'intel.evidence.add',
    'intel.evidence.delete',

    -- The master name index (spec 7.2, 7.3).
    'person.create',
    'person.search',
    'person.get',
    'person.update',
    'person.caution.set',

    -- Vehicle and firearm registers (spec 7.4, 7.5).
    'vehicle.search',
    'vehicle.get',
    'vehicle.register',
    'vehicle.update',
    'vehicle.plate.change',
    'vehicle.flag',
    'vehicle.flag.clear',
    'firearm.search',
    'firearm.get',
    'firearm.register',
    'firearm.update',
    'firearm.transfer',
    'firearm.status',
    'firearm.assign',
    'firearm.trace',

    -- Suggesting real citizens and vehicles from ESX's own tables
    -- (server/modules/esxdata/routes.lua).
    'esx.character.search',
    'esx.vehicle.search',

    -- The unified query and hot-file hits (spec 7.2).
    'query.run',
    'query.hit.confirm',
    'query.log',

    -- Brottskatalogen (spec 7.10).
    'brott.list',
    'brott.versions',
    'brott.straffskala',
    'brott.create',
    'brott.version',
    'brott.retire',

    -- Anmälan och förundersökning (spec 7.7, 7.8).
    'anmalan.list',
    'anmalan.get',
    'anmalan.versions',
    'anmalan.create',
    'anmalan.update',
    'anmalan.submit',
    'anmalan.atersand',
    'anmalan.approve',
    'anmalan.charges.set',
    'anmalan.person.set',
    'anmalan.person.remove',
    'fu.list',
    'fu.get',
    'fu.create',
    'fu.assign',
    'fu.slutdelge',
    'fu.redovisa',
    'fu.lagg_ned',

    -- Frihetsberövande (spec 7.9).
    'frihet.open',
    'frihet.list',
    'frihet.get',
    'frihet.gripande',
    'frihet.anhallande',
    'frihet.framstallan',
    'frihet.haktning',
    'frihet.fallback.anhallande',
    'frihet.fallback.framstallan',
    'frihet.fallback.haktning',
    'frihet.frigiv',
    'frihet.underratta',
    'frihet.charges.set',
    'frihet.log.add',

    -- Tvångsmedel och efterlysning (spec 7.12, 7.13).
    'tvang.list',
    'tvang.get',
    'tvang.decide',
    'tvang.verkstall',
    'tvang.upphav',
    'efterlysning.list',
    'efterlysning.create',
    'efterlysning.cancel',

    -- Spaningsuppdrag (spec 7.13).
    'spaning.list',
    'spaning.get',
    'spaning.create',
    'spaning.resolve',

    -- Surveillance: the secret coercive measures (spec 9, M5).
    'hak.list',
    'hak.get',
    'hak.log',
    'hak.request',
    'hak.grant',
    'hak.refuse',
    'hak.upphav',
    'hak.session.start',
    'hak.session.end',
    'hak.intercept.add',

    -- Åtal och dom (spec 7.20, M6).
    'court.referral.list',
    'court.referral.pending',
    'court.referral.get',
    'court.referral.decide',
    'court.disposition.enter',

    -- Personnel (spec 7.22-7.24, M6).
    'personnel.roster.list',
    'personnel.roster.get',
    'personnel.roster.update',
    'personnel.shift.start',
    'personnel.shift.end',
    'personnel.equipment.assign',
    'personnel.equipment.return',
    'personnel.issueGate.list',
    'personnel.issueGate.set',
    'personnel.issueGate.clear',
    'personnel.loadout.list',
    'personnel.loadout.create',
    'personnel.loadout.delete',
    'personnel.officer.setLoadout',
    'personnel.certification.issue',
    'personnel.certification.revoke',
    'personnel.discipline.list',
    'personnel.discipline.open',
    'personnel.discipline.close',

    -- Booking (spec 7.9, M6).
    'booking.list',
    'booking.get',
    'booking.book',
    'booking.property.add',
    'booking.property.release',
    'booking.release',

    -- Ordningsbot (spec 7.11, M6).
    'ordningsbot.tariff.list',
    'ordningsbot.tariff.set',
    'ordningsbot.tariff.retire',
    'ordningsbot.list',
    'ordningsbot.get',
    'ordningsbot.issue',
    'ordningsbot.void',
    'ordningsbot.contest',
    'ordningsbot.pay',

    -- Impound (spec 7.15, M6).
    'impound.list',
    'impound.get',
    'impound.create',
    'location.search',
    'location.get',
    'location.create',
    'location.update',
    'location.hazard.add',
    'location.hazard.cancel',
    'location.keyholder.set',
    'location.keyholder.remove',
    'fi.create',
    'fi.list',
    'fi.get',
    'stop.create',
    'stop.list',
    'impound.authorize',
    'impound.release',
    'impound.inventory',

    -- Photographs and mugshots through the gateway (ADR-019).
    'person.photo.begin',
    'person.photo.commit',
    'booking.mugshot.begin',
    'booking.tenPrint.capture',

    -- Printing (7.28, ADR-020).
    'document.capabilities',
    'document.print',

    -- Crime scenes, evidence and the chain of custody (spec 8).
    'scene.create',
    'scene.release',
    'scene.list',
    'evidence.collect',
    'evidence.list',
    'evidence.get',
    'evidence.custody',
    'evidence.intake',
    'evidence.transfer',

    -- The forensic lab (spec 8.7).
    'lab.request.create',
    'lab.queue',
    'lab.analysis.start',
    'lab.analysis.complete',

    -- Administration: permission groups and the motor pool fleet.
    'admin.group.list',
    'admin.group.create',
    'admin.group.update',
    'admin.group.delete',
    'admin.permission.list',
    'garage.fleet.manage',
    'garage.fleet.add',
    'garage.fleet.update',
    'garage.fleet.remove',

    -- Dispatch: calls, the unit board, the map and ALPR (spec 7.16-7.18).
    --
    -- `unit.emergency` and `unit.status` are here as well as on the keybind in
    -- `client/cad.lua`: the panic button has to work with the MDT shut, and a
    -- dispatcher sitting at the console has to be able to press the same thing.
    'call.create',
    'call.list',
    'call.get',
    'call.dispatch',
    'call.self_assign',
    'call.status',
    'call.clear',
    'call.acknowledge',
    'call.note',
    'call.link',
    'unit.list',
    'unit.status',
    -- The command line (Appendix F): the routes the in-game status keys call.
    'unit.progress',
    'call.attach_nearest',
    'call.clear_mine',
    'unit.manage',
    'unit.emergency',
    'broadcast.create',
    'broadcast.cancel',
    'broadcast.list',
    'beat.list',
    'map.view',
    'alpr.read.list',
    'alpr.hotlist.edit',
    'alpr.hotlist.list',
}

for _, name in ipairs(NUI_ROUTES) do
    RegisterNUICallback(name, function(data, cb)
        -- `cb` is what encodes the JSON the browser parses, and this is the
        -- only hop that can decide array from object: the answer arrived over
        -- `lib.callback`, which is msgpack and carries no metatables, so
        -- whatever the server marked was lost on the way here. Without this an
        -- empty list reaches the interface as `{}` and an `{#each}` over it
        -- throws (shared/arrays.lua).
        cb(FredPD.markArrays(FredPD.Client.core.call(name, data)))
    end)
end

AddEventHandler('fredpd:toggleInterface', function()
    setOpen(not isOpen)
end)

--- The MDT on a key (spec 1.4), bound by default to `Config.shared.mdcKeybind`
--- and rebindable under Settings -> Key Bindings -> FiveM. An officer used to
--- have to walk to a terminal to read a record; the car and the street are
--- where the work is.
---
--- Opening is not access. Everything inside is a route the server checks, and
--- the routes pinned to a terminal (`accessPoint`) still need the terminal:
--- this opens with no placement, so they refuse with a sentence saying where
--- to go. `mdtInVehicleOnly` narrows the key to a car for a server that wants
--- the MDC to feel like one -- a matter of feel, not of security.
local MDT_COMMAND <const> = 'fredpd_mdt'

RegisterCommand(MDT_COMMAND, function()
    if isOpen then
        setOpen(false)
        return
    end

    if FredPD.Config.shared.mdtInVehicleOnly and not IsPedInAnyVehicle(PlayerPedId(), false) then
        FredPD.Client.core.showError({ err = FredPD.ErrorCode.CONTEXT, fields = { _context = 'inAgencyVehicle' } })
        return
    end

    setOpen(true)
end, false)

RegisterKeyMapping(MDT_COMMAND, FredPD.t('shell.keybind'), 'keyboard',
    FredPD.Config.shared.mdcKeybind or '')

--- For the field actions (client/field.lua): open the MDT on a record.
FredPD.Client.mdt = {
    open = function(intent) setOpen(true, nil, intent) end,
}

--- Opening a terminal is the same action wherever it is placed, so every
--- terminal kind maps to it (spec 3.10). What the officer can then *do* inside
--- differs by permission, which the server decides.
for _, kind in ipairs({
    'station_terminal',
    'property_terminal',
    'lab_terminal',
    'booking_terminal',
    'dispatch_console',
    'courthouse_terminal',
}) do
    FredPD.Client.placements.registerAction(kind, function(placement)
        setOpen(true, placement)
    end)
end

--- Reading a printed document (7.28, ADR-020). ox_inventory calls this when
--- the paper item is used (`client = { export = 'fredpd.readPaper' }` in the
--- item list). The paper's own metadata carries the document as it was
--- printed, so nothing is read from the server: a copy is whatever it says,
--- to whoever holds it, and the record it came from stays behind its own
--- access check. Open to anybody holding the paper -- no session needed.
local function readPaper(data, slot)
    local metadata = (type(slot) == 'table' and slot.metadata)
        or (type(data) == 'table' and data.metadata) or nil
    local document = type(metadata) == 'table' and metadata.fredpd or nil
    if type(document) ~= 'table' then return end

    isOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'fredpd:paper', document = document })
end

exports('readPaper', readPaper)

--- An impound lot (7.15, 0037) opens the MDT on the impound tab: what the
--- officer at the lot does is find the car and write down what is in it.
FredPD.Client.placements.registerAction('impound_lot', function()
    setOpen(true, nil, { module = 'records', tab = 'impound' })
end)

--- Permissions changed while the player was connected: a role was added or
--- removed, or an administrator edited the role map. The shell redraws its rail
--- from what the server now allows (spec 4.2).
RegisterNetEvent('fredpd:permissions', function(payload)
    SendNUIMessage({ type = 'fredpd:permissions', modules = payload.modules })
end)

--- Ask for world geometry once the session exists on the server.
AddEventHandler('playerSpawned', function()
    TriggerServerEvent('fredpd:requestPlacements')
end)

CreateThread(function()
    -- Covers a resource restart while players are already in the world, where
    -- playerSpawned has long since fired.
    Wait(2000)
    TriggerServerEvent('fredpd:requestPlacements')
end)

--- Never leave a player stuck with NUI focus and no NUI.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and isOpen then
        SetNuiFocus(false, false)
    end
end)
