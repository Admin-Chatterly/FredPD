--- In-world UI bridges: esx_textui and esx_menu_dialog (spec 3.8).
---
--- These are client-side because prompts and menus are drawn on the client.
--- They are still bridges: esx_textui and esx_menu_dialog are named here and
--- nowhere else, so swapping either one is a change to this file alone.
---
--- Nothing here decides anything. A menu shows options the server already said
--- this session may see, and picking one calls a route that checks the
--- permission again (invariant 4). The menu is a convenience, never a control.

FredPD = FredPD or {}
FredPD.Bridge = FredPD.Bridge or {}

local Ui = {}

local TEXTUI <const> = 'esx_textui'
local MENU <const> = 'esx_menu_dialog'

local textShown = false

local function has(resource)
    return GetResourceState(resource) == 'started'
end

--- Shows the "press E" style prompt.
---
--- @param message string already translated by the caller -- this bridge never
---   builds user-facing text, so invariant 6 stays with the caller's locale key
function Ui.showPrompt(message)
    if textShown then return end
    textShown = true

    if has(TEXTUI) then
        exports[TEXTUI]:TextUI(message)
    elseif lib and lib.showTextUI then
        -- ox_lib is a hard dependency, so this is a real fallback rather than a
        -- silent no-op on a server without esx_textui.
        lib.showTextUI(message)
    end
end

function Ui.hidePrompt()
    if not textShown then return end
    textShown = false

    if has(TEXTUI) then
        exports[TEXTUI]:HideUI()
    elseif lib and lib.hideTextUI then
        lib.hideTextUI()
    end
end

--- Asks the player to pick one of `options`.
---
--- @param title string translated
--- @param options table list of { value = any, label = string (translated) }
--- @param onSelect function(value)
function Ui.showMenu(title, options, onSelect)
    if has(MENU) and ESX and ESX.UI and ESX.UI.Menu then
        local elements = {}

        for index = 1, #options do
            elements[index] = { label = options[index].label, value = options[index].value }
        end

        ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'fredpd_menu', {
            title = title,
            align = 'top-left',
            elements = elements,
        }, function(data, menu)
            menu.close()
            onSelect(data.current.value)
        end, function(_data, menu)
            menu.close()
        end)

        return
    end

    -- ox_lib fallback, so a server without esx_menu_dialog is not stuck.
    local items = {}
    for index = 1, #options do
        items[index] = {
            title = options[index].label,
            onSelect = function() onSelect(options[index].value) end,
        }
    end

    lib.registerContext({ id = 'fredpd_menu', title = title, options = items })
    lib.showContext('fredpd_menu')
end

--- Asks for a single line of text.
--- @param onSubmit function(value|nil) nil when cancelled
function Ui.prompt(title, label, onSubmit)
    local input = lib.inputDialog(title, { { type = 'input', label = label, required = true } })

    onSubmit(input and input[1] or nil)
end

FredPD.Bridge.ui = Ui
