--- The in-game placement editor (spec 3.10, ADR-006).
---
--- `/fredpd placement` — put a terminal where the desk actually is, standing in
--- front of it, without a config file or a restart.
---
--- The client does none of the deciding. Every action here calls a route that
--- checks `admin.placement.edit` on the server; an officer without it gets a
--- refusal, not a hidden menu. Hiding the command would be a convenience, never
--- the control (invariant 4).

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

local Editor = {}

local call = nil

local function client()
    call = call or FredPD.Client.core
    return call
end

--- Icon shown beside each kind in the picker (FontAwesome, ox_lib context
--- menus). Purely presentational: never sent to the server, and not itself
--- user-facing text -- invariant 6 governs strings, not an icon name.
local KIND_ICONS <const> = {
    station_terminal = 'desktop',
    property_terminal = 'box-archive',
    lab_terminal = 'flask',
    booking_terminal = 'clipboard-list',
    dispatch_console = 'headset',
    courthouse_terminal = 'gavel',
    motorpool = 'car',
    evidence_bench = 'magnifying-glass',
    fingerprint_scanner = 'fingerprint',
}

--- Placement kinds offered in the editor, each with its label, a one-line
--- description of what standing here actually gates, and an icon.
---
--- Built from the generated enum so the editor can never offer a kind the
--- server would reject.
local function kindOptions()
    local options = {}

    for _, kind in pairs(FredPD.PlacementKind) do
        options[#options + 1] = {
            kind = kind,
            title = FredPD.t('placement.' .. kind),
            description = FredPD.t('placement.editor.description.' .. kind),
            icon = KIND_ICONS[kind],
        }
    end

    table.sort(options, function(a, b) return a.title < b.title end)
    return options
end

