--- Forensics resource namespace.
---
--- Scope (spec 8, milestone M3): evidence generation, scene processing,
--- packaging and destruction mechanics.
---
--- Forensic truth -- whose print it is, whose blood, which weapon fired a
--- casing -- is decided and stored on the server and never sent to a client
--- (invariants 1 and 5). Clients see an unidentified item until the lab
--- reports a result to someone authorized to read it.

FredPDForensics = FredPDForensics or {}

FredPDForensics.resource = GetCurrentResourceName()
FredPDForensics.version = GetResourceMetadata(FredPDForensics.resource, 'version', 0) or '0.0.0'
