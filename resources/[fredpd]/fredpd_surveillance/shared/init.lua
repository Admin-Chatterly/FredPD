--- Surveillance resource namespace.
---
--- Scope (spec 9, milestone M5): wiretaps, radio monitoring, listening devices
--- and trackers.
---
--- Every method here is warrant-gated and writes a server-side log. The server
--- decides who may listen and records that they did; the client never holds the
--- authority to start interception (invariants 1, 4 and 11).

FredPDSurveillance = FredPDSurveillance or {}

FredPDSurveillance.resource = GetCurrentResourceName()
FredPDSurveillance.version = GetResourceMetadata(FredPDSurveillance.resource, 'version', 0) or '0.0.0'