--- Asks which kind this placement should be, through ox_lib's own context
--- menu rather than the generic `Ui.showMenu` bridge -- which only ever
--- carries a label, never an icon or a description.
---
--- An officer choosing between nine kinds by name alone, with nothing said
--- about what each one actually does, was the whole reason this needed
--- improving: `station_terminal` and `booking_terminal` read as
--- near-synonyms without the sentence that tells them apart. ox_lib is a
--- hard dependency of this resource (`fxmanifest.lua`'s `REQUIRED_RESOURCES`),
--- not a bridge target that might be swapped out, so calling it directly
--- here is the same thing `lib.inputDialog` and `lib.alertDialog` already do
--- elsewhere in this file.
---
--- @param onPick function(kind)
local function pickKind(onPick)
    local options = kindOptions()
    local contextOptions = {}

    for index = 1, #options do
        local option = options[index]

        contextOptions[index] = {
            title = option.title,
            description = option.description,
            icon = option.icon,
            onSelect = function() onPick(option.kind) end,
        }
    end

    lib.registerContext({
        id = 'fredpd_placement_kind',
        title = FredPD.t('placement.editor.pickKind'),
        options = contextOptions,
    })
    lib.showContext('fredpd_placement_kind')
end

--- The placement nearest the player, from what the server pushed.
local function nearest()
    local position = GetEntityCoords(PlayerPedId())
    local best, bestDistance = nil, math.huge

    for _, placement in pairs(FredPD.Client.placements.all()) do
        local distance = #(position - vec3(placement.x, placement.y, placement.z))

        if distance < bestDistance then
            best, bestDistance = placement, distance
        end
    end

    return best, bestDistance
end

--- The prop the player is looking at, for the `prop` interaction.
---
--- Binding to a prop that is already in the map is how a station terminal ends
--- up exactly on the desk rather than approximately near it.
local function propInView()
    local ped = PlayerPedId()
    local from = GetGameplayCamCoord()
    local direction = GetEntityForwardVector(ped)
    local to = from + (direction * 5.0)

    local ray = StartShapeTestRay(from.x, from.y, from.z, to.x, to.y, to.z, 16, ped, 0)
    local _, hit, _, _, entity = GetShapeTestResult(ray)

    if hit == 0 or not entity or entity == 0 then return nil end
    if not DoesEntityExist(entity) then return nil end

    return entity
end

-- -----------------------------------------------------------------------------
-- Actions
-- -----------------------------------------------------------------------------

local function create(interaction)
    local ped = PlayerPedId()
    local position = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local model = nil

    if interaction == 'prop' then
        local entity = propInView()

        if not entity then
            client().notify('placement.editor.noProp')
            return
        end

        -- Bind to where the prop is, not where the player is standing.
        position = GetEntityCoords(entity)
        heading = GetEntityHeading(entity)
        model = tostring(GetEntityModel(entity))
    elseif interaction == 'ped' then
        local input = lib.inputDialog(FredPD.t('placement.editor.pedModelTitle'), {
            { type = 'input', label = FredPD.t('placement.editor.pedModelLabel'), required = true },
        })

        if not input or not input[1] then return end
        model = input[1]
    end

    pickKind(function(kind)
        local response = client().call('placement.create', {
            kind = kind,
            interaction = interaction,
            model = model,
            x = position.x,
            y = position.y,
            z = position.z,
            heading = heading + 0.0,
            labelKey = 'placement.' .. kind,
        })

        if response.ok then
            client().notify('placement.editor.created')
        else
            client().showError(response)
        end
    end)
end

local function moveNearest()
    local placement = nearest()
    if not placement then
        client().notify('placement.editor.noneNearby')
        return
    end

    local ped = PlayerPedId()
    local position = GetEntityCoords(ped)

    local response = client().call('placement.update', {
        id = placement.id,
        x = position.x,
        y = position.y,
        z = position.z,
        heading = GetEntityHeading(ped) + 0.0,
    })

    if response.ok then
        client().notify('placement.editor.moved')
    else
        client().showError(response)
    end
end

local function toggleNearest()
    local placement = nearest()
    if not placement then
        client().notify('placement.editor.noneNearby')
        return
    end

    -- The client only knows about enabled placements, so this always disables.
    -- Re-enabling is done from the MDT admin screen, where the full list --
    -- including what is switched off -- is visible.
    local response = client().call('placement.update', { id = placement.id, enabled = false })

    if response.ok then
        client().notify('placement.editor.disabled')
    else
        client().showError(response)
    end
end

local function deleteNearest()
    local placement, distance = nearest()
    if not placement then
        client().notify('placement.editor.noneNearby')
        return
    end

    local confirmed = lib.alertDialog({
        header = FredPD.t('placement.editor.deleteTitle'),
        content = FredPD.t('placement.editor.deleteBody', {
            kind = FredPD.t('placement.' .. placement.kind),
            distance = ('%.1f'):format(distance),
        }),
        centered = true,
        cancel = true,
    })

    if confirmed ~= 'confirm' then return end

    local response = client().call('placement.delete', { id = placement.id })

    if response.ok then
        client().notify('placement.editor.deleted')
    else
        client().showError(response)
    end
end

--- Opens the editor.
function Editor.open()
    FredPD.Bridge.ui.showMenu(FredPD.t('placement.editor.title'), {
        { value = 'new_zone', label = FredPD.t('placement.editor.newZone') },
        { value = 'new_prop', label = FredPD.t('placement.editor.newProp') },
        { value = 'new_ped', label = FredPD.t('placement.editor.newPed') },
        { value = 'move', label = FredPD.t('placement.editor.move') },
        { value = 'disable', label = FredPD.t('placement.editor.disable') },
        { value = 'delete', label = FredPD.t('placement.editor.delete') },
    }, function(choice)
        if choice == 'new_zone' then create('zone')
        elseif choice == 'new_prop' then create('prop')
        elseif choice == 'new_ped' then create('ped')
        elseif choice == 'move' then moveNearest()
        elseif choice == 'disable' then toggleNearest()
        elseif choice == 'delete' then deleteNearest()
        end
    end)
end

RegisterCommand('fredpd', function(_source, args)
    if args[1] == 'placement' then
        Editor.open()
    elseif args[1] == 'tenprint' then
        -- Ten-print capture (8.8): a deliberate command, not the scanner's
        -- own interact key -- see `fingerprint_scanner.lua`'s own header for
        -- why filing a permanent reference needs more than standing nearby.
        FredPD.Client.fingerprintScanner.capture()
    elseif args[1] == 'setup' then
        -- First-run setup: /fredpd setup <code> <discord role id>. Both come
        -- from the server console, so this is only useful to whoever is running
        -- the server (see bootstrap.lua).
        TriggerServerEvent('fredpd:setup', args[2] or '', args[3] or '')
    else
        TriggerEvent('fredpd:toggleInterface')
    end
end, false)

--- How setup went, translated on the client like every other message.
RegisterNetEvent('fredpd:setupResult', function(ok, localeKey, params)
    if ok then
        FredPD.Client.core.notify(localeKey, params)
    else
        lib.notify({
            title = FredPD.t('app.name'),
            description = FredPD.t(localeKey, params),
            type = 'error',
        })
    end
end)

FredPD.Client.placementEditor = Editor
