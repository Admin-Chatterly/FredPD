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

--- How far from the scanner a revealed print may be and still be picked up by
--- it. Matches the server's own 3 m collection range (8.3.2): reaching further
--- than that would only ever produce a refusal once the call reaches the core.
local SCAN_RADIUS <const> = 3.0

local function scanForPrint(_placement)
    local coords = GetEntityCoords(PlayerPedId())

    local ok, traceKey = pcall(function()
        return exports.fredpd_forensics:nearestPrintTraceKey(coords.x, coords.y, coords.z, SCAN_RADIUS)
    end)

    if not ok or not traceKey then
        FredPD.Client.core.notify('fingerprintScanner.noPrint')
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
