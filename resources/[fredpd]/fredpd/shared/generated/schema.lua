--- GENERATED FILE -- DO NOT EDIT.
---
--- Written by `pnpm schema:gen` from packages/schema/src.
--- Change the TypeScript definitions and regenerate; CI fails on a stale copy.

FredPD = FredPD or {}

--- Route error codes (spec 3.5).
FredPD.ErrorCode = {
    NO_SESSION = 'no_session',
    FORBIDDEN = 'forbidden',
    CONTEXT = 'context',
    RATE_LIMITED = 'rate_limited',
    INVALID = 'invalid',
    NOT_FOUND = 'not_found',
    CONFLICT = 'conflict',
    RESTRICTED = 'restricted',
    STALE_PERMISSIONS = 'stale_permissions',
    INTERNAL = 'internal',
}

--- Where a session opened FredPD from (spec 1.4).
FredPD.AccessPoint = {
    MDC = 'mdc',
    TABLET = 'tablet',
    STATION = 'station',
    PROPERTY = 'property',
    LAB = 'lab',
    BOOKING = 'booking',
    DISPATCH = 'dispatch',
    COURTHOUSE = 'courthouse',
    PORTAL = 'portal',
}

--- Unit status (spec 7.1).
FredPD.UnitStatus = {
    AVAILABLE = 'available',
    EN_ROUTE = 'en_route',
    ON_SCENE = 'on_scene',
    BUSY = 'busy',
    OUT_OF_SERVICE = 'out_of_service',
    PANIC = 'panic',
}
