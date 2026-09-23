--- The fingerprint scanner placement (spec 3.10, 8.4).
---
--- A fast, no-dialog way to collect a print that has already been revealed and
--- is within reach -- the same shortcut the GSR swab already gives an officer
--- for residue, extended to prints. It changes nothing about how a print is
--- collected: the call is `evidence.collect` with a trace key, exactly as a
--- target-zone collection sends, and the server decides everything about the
--- item the same way (invariant 1). What the placement buys is standing
--- somewhere convenient and pressing one key instead of walking to the print,
--- opening a packaging dialog and choosing values the scanner already knows.
---
--- `fredpd_forensics` owns every print this client has been streamed (8.1.6)
--- and this resource owns placements, so finding one and dropping it once
--- collected are both cross-resource exports -- `nearestPrintTraceKey` and
--- `forgetTrace` -- rather than this file reaching into that resource's state
--- directly, which Lua does not let it do anyway (each resource is its own
--- environment).

FredPD = FredPD or {}
FredPD.Client = FredPD.Client or {}

--- How far from the scanner a revealed print, or a person, may be and still
--- be reached by it. Matches the server's own 3 m collection range (8.3.2):
--- reaching further than that would only ever produce a refusal once the
--- call reaches the core.
local SCAN_RADIUS <const> = 3.0

--- The nearest other player within radius, as a server id -- what a live
--- scan or a ten-print capture both need to name who they act on. The server
--- re-resolves and re-range-checks this itself (8.3.2), so a wrong id here
--- only ever produces a refusal; it is never trusted as a claim about who it
--- names.
---
--- Only real players, never an AI ped: the hidden identifier a scan or a
--- capture resolves this id to comes from the framework bridge, which has
--- nothing to say about a ped nobody is controlling.
---
--- @return number|nil serverId
local function nearestPlayerId(radius)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local best, bestDistance = nil, radius

    for _, playerId in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(playerId)

        if ped ~= myPed and DoesEntityExist(ped) then
            local distance = #(myCoords - GetEntityCoords(ped))

            if distance <= bestDistance then
                best, bestDistance = playerId, distance
            end
        end
    end

    if not best then return nil end

    return GetPlayerServerId(best)
end

--- The nearest `booking_terminal` placement within its own radius, or nil.
---
--- Ten-print capture is limited to the booking terminal (spec 1.4), enforced
--- server-side by the `accessPoint` context condition -- this is only what
--- lets the client hand that route a `placementId` at all, and standing
--- somewhere else still gets refused there, not here.
local function nearestBookingTerminal()
    local position = GetEntityCoords(PlayerPedId())
    local best, bestDistance = nil, math.huge

    for _, placement in pairs(FredPD.Client.placements.all()) do
        if placement.kind == 'booking_terminal' then
            local distance = #(position - vec3(placement.x, placement.y, placement.z))

            if distance <= (placement.radius or 1.5) and distance < bestDistance then
                best, bestDistance = placement, distance
            end
        end
    end

    return best
end

--- The scanner's second action (8.8): who is standing at it, if their prints
--- are already on file. Only reached once `scanForPrint` below finds no
--- revealed trace to collect instead -- a scanner does not choose between
--- the two, it does whichever one there is something to do.
local function scanForIdentity()
    local targetId = nearestPlayerId(SCAN_RADIUS)

    if not targetId then
        FredPD.Client.core.notify('fingerprintScanner.noPrint')
        return
    end

    local response = FredPD.Client.core.call('forensics.identity.scan', { targetId = targetId })

    if not response.ok then
        FredPD.Client.core.showError(response)
        return
    end

    if response.data and response.data.match then
        local person = response.data.person

        FredPD.Client.core.notify('fingerprintScanner.identified', {
            number = person.personNumber,
            name = ('%s %s'):format(person.firstName or '', person.lastName or ''),
        })
    else
        FredPD.Client.core.notify('fingerprintScanner.noMatch')
    end
end

local function scanForPrint(_placement)
    local coords = GetEntityCoords(PlayerPedId())

    local ok, traceKey = pcall(function()
        return exports.fredpd_forensics:nearestPrintTraceKey(coords.x, coords.y, coords.z, SCAN_RADIUS)
    end)

    if not ok or not traceKey then
        scanForIdentity()
        return
    end

    local response = FredPD.Client.core.call('evidence.collect', {
        traceKey = traceKey,
        packaging = 'lift_card',
    })

    if not response.ok then
        FredPD.Client.core.showError(response)
        return
    end

    pcall(function()
        exports.fredpd_forensics:forgetTrace(traceKey)
    end)

    FredPD.Client.core.notify('fingerprintScanner.scanned', {
        number = response.data and response.data.item and response.data.item.evidenceNumber or '?',
    })
end

--- Registered against the placement kind, so the scanner appears wherever an
--- administrator put one (spec 3.10) and nowhere else.
FredPD.Client.placements.registerAction('fingerprint_scanner', scanForPrint)

--- Ten-print capture (8.8's "ten-print cards from booking"): files the
--- nearest player's prints against an open booking, named by the number the
--- officer already has to hand from booking them.
---
--- A deliberate command rather than the scanner's own interact key, unlike
--- the read-only scan above: filing a permanent reference against a named
--- booking is not something standing near somebody should do by pressing the
--- same key that only ever reads. `placement-editor.lua`'s `/fredpd`
--- dispatcher routes `tenprint` here, alongside `placement` and `setup`.
local function captureTenPrint()
    local terminal = nearestBookingTerminal()
    if not terminal then
        FredPD.Client.core.notify('fingerprintScanner.tenPrint.noTerminal')
        return
    end

    local targetId = nearestPlayerId(SCAN_RADIUS)

    if not targetId then
        FredPD.Client.core.notify('fingerprintScanner.noPrint')
        return
    end

    local input = lib.inputDialog(FredPD.t('fingerprintScanner.tenPrint.title'), {
        { type = 'input', label = FredPD.t('fingerprintScanner.tenPrint.numberLabel'), required = true },
    })

    if not input or not input[1] then return end

    local response = FredPD.Client.core.call('booking.tenPrint.capture', {
        number = input[1],
        targetId = targetId,
        placementId = terminal.id,
    })

    if not response.ok then
        FredPD.Client.core.showError(response)
        return
    end

    FredPD.Client.core.notify('fingerprintScanner.tenPrint.captured', { number = response.data.number })
end

FredPD.Client.fingerprintScanner = { capture = captureTenPrint }
