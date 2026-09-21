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
    OFF_DUTY = 'off_duty',
    AVAILABLE = 'available',
    EN_ROUTE = 'en_route',
    ON_SCENE = 'on_scene',
    BUSY = 'busy',
    TRANSPORTING = 'transporting',
    AT_STATION = 'at_station',
    OUT_OF_SERVICE = 'out_of_service',
    EMERGENCY = 'emergency',
}

--- What a world placement opens (spec 3.10).
FredPD.PlacementKind = {
    STATION_TERMINAL = 'station_terminal',
    PROPERTY_TERMINAL = 'property_terminal',
    LAB_TERMINAL = 'lab_terminal',
    BOOKING_TERMINAL = 'booking_terminal',
    DISPATCH_CONSOLE = 'dispatch_console',
    COURTHOUSE_TERMINAL = 'courthouse_terminal',
    MOTORPOOL = 'motorpool',
    EVIDENCE_BENCH = 'evidence_bench',
}

--- How a placement is reached in the world (spec 3.10).
FredPD.PlacementInteraction = {
    PROP = 'prop',
    PED = 'ped',
    ZONE = 'zone',
}

--- Person of interest status (spec 10).
FredPD.IntelPersonStatus = {
    UNKNOWN = 'unknown',
    POI = 'poi',
    ACTIVE_INVESTIGATION = 'active_investigation',
    WARRANT = 'warrant',
    CLEARED = 'cleared',
    INCARCERATED = 'incarcerated',
    DECEASED = 'deceased',
}

--- Organisation type (spec 10).
FredPD.IntelOrgType = {
    GANG = 'gang',
    CARTEL = 'cartel',
    BUSINESS = 'business',
    CREW = 'crew',
    OTHER = 'other',
}

--- Organisation status (spec 10).
FredPD.IntelOrgStatus = {
    ACTIVE = 'active',
    DISBANDED = 'disbanded',
    DORMANT = 'dormant',
}

--- Where a piece of intelligence came from (spec 10).
FredPD.IntelSource = {
    INFORMANT = 'informant',
    WIRETAP = 'wiretap',
    SURVEILLANCE = 'surveillance',
    PATROL = 'patrol',
    TIP = 'tip',
    OTHER = 'other',
}

--- Confidence in a piece of intelligence (spec 10).
FredPD.IntelConfidence = {
    LOW = 'low',
    MEDIUM = 'medium',
    HIGH = 'high',
}

--- Case status (spec 10).
FredPD.IntelCaseStatus = {
    OPEN = 'open',
    CLOSED = 'closed',
    COLD = 'cold',
}

--- Record classification levels (spec 4.5).
FredPD.Classification = {
    OPEN = 'open',
    INTERNAL = 'internal',
    RESTRICTED = 'restricted',
    CONFIDENTIAL = 'confidential',
    SECRET = 'secret',
}

--- What an officer may set on their own unit (spec 7.16; Appendix F's ST).
FredPD.SelfSetUnitStatus = {
    AVAILABLE = 'available',
    EN_ROUTE = 'en_route',
    ON_SCENE = 'on_scene',
    BUSY = 'busy',
    TRANSPORTING = 'transporting',
    AT_STATION = 'at_station',
    OUT_OF_SERVICE = 'out_of_service',
}

--- What a supervisor may set on somebody else (spec 7.16).
FredPD.SupervisorUnitStatus = {
    OFF_DUTY = 'off_duty',
    AVAILABLE = 'available',
    EN_ROUTE = 'en_route',
    ON_SCENE = 'on_scene',
    BUSY = 'busy',
    TRANSPORTING = 'transporting',
    AT_STATION = 'at_station',
    OUT_OF_SERVICE = 'out_of_service',
}

--- The progress a unit reports on a call (spec 7.16).
FredPD.CallProgressStatus = {
    EN_ROUTE = 'en_route',
    ON_SCENE = 'on_scene',
}

--- Call priority P1-P4 (Appendix E).
FredPD.CallPriority = {
    P1 = 1,
    P2 = 2,
    P3 = 3,
    P4 = 4,
}

--- The call lifecycle (spec 7.16, Appendix E).
FredPD.CallStatus = {
    PENDING = 'pending',
    DISPATCHED = 'dispatched',
    EN_ROUTE = 'en_route',
    ON_SCENE = 'on_scene',
    CLEARED = 'cleared',
    CANCELLED = 'cancelled',
}

--- What a call is (spec 7.16).
FredPD.CallType = {
    ALARM = 'alarm',
    ASSAULT = 'assault',
    BACKUP = 'backup',
    BURGLARY = 'burglary',
    DISTURBANCE = 'disturbance',
    DOMESTIC = 'domestic',
    DRUGS = 'drugs',
    MISSING_PERSON = 'missing_person',
    OFFICER_EMERGENCY = 'officer_emergency',
    PURSUIT = 'pursuit',
    ROBBERY = 'robbery',
    SHOTS_FIRED = 'shots_fired',
    STOLEN_VEHICLE = 'stolen_vehicle',
    SUSPICIOUS = 'suspicious',
    THEFT = 'theft',
    TRAFFIC_COLLISION = 'traffic_collision',
    TRAFFIC_STOP = 'traffic_stop',
    WARRANT_SERVICE = 'warrant_service',
    WEAPONS = 'weapons',
    WELFARE_CHECK = 'welfare_check',
    OTHER = 'other',
}

--- How a call ended (spec 7.16).
FredPD.CallDisposition = {
    REPORT_TAKEN = 'report_taken',
    ARREST_MADE = 'arrest_made',
    CITATION_ISSUED = 'citation_issued',
    WARNING_GIVEN = 'warning_given',
    HANDLED_ON_SCENE = 'handled_on_scene',
    ASSISTANCE_RENDERED = 'assistance_rendered',
    GONE_ON_ARRIVAL = 'gone_on_arrival',
    UNABLE_TO_LOCATE = 'unable_to_locate',
    UNFOUNDED = 'unfounded',
    REFERRED = 'referred',
    DUPLICATE = 'duplicate',
    CANCELLED = 'cancelled',
}

--- What a line in the narrative log is (spec 7.16).
FredPD.CallLogKind = {
    CREATED = 'created',
    NOTE = 'note',
    DISPATCHED = 'dispatched',
    UNIT_JOINED = 'unit_joined',
    UNIT_LEFT = 'unit_left',
    LEAD_CHANGED = 'lead_changed',
    UNIT_STATUS = 'unit_status',
    CALL_STATUS = 'call_status',
    LINKED = 'linked',
    UNLINKED = 'unlinked',
    CLEARED = 'cleared',
}

--- What can be linked to a call (spec 7.16).
FredPD.CallLinkKind = {
    PERSON = 'person',
    VEHICLE = 'vehicle',
}

--- How a person or vehicle is involved (spec 7.16).
FredPD.CallLinkRole = {
    CALLER = 'caller',
    VICTIM = 'victim',
    SUSPECT = 'suspect',
    WITNESS = 'witness',
    INVOLVED = 'involved',
}

--- What a dispatch broadcast is (spec 7.16).
FredPD.BroadcastKind = {
    BOLO = 'bolo',
    ATTEMPT_TO_LOCATE = 'attempt_to_locate',
    ALL_UNITS = 'all_units',
    INFORMATION = 'information',
}

--- Why a plate is on the ALPR hotlist (spec 7.18).
FredPD.HotlistReason = {
    STOLEN_VEHICLE = 'stolen_vehicle',
    WANTED_PERSON = 'wanted_person',
    WARRANT = 'warrant',
    BOLO = 'bolo',
    INVESTIGATION = 'investigation',
    OTHER = 'other',
}

--- Route input schemas (spec 3.5). The route layer validates against these and
--- drops any key not listed, so a handler never sees a field it did not ask for.
FredPD.Schema = {
    PlacementList = {
        agencyId = { type = 'string', required = false, max = 32 },
    },

    PlacementCreate = {
        kind = { type = 'enum', required = true, values = { 'station_terminal', 'property_terminal', 'lab_terminal', 'booking_terminal', 'dispatch_console', 'courthouse_terminal', 'motorpool', 'evidence_bench' } },
        interaction = { type = 'enum', required = true, values = { 'prop', 'ped', 'zone' } },
        agencyId = { type = 'string', required = false, max = 32 },
        model = { type = 'string', required = false, max = 64 },
        x = { type = 'number', required = true },
        y = { type = 'number', required = true },
        z = { type = 'number', required = true },
        heading = { type = 'number', required = false, min = 0, max = 360 },
        radius = { type = 'number', required = false, min = 0.5, max = 50 },
        labelKey = { type = 'string', required = false, max = 128 },
    },

    PlacementUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        kind = { type = 'enum', required = false, values = { 'station_terminal', 'property_terminal', 'lab_terminal', 'booking_terminal', 'dispatch_console', 'courthouse_terminal', 'motorpool', 'evidence_bench' } },
        interaction = { type = 'enum', required = false, values = { 'prop', 'ped', 'zone' } },
        model = { type = 'string', required = false, max = 64 },
        x = { type = 'number', required = false },
        y = { type = 'number', required = false },
        z = { type = 'number', required = false },
        heading = { type = 'number', required = false, min = 0, max = 360 },
        radius = { type = 'number', required = false, min = 0.5, max = 50 },
        labelKey = { type = 'string', required = false, max = 128 },
        enabled = { type = 'boolean', required = false },
    },

    PlacementDelete = {
        id = { type = 'integer', required = true, min = 1 },
    },

    ChatSend = {
        body = { type = 'string', required = true, min = 1, max = 512 },
    },

    ChatHistory = {
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    RoleMapList = {
        agencyId = { type = 'string', required = false, max = 32 },
    },

    RoleMapCreate = {
        discordRoleId = { type = 'string', required = true, min = 17, max = 32 },
        discordRoleName = { type = 'string', required = false, max = 191 },
        groupKey = { type = 'string', required = true, max = 64 },
        agencyId = { type = 'string', required = true, max = 32 },
    },

    RoleMapDelete = {
        id = { type = 'integer', required = true, min = 1 },
    },

    GroupList = {

    },

    GroupCreate = {
        key = { type = 'string', required = true, min = 2, max = 64 },
        name = { type = 'string', required = true, min = 1, max = 191 },
        inherits = { type = 'string', required = false, max = 64 },
        description = { type = 'string', required = false, max = 255 },
        permissions = { type = 'string[]', required = true, maxItems = 256, maxLength = 128 },
    },

    GroupUpdate = {
        key = { type = 'string', required = true, min = 2, max = 64 },
        version = { type = 'integer', required = true, min = 1 },
        name = { type = 'string', required = false, min = 1, max = 191 },
        inherits = { type = 'string', required = false, max = 64 },
        description = { type = 'string', required = false, max = 255 },
        permissions = { type = 'string[]', required = false, maxItems = 256, maxLength = 128 },
    },

    GroupDelete = {
        key = { type = 'string', required = true, min = 2, max = 64 },
    },

    PermissionList = {

    },

    FleetList = {
        placementId = { type = 'integer', required = true, min = 1 },
    },

    GarageDraw = {
        placementId = { type = 'integer', required = true, min = 1 },
        model = { type = 'string', required = true, max = 64 },
    },

    GarageReturn = {
        placementId = { type = 'integer', required = true, min = 1 },
        plate = { type = 'string', required = true, max = 16 },
    },

    FleetManage = {

    },

    FleetAdd = {
        model = { type = 'string', required = true, min = 1, max = 64 },
        labelKey = { type = 'string', required = true, min = 3, max = 128 },
        permission = { type = 'string', required = false, max = 128 },
        certification = { type = 'string', required = false, max = 64 },
        livery = { type = 'integer', required = false, min = -1, max = 63 },
        sortOrder = { type = 'integer', required = false, min = 0, max = 9999 },
        enabled = { type = 'boolean', required = false },
        requiredGroup = { type = 'string', required = false, max = 64 },
        requiredDiscordRole = { type = 'string', required = false, max = 32 },
    },

    FleetUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        model = { type = 'string', required = false, max = 64 },
        labelKey = { type = 'string', required = false, max = 128 },
        permission = { type = 'string', required = false, max = 128 },
        certification = { type = 'string', required = false, max = 64 },
        livery = { type = 'integer', required = false, min = -1, max = 63 },
        sortOrder = { type = 'integer', required = false, min = 0, max = 9999 },
        enabled = { type = 'boolean', required = false },
        requiredGroup = { type = 'string', required = false, max = 64 },
        requiredDiscordRole = { type = 'string', required = false, max = 32 },
    },

    FleetRemove = {
        id = { type = 'integer', required = true, min = 1 },
    },

    SceneCreate = {
        caseNumber = { type = 'string', required = false, max = 32 },
        radius = { type = 'number', required = false, min = 5, max = 500 },
    },

    SceneRelease = {
        id = { type = 'integer', required = true, min = 1 },
        reason = { type = 'string', required = false, max = 255 },
    },

    SceneList = {
        status = { type = 'enum', required = false, values = { 'open', 'released' } },
        caseNumber = { type = 'string', required = false, max = 32 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    EvidenceCollect = {
        traceKey = { type = 'string', required = false, min = 1, max = 64 },
        targetId = { type = 'integer', required = false, min = 1 },
        sceneId = { type = 'integer', required = false, min = 1 },
        caseNumber = { type = 'string', required = false, max = 32 },
        packaging = { type = 'enum', required = false, values = { 'evidence_bag', 'envelope', 'swab_box', 'lift_card', 'firearm_box', 'drug_bag', 'phone_bag', 'item_tag' } },
        markerNumber = { type = 'integer', required = false, min = 1, max = 999 },
        description = { type = 'string', required = false, max = 512 },
    },

    EvidenceList = {
        status = { type = 'enum', required = false, values = { 'collected', 'in_locker', 'in_property', 'checked_out', 'at_lab', 'released', 'destroyed' } },
        type = { type = 'enum', required = false, values = { 'print', 'blood', 'dna_touch', 'casing', 'bullet', 'magazine', 'gsr', 'footwear', 'glove_mark', 'drug_residue', 'tool_mark', 'digital' } },
        sceneId = { type = 'integer', required = false, min = 1 },
        caseNumber = { type = 'string', required = false, max = 32 },
        search = { type = 'string', required = false, max = 64 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    EvidenceGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    EvidenceCustody = {
        id = { type = 'integer', required = true, min = 1 },
    },

    EvidenceIntake = {
        placementId = { type = 'integer', required = true, min = 1 },
        id = { type = 'integer', required = true, min = 1 },
        accepted = { type = 'boolean', required = true },
        storageLocation = { type = 'string', required = false, max = 64 },
        reason = { type = 'string', required = false, max = 255 },
    },

    EvidenceTransfer = {
        id = { type = 'integer', required = true, min = 1 },
        destination = { type = 'enum', required = true, values = { 'locker', 'lab', 'court', 'investigator' } },
        placementId = { type = 'integer', required = false, min = 1 },
        toParty = { type = 'string', required = false, max = 191 },
        reason = { type = 'string', required = true, min = 1, max = 255 },
    },

    LabRequestCreate = {
        evidenceIds = { type = 'string[]', required = true, maxItems = 25, maxLength = 20 },
        analyses = { type = 'string[]', required = true, maxItems = 6, maxLength = 32 },
        priority = { type = 'enum', required = false, values = { 'routine', 'expedited', 'urgent' } },
        caseNumber = { type = 'string', required = false, max = 32 },
        justification = { type = 'string', required = false, max = 512 },
    },

    LabQueue = {
        status = { type = 'enum', required = false, values = { 'queued', 'in_progress', 'complete', 'reviewed', 'released', 'cancelled' } },
        analysis = { type = 'enum', required = false, values = { 'dna', 'print_comparison', 'print_search', 'ballistics', 'gsr', 'drug_id' } },
        mine = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    LabAnalysisStart = {
        id = { type = 'integer', required = true, min = 1 },
        placementId = { type = 'integer', required = true, min = 1 },
    },

    LabAnalysisComplete = {
        id = { type = 'integer', required = true, min = 1 },
        placementId = { type = 'integer', required = true, min = 1 },
        observations = { type = 'string', required = false, max = 1024 },
    },

    IntelId = {
        id = { type = 'integer', required = true, min = 1 },
    },

    IntelSearch = {
        term = { type = 'string', required = true, min = 2, max = 128 },
        perType = { type = 'integer', required = false, min = 1, max = 25 },
    },

    IntelPersonList = {
        search = { type = 'string', required = false, max = 128 },
        status = { type = 'enum', required = false, values = { 'unknown', 'poi', 'active_investigation', 'warrant', 'cleared', 'incarcerated', 'deceased' } },
        tag = { type = 'string', required = false, max = 64 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    IntelPersonCreate = {
        name = { type = 'string', required = false, max = 191 },
        alias = { type = 'string', required = false, max = 191 },
        description = { type = 'string', required = false, max = 4000 },
        status = { type = 'enum', required = false, values = { 'unknown', 'poi', 'active_investigation', 'warrant', 'cleared', 'incarcerated', 'deceased' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelPersonUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        name = { type = 'string', required = false, max = 191 },
        alias = { type = 'string', required = false, max = 191 },
        description = { type = 'string', required = false, max = 4000 },
        status = { type = 'enum', required = false, values = { 'unknown', 'poi', 'active_investigation', 'warrant', 'cleared', 'incarcerated', 'deceased' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelPersonMerge = {
        keepId = { type = 'integer', required = true, min = 1 },
        dropId = { type = 'integer', required = true, min = 1 },
    },

    IntelOrgList = {
        search = { type = 'string', required = false, max = 128 },
        tag = { type = 'string', required = false, max = 64 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    IntelOrgCreate = {
        name = { type = 'string', required = true, min = 1, max = 191 },
        type = { type = 'enum', required = false, values = { 'gang', 'cartel', 'business', 'crew', 'other' } },
        territory = { type = 'string', required = false, max = 191 },
        status = { type = 'enum', required = false, values = { 'active', 'disbanded', 'dormant' } },
        notes = { type = 'string', required = false, max = 4000 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelOrgUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        name = { type = 'string', required = false, min = 1, max = 191 },
        type = { type = 'enum', required = false, values = { 'gang', 'cartel', 'business', 'crew', 'other' } },
        territory = { type = 'string', required = false, max = 191 },
        status = { type = 'enum', required = false, values = { 'active', 'disbanded', 'dormant' } },
        notes = { type = 'string', required = false, max = 4000 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelNoteList = {
        personId = { type = 'integer', required = false, min = 1 },
        orgId = { type = 'integer', required = false, min = 1 },
        caseId = { type = 'integer', required = false, min = 1 },
        source = { type = 'enum', required = false, values = { 'informant', 'wiretap', 'surveillance', 'patrol', 'tip', 'other' } },
        confidence = { type = 'enum', required = false, values = { 'low', 'medium', 'high' } },
        tag = { type = 'string', required = false, max = 64 },
        search = { type = 'string', required = false, max = 128 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    IntelNoteCreate = {
        personId = { type = 'integer', required = false, min = 1 },
        orgId = { type = 'integer', required = false, min = 1 },
        caseId = { type = 'integer', required = false, min = 1 },
        body = { type = 'string', required = true, min = 1, max = 8000 },
        source = { type = 'enum', required = false, values = { 'informant', 'wiretap', 'surveillance', 'patrol', 'tip', 'other' } },
        confidence = { type = 'enum', required = false, values = { 'low', 'medium', 'high' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        tags = { type = 'string[]', required = false, maxItems = 12, maxLength = 64 },
    },

    IntelNoteUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        body = { type = 'string', required = false, min = 1, max = 8000 },
        source = { type = 'enum', required = false, values = { 'informant', 'wiretap', 'surveillance', 'patrol', 'tip', 'other' } },
        confidence = { type = 'enum', required = false, values = { 'low', 'medium', 'high' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        tags = { type = 'string[]', required = false, maxItems = 12, maxLength = 64 },
    },

    IntelVehicleCreate = {
        personId = { type = 'integer', required = false, min = 1 },
        plate = { type = 'string', required = false, max = 16 },
        model = { type = 'string', required = false, max = 64 },
        color = { type = 'string', required = false, max = 64 },
        notes = { type = 'string', required = false, max = 2000 },
    },

    IntelCaseList = {
        status = { type = 'enum', required = false, values = { 'open', 'closed', 'cold' } },
        search = { type = 'string', required = false, max = 128 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    IntelCaseCreate = {
        title = { type = 'string', required = true, min = 1, max = 191 },
        description = { type = 'string', required = false, max = 8000 },
        status = { type = 'enum', required = false, values = { 'open', 'closed', 'cold' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelCaseUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        title = { type = 'string', required = false, min = 1, max = 191 },
        description = { type = 'string', required = false, max = 8000 },
        status = { type = 'enum', required = false, values = { 'open', 'closed', 'cold' } },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    IntelCaseLinkAdd = {
        caseId = { type = 'integer', required = true, min = 1 },
        personId = { type = 'integer', required = false, min = 1 },
        orgId = { type = 'integer', required = false, min = 1 },
        role = { type = 'string', required = false, max = 191 },
    },

    IntelMembershipSet = {
        personId = { type = 'integer', required = true, min = 1 },
        orgId = { type = 'integer', required = true, min = 1 },
        role = { type = 'string', required = false, max = 191 },
        isConfirmed = { type = 'boolean', required = false },
    },

    IntelMembershipRemove = {
        personId = { type = 'integer', required = true, min = 1 },
        orgId = { type = 'integer', required = true, min = 1 },
    },

    IntelAssociateSet = {
        personId = { type = 'integer', required = true, min = 1 },
        associateId = { type = 'integer', required = true, min = 1 },
        relationship = { type = 'string', required = false, max = 191 },
        isConfirmed = { type = 'boolean', required = false },
    },

    IntelAssociateRemove = {
        personId = { type = 'integer', required = true, min = 1 },
        associateId = { type = 'integer', required = true, min = 1 },
    },

    IntelEvidenceAdd = {
        personId = { type = 'integer', required = false, min = 1 },
        orgId = { type = 'integer', required = false, min = 1 },
        caseId = { type = 'integer', required = false, min = 1 },
        url = { type = 'string', required = false, max = 1024 },
        storagePath = { type = 'string', required = false, max = 512 },
        caption = { type = 'string', required = false, max = 512 },
    },

    PersonSearch = {
        term = { type = 'string', required = true, min = 2, max = 191 },
        dateOfBirth = { type = 'string', required = false, max = 10 },
        limit = { type = 'integer', required = false, min = 1, max = 50 },
        reason = { type = 'string', required = false, max = 255 },
        caseNumber = { type = 'string', required = false, max = 32 },
    },

    PersonGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    PersonUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        firstName = { type = 'string', required = false, max = 96 },
        middleName = { type = 'string', required = false, max = 96 },
        lastName = { type = 'string', required = false, max = 96 },
        dateOfBirth = { type = 'string', required = false, max = 10 },
        sex = { type = 'enum', required = false, values = { 'male', 'female', 'other', 'unknown' } },
        phone = { type = 'string', required = false, max = 32 },
        address = { type = 'string', required = false, max = 191 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        deceased = { type = 'boolean', required = false },
        missing = { type = 'boolean', required = false },
    },

    PersonCautionSet = {
        cancel = { type = 'boolean', required = false },
        cautionId = { type = 'integer', required = false, min = 1 },
        personId = { type = 'integer', required = false, min = 1 },
        kind = { type = 'enum', required = false, values = { 'armed', 'violent', 'officer_safety', 'mental_health', 'gang' } },
        detail = { type = 'string', required = false, max = 512 },
        sourceCase = { type = 'string', required = false, max = 32 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        expiresInDays = { type = 'integer', required = false, min = 0, max = 3650 },
    },

    VehicleSearch = {
        term = { type = 'string', required = false, max = 24 },
        ownerPersonId = { type = 'integer', required = false, min = 1 },
        ownerIdentifier = { type = 'string', required = false, max = 191 },
        limit = { type = 'integer', required = false, min = 1, max = 100 },
        reason = { type = 'string', required = false, max = 255 },
        caseNumber = { type = 'string', required = false, max = 32 },
    },

    VehicleGet = {
        id = { type = 'integer', required = false, min = 1 },
        plate = { type = 'string', required = false, max = 16 },
        vin = { type = 'string', required = false, max = 24 },
        reason = { type = 'string', required = false, max = 255 },
        caseNumber = { type = 'string', required = false, max = 32 },
    },

    VehicleRegister = {
        plate = { type = 'string', required = true, min = 1, max = 16 },
        model = { type = 'string', required = false, max = 64 },
        colour = { type = 'string', required = false, max = 32 },
        colourSecondary = { type = 'string', required = false, max = 32 },
        ownerPersonId = { type = 'integer', required = false, min = 1 },
        ownerIdentifier = { type = 'string', required = false, max = 191 },
        registrationStatus = { type = 'enum', required = false, values = { 'valid', 'expired', 'suspended', 'revoked', 'unregistered' } },
        insuranceStatus = { type = 'enum', required = false, values = { 'valid', 'expired', 'none' } },
        registrationExpires = { type = 'string', required = false, max = 10 },
        insuranceExpires = { type = 'string', required = false, max = 10 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        reason = { type = 'string', required = false, max = 191 },
    },

    VehicleUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        model = { type = 'string', required = false, max = 64 },
        colour = { type = 'string', required = false, max = 32 },
        colourSecondary = { type = 'string', required = false, max = 32 },
        ownerPersonId = { type = 'integer', required = false, min = 0 },
        ownerIdentifier = { type = 'string', required = false, max = 191 },
        registrationStatus = { type = 'enum', required = false, values = { 'valid', 'expired', 'suspended', 'revoked', 'unregistered' } },
        insuranceStatus = { type = 'enum', required = false, values = { 'valid', 'expired', 'none' } },
        registrationExpires = { type = 'string', required = false, max = 10 },
        insuranceExpires = { type = 'string', required = false, max = 10 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    VehiclePlateChange = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        plate = { type = 'string', required = true, min = 1, max = 16 },
        reason = { type = 'string', required = false, max = 191 },
    },

    VehicleFlag = {
        vehicleId = { type = 'integer', required = true, min = 1 },
        kind = { type = 'enum', required = true, values = { 'stolen', 'wanted', 'bolo', 'impounded', 'evidence_hold', 'uninsured' } },
        detail = { type = 'string', required = false, max = 512 },
        caseNumber = { type = 'string', required = false, max = 32 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        expiresIn = { type = 'integer', required = false, min = 0, max = 31536000 },
    },

    VehicleFlagClear = {
        flagId = { type = 'integer', required = true, min = 1 },
    },

    FirearmSearch = {
        term = { type = 'string', required = false, max = 64 },
        ownerPersonId = { type = 'integer', required = false, min = 1 },
        ownerIdentifier = { type = 'string', required = false, max = 191 },
        status = { type = 'enum', required = false, values = { 'registered', 'lost', 'stolen', 'seized', 'destroyed', 'agency_issued' } },
        assignedOfficer = { type = 'string', required = false, max = 32 },
        limit = { type = 'integer', required = false, min = 1, max = 100 },
        reason = { type = 'string', required = false, max = 255 },
        caseNumber = { type = 'string', required = false, max = 32 },
    },

    FirearmGet = {
        id = { type = 'integer', required = false, min = 1 },
        serial = { type = 'string', required = false, max = 64 },
        reason = { type = 'string', required = false, max = 255 },
        caseNumber = { type = 'string', required = false, max = 32 },
    },

    FirearmRegister = {
        serial = { type = 'string', required = true, min = 1, max = 64 },
        make = { type = 'string', required = false, max = 64 },
        model = { type = 'string', required = false, max = 64 },
        type = { type = 'enum', required = false, values = { 'pistol', 'revolver', 'rifle', 'shotgun', 'smg', 'other' } },
        calibre = { type = 'string', required = false, max = 24 },
        status = { type = 'enum', required = false, values = { 'registered', 'lost', 'stolen', 'seized', 'destroyed', 'agency_issued' } },
        ownerPersonId = { type = 'integer', required = false, min = 1 },
        ownerIdentifier = { type = 'string', required = false, max = 191 },
        ownerParty = { type = 'string', required = false, max = 191 },
        assignedOfficer = { type = 'string', required = false, max = 32 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        caseNumber = { type = 'string', required = false, max = 32 },
        reason = { type = 'string', required = false, max = 512 },
    },

    FirearmUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        make = { type = 'string', required = false, max = 64 },
        model = { type = 'string', required = false, max = 64 },
        type = { type = 'enum', required = false, values = { 'pistol', 'revolver', 'rifle', 'shotgun', 'smg', 'other' } },
        calibre = { type = 'string', required = false, max = 24 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    FirearmTransfer = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        toPersonId = { type = 'integer', required = false, min = 1 },
        toIdentifier = { type = 'string', required = false, max = 191 },
        toParty = { type = 'string', required = false, max = 191 },
        fromParty = { type = 'string', required = false, max = 191 },
        caseNumber = { type = 'string', required = false, max = 32 },
        reason = { type = 'string', required = false, max = 512 },
    },

    FirearmStatus = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        status = { type = 'enum', required = true, values = { 'registered', 'lost', 'stolen', 'seized', 'destroyed', 'agency_issued' } },
        caseNumber = { type = 'string', required = false, max = 32 },
        reason = { type = 'string', required = false, max = 512 },
    },

    FirearmAssign = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        assignedOfficer = { type = 'string', required = false, max = 32 },
        caseNumber = { type = 'string', required = false, max = 32 },
        reason = { type = 'string', required = false, max = 512 },
    },

    FirearmTrace = {
        id = { type = 'integer', required = false, min = 1 },
        serial = { type = 'string', required = false, max = 64 },
    },

    QueryRun = {
        term = { type = 'string', required = true, min = 2, max = 191 },
        type = { type = 'string', required = false, max = 16 },
        limit = { type = 'integer', required = false, min = 1, max = 50 },
        reason = { type = 'string', required = false, max = 255 },
        caseNumber = { type = 'string', required = false, max = 32 },
    },

    QueryHitConfirm = {
        queryId = { type = 'integer', required = false, min = 1 },
        hitType = { type = 'string', required = true, max = 24 },
        hitId = { type = 'integer', required = true, min = 1 },
        outcome = { type = 'string', required = true, max = 16 },
        caseNumber = { type = 'string', required = false, max = 32 },
        detail = { type = 'string', required = false, max = 512 },
    },

    QueryLog = {
        mine = { type = 'boolean', required = false },
        discordId = { type = 'string', required = false, max = 32 },
        queryType = { type = 'string', required = false, max = 16 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    ForensicsObserve = {
        kind = { type = 'enum', required = true, values = { 'shot', 'reload', 'surface', 'vehicle_door', 'item_use', 'tool' } },
        netId = { type = 'integer', required = false, min = 1 },
        doorIndex = { type = 'integer', required = false, min = 0, max = 7 },
    },

    ForensicsProcess = {
        tool = { type = 'enum', required = true, values = { 'powder', 'luminol', 'forensic_light' } },
    },

    ForensicsDestroy = {
        action = { type = 'enum', required = true, values = { 'wipe', 'weapon', 'clean', 'wash', 'pickup' } },
        traceKey = { type = 'string', required = false, max = 64 },
        netId = { type = 'integer', required = false, min = 1 },
    },

    CallCreate = {
        placementId = { type = 'integer', required = true, min = 1 },
        type = { type = 'enum', required = true, values = { 'alarm', 'assault', 'backup', 'burglary', 'disturbance', 'domestic', 'drugs', 'missing_person', 'officer_emergency', 'pursuit', 'robbery', 'shots_fired', 'stolen_vehicle', 'suspicious', 'theft', 'traffic_collision', 'traffic_stop', 'warrant_service', 'weapons', 'welfare_check', 'other' } },
        priority = { type = 'integer', required = true, min = 1, max = 4 },
        locationText = { type = 'string', required = true, min = 1, max = 191 },
        beatId = { type = 'integer', required = false, min = 1 },
        callerName = { type = 'string', required = false, max = 191 },
        callerPhone = { type = 'string', required = false, max = 32 },
        details = { type = 'string', required = false, max = 1000 },
    },

    CallList = {
        status = { type = 'enum', required = false, values = { 'pending', 'dispatched', 'en_route', 'on_scene', 'cleared', 'cancelled' } },
        priority = { type = 'integer', required = false, min = 1, max = 4 },
        beatId = { type = 'integer', required = false, min = 1 },
        mine = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    CallGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    CallDispatch = {
        placementId = { type = 'integer', required = true, min = 1 },
        callId = { type = 'integer', required = true, min = 1 },
        officerIds = { type = 'string[]', required = false, maxItems = 12, maxLength = 20 },
        removeOfficerIds = { type = 'string[]', required = false, maxItems = 12, maxLength = 20 },
        leadOfficerId = { type = 'string', required = false, min = 1, max = 20 },
    },

    CallSelfAssign = {
        callId = { type = 'integer', required = true, min = 1 },
    },

    CallStatus = {
        callId = { type = 'integer', required = true, min = 1 },
        status = { type = 'enum', required = true, values = { 'en_route', 'on_scene' } },
    },

    CallClear = {
        callId = { type = 'integer', required = true, min = 1 },
        disposition = { type = 'enum', required = true, values = { 'report_taken', 'arrest_made', 'citation_issued', 'warning_given', 'handled_on_scene', 'assistance_rendered', 'gone_on_arrival', 'unable_to_locate', 'unfounded', 'referred', 'duplicate', 'cancelled' } },
        note = { type = 'string', required = false, max = 1000 },
    },

    CallAcknowledge = {
        callId = { type = 'integer', required = true, min = 1 },
    },

    CallNote = {
        callId = { type = 'integer', required = true, min = 1 },
        body = { type = 'string', required = true, min = 1, max = 1000 },
    },

    CallLink = {
        callId = { type = 'integer', required = true, min = 1 },
        kind = { type = 'enum', required = true, values = { 'person', 'vehicle' } },
        targetId = { type = 'integer', required = true, min = 1 },
        role = { type = 'enum', required = false, values = { 'caller', 'victim', 'suspect', 'witness', 'involved' } },
        remove = { type = 'boolean', required = false },
    },

    UnitList = {
        status = { type = 'enum', required = false, values = { 'off_duty', 'available', 'en_route', 'on_scene', 'busy', 'transporting', 'at_station', 'out_of_service', 'emergency' } },
        beatId = { type = 'integer', required = false, min = 1 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    UnitStatus = {
        status = { type = 'enum', required = true, values = { 'available', 'en_route', 'on_scene', 'busy', 'transporting', 'at_station', 'out_of_service' } },
    },

    UnitManage = {
        officerId = { type = 'integer', required = true, min = 1 },
        status = { type = 'enum', required = false, values = { 'off_duty', 'available', 'en_route', 'on_scene', 'busy', 'transporting', 'at_station', 'out_of_service' } },
        callsign = { type = 'string', required = false, max = 32 },
        beatId = { type = 'integer', required = false, min = 1 },
        reason = { type = 'string', required = false, max = 255 },
    },

    Emergency = {

    },

    BroadcastCreate = {
        kind = { type = 'enum', required = true, values = { 'bolo', 'attempt_to_locate', 'all_units', 'information' } },
        priority = { type = 'integer', required = false, min = 1, max = 4 },
        title = { type = 'string', required = true, min = 1, max = 128 },
        body = { type = 'string', required = true, min = 1, max = 2000 },
        plate = { type = 'string', required = false, max = 16 },
        expiresInMinutes = { type = 'integer', required = false, min = 5, max = 10080 },
    },

    BroadcastCancel = {
        id = { type = 'integer', required = true, min = 1 },
    },

    BroadcastList = {
        includeExpired = { type = 'boolean', required = false },
        kind = { type = 'enum', required = false, values = { 'bolo', 'attempt_to_locate', 'all_units', 'information' } },
        callId = { type = 'integer', required = false, min = 1 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    BeatList = {

    },

    MapView = {
        subscribe = { type = 'boolean', required = false },
    },

    AlprReadList = {
        plate = { type = 'string', required = false, min = 2, max = 16 },
        officerId = { type = 'integer', required = false, min = 1 },
        sinceHours = { type = 'integer', required = false, min = 1, max = 720 },
        hitsOnly = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    AlprHotlistEdit = {
        plate = { type = 'string', required = true, min = 2, max = 16 },
        remove = { type = 'boolean', required = false },
        reason = { type = 'enum', required = false, values = { 'stolen_vehicle', 'wanted_person', 'warrant', 'bolo', 'investigation', 'other' } },
        note = { type = 'string', required = false, max = 255 },
        caseNumber = { type = 'string', required = false, max = 32 },
        silent = { type = 'boolean', required = false },
        expiresInMinutes = { type = 'integer', required = false, min = 5, max = 43200 },
    },

    AlprHotlistList = {
        plate = { type = 'string', required = false, min = 2, max = 16 },
        reason = { type = 'enum', required = false, values = { 'stolen_vehicle', 'wanted_person', 'warrant', 'bolo', 'investigation', 'other' } },
        includeExpired = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    BrottList = {

    },

    BrottVersions = {
        code = { type = 'string', required = true, min = 1, max = 32 },
    },

    BrottStraffskala = {
        brottIds = { type = 'string[]', required = true, maxItems = 25, maxLength = 20 },
    },

    BrottCreate = {
        code = { type = 'string', required = true, min = 1, max = 32 },
        balk = { type = 'string', required = false, max = 16 },
        kapitel = { type = 'integer', required = false, min = 1, max = 255 },
        paragraf = { type = 'integer', required = false, min = 1, max = 255 },
        stycke = { type = 'integer', required = false, min = 1, max = 255 },
        labelKey = { type = 'string', required = true, min = 1, max = 128 },
        descriptionKey = { type = 'string', required = false, max = 128 },
        grad = { type = 'enum', required = true, values = { 'ringa', 'normal', 'grov', 'synnerligen_grov' } },
        boter = { type = 'boolean', required = false },
        fangelseMinMonths = { type = 'integer', required = false, min = 0, max = 216 },
        fangelseMaxMonths = { type = 'integer', required = false, min = 0, max = 216 },
        forsok = { type = 'boolean', required = false },
        forberedelse = { type = 'boolean', required = false },
        preskriptionYears = { type = 'integer', required = false, min = 1, max = 100 },
    },

    AnmalanList = {
        status = { type = 'enum', required = false, values = { 'utkast', 'inlamnad', 'atersand', 'godkand' } },
        mine = { type = 'boolean', required = false },
        fuId = { type = 'integer', required = false, min = 1 },
        includeSupplements = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    AnmalanGet = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = false, min = 1 },
    },

    AnmalanReturn = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = false, min = 1 },
        note = { type = 'string', required = false, max = 2000 },
    },

    AnmalanCreate = {
        title = { type = 'string', required = true, min = 1, max = 191 },
        parentId = { type = 'integer', required = false, min = 1 },
        fuId = { type = 'integer', required = false, min = 1 },
        callId = { type = 'integer', required = false, min = 1 },
        handelseforlopp = { type = 'string', required = false, max = 60000 },
        occurredAt = { type = 'string', required = false, max = 32 },
        occurredPlace = { type = 'string', required = false, max = 191 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    AnmalanUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        title = { type = 'string', required = false, min = 1, max = 191 },
        handelseforlopp = { type = 'string', required = false, max = 60000 },
        occurredAt = { type = 'string', required = false, max = 32 },
        occurredPlace = { type = 'string', required = false, max = 191 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
        fuId = { type = 'integer', required = false, min = 1 },
    },

    AnmalanCharges = {
        id = { type = 'integer', required = true, min = 1 },
        brottIds = { type = 'string[]', required = true, maxItems = 25, maxLength = 20 },
        stages = { type = 'string[]', required = false, maxItems = 25, maxLength = 16 },
        personIds = { type = 'string[]', required = false, maxItems = 25, maxLength = 20 },
    },

    AnmalanPerson = {
        id = { type = 'integer', required = true, min = 1 },
        personId = { type = 'integer', required = true, min = 1 },
        roll = { type = 'enum', required = true, values = { 'misstankt', 'malsagande', 'vittne', 'anmalare', 'annan' } },
        note = { type = 'string', required = false, max = 255 },
    },

    FuList = {
        status = { type = 'enum', required = false, values = { 'inledd', 'slutdelgiven', 'redovisad', 'nedlagd' } },
        mine = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    FuGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    FuCreate = {
        title = { type = 'string', required = true, min = 1, max = 191 },
        fuLedare = { type = 'string', required = false, max = 32 },
        ledareKind = { type = 'enum', required = false, values = { 'polis', 'aklagare' } },
        intelCaseId = { type = 'integer', required = false, min = 1 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    FuAssign = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        fuLedare = { type = 'string', required = true, min = 1, max = 32 },
        ledareKind = { type = 'enum', required = true, values = { 'polis', 'aklagare' } },
    },

    FuDecision = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        reason = { type = 'string', required = false, max = 128 },
        note = { type = 'string', required = false, max = 2000 },
    },

    FrihetOpen = {
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    FrihetList = {
        status = { type = 'enum', required = false, values = { 'gripen', 'anhallen', 'framstalld', 'haktad', 'frigiven' } },
        personId = { type = 'integer', required = false, min = 1 },
        fuId = { type = 'integer', required = false, min = 1 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    FrihetGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    FrihetGripande = {
        personId = { type = 'integer', required = true, min = 1 },
        grund = { type = 'string', required = true, min = 1, max = 128 },
        plats = { type = 'string', required = false, max = 191 },
        fuId = { type = 'integer', required = false, min = 1 },
        anmalanId = { type = 'integer', required = false, min = 1 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    FrihetDecision = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        grund = { type = 'string', required = false, max = 128 },
    },

    FrihetCharges = {
        id = { type = 'integer', required = true, min = 1 },
        brottIds = { type = 'string[]', required = true, maxItems = 25, maxLength = 20 },
    },

    FrihetLog = {
        id = { type = 'integer', required = true, min = 1 },
        kind = { type = 'string', required = true, min = 1, max = 64 },
        note = { type = 'string', required = false, max = 500 },
    },

    TvangList = {
        kind = { type = 'enum', required = false, values = { 'husrannsakan_reell', 'husrannsakan_personell', 'kroppsvisitation', 'kroppsbesiktning', 'beslag' } },
        fuId = { type = 'integer', required = false, min = 1 },
        liveOnly = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    TvangGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    TvangDecide = {
        kind = { type = 'enum', required = true, values = { 'husrannsakan_reell', 'husrannsakan_personell', 'kroppsvisitation', 'kroppsbesiktning', 'beslag' } },
        targetKind = { type = 'enum', required = true, values = { 'person', 'vehicle', 'address' } },
        targetId = { type = 'integer', required = true, min = 1 },
        targetLabel = { type = 'string', required = false, max = 191 },
        fuId = { type = 'integer', required = false, min = 1 },
        grund = { type = 'string', required = true, min = 1, max = 128 },
        scope = { type = 'string', required = false, max = 500 },
        validSeconds = { type = 'integer', required = false, min = 3600, max = 2592000 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    TvangVerkstall = {
        id = { type = 'integer', required = true, min = 1 },
        note = { type = 'string', required = false, max = 500 },
    },

    TvangUpphav = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
    },

    EfterlysningList = {
        grund = { type = 'enum', required = false, values = { 'anhallen_i_franvaro', 'haktad_i_franvaro', 'delgivning', 'forsvunnen', 'oidentifierad', 'annan' } },
        includeCancelled = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    EfterlysningCreate = {
        personId = { type = 'integer', required = true, min = 1 },
        grund = { type = 'enum', required = true, values = { 'anhallen_i_franvaro', 'haktad_i_franvaro', 'delgivning', 'forsvunnen', 'oidentifierad', 'annan' } },
        frihetId = { type = 'integer', required = false, min = 1 },
        fuId = { type = 'integer', required = false, min = 1 },
        note = { type = 'string', required = false, max = 500 },
        priority = { type = 'integer', required = false, min = 1, max = 4 },
        expiresInSeconds = { type = 'integer', required = false, min = 3600, max = 31536000 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    EfterlysningCancel = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        grund = { type = 'string', required = false, max = 128 },
    },

    SpaningList = {
        targetKind = { type = 'enum', required = false, values = { 'person', 'vehicle', 'other' } },
        priority = { type = 'integer', required = false, min = 1, max = 4 },
        includeResolved = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    SpaningGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    SpaningCreate = {
        targetKind = { type = 'enum', required = true, values = { 'person', 'vehicle', 'other' } },
        targetId = { type = 'integer', required = false, min = 1 },
        description = { type = 'string', required = false, max = 500 },
        grund = { type = 'string', required = true, min = 1, max = 128 },
        priority = { type = 'integer', required = false, min = 1, max = 4 },
        beatId = { type = 'integer', required = false, min = 1 },
        areaNote = { type = 'string', required = false, max = 191 },
        fuId = { type = 'integer', required = false, min = 1 },
        anmalanId = { type = 'integer', required = false, min = 1 },
        validSeconds = { type = 'integer', required = false, min = 3600, max = 7776000 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    SpaningResolve = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        grund = { type = 'string', required = false, max = 128 },
    },

    HakList = {
        fuId = { type = 'integer', required = false, min = 1 },
        status = { type = 'enum', required = false, values = { 'begard', 'beviljad', 'avslagen', 'upphavd' } },
        liveOnly = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    HakGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    HakRequest = {
        fuId = { type = 'integer', required = true, min = 1 },
        targetKind = { type = 'enum', required = true, values = { 'person', 'phone', 'vehicle', 'location' } },
        targetId = { type = 'integer', required = false, min = 1 },
        targetLabel = { type = 'string', required = false, max = 191 },
        method = { type = 'enum', required = true, values = { 'hak', 'hra', 'sparsandare', 'kameraovervakning' } },
        grund = { type = 'string', required = true, min = 1, max = 128 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    HakGrant = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        courtRef = { type = 'string', required = false, max = 64 },
        validSeconds = { type = 'integer', required = false, min = 3600, max = 2592000 },
    },

    HakRefuse = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        grund = { type = 'string', required = true, min = 1, max = 128 },
    },

    HakUpphav = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        grund = { type = 'string', required = false, max = 128 },
    },

    HakInterceptAdd = {
        hakId = { type = 'integer', required = true, min = 1 },
        kind = { type = 'string', required = true, min = 1, max = 64 },
        summary = { type = 'string', required = false, max = 500 },
        mediaRef = { type = 'string', required = false, max = 191 },
    },

    HakSessionStart = {
        hakId = { type = 'integer', required = true, min = 1 },
    },

    HakSessionEnd = {
        id = { type = 'integer', required = true, min = 1 },
        minimizationNote = { type = 'string', required = false, max = 500 },
    },

    HakLog = {
        hakId = { type = 'integer', required = true, min = 1 },
    },

    CourtReferralList = {
        beslut = { type = 'enum', required = false, values = { 'atalad', 'ej_atal' } },
        awaitingDisposition = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    CourtReferralPending = {

    },

    CourtReferralGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    CourtReferralDecide = {
        fuId = { type = 'integer', required = true, min = 1 },
        beslut = { type = 'enum', required = true, values = { 'atalad', 'ej_atal' } },
        beslutGrund = { type = 'string', required = false, max = 128 },
        brottIds = { type = 'string[]', required = false, maxItems = 25, maxLength = 20 },
        stages = { type = 'string[]', required = false, maxItems = 25, maxLength = 16 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    CourtDispositionEnter = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        disposition = { type = 'enum', required = true, values = { 'guilty', 'not_guilty', 'dismissed', 'plea' } },
        sentenceMonths = { type = 'integer', required = false, min = 0, max = 216 },
        sentenceLivstid = { type = 'boolean', required = false },
        note = { type = 'string', required = false, max = 500 },
    },

    PersonnelRosterList = {
        active = { type = 'boolean', required = false },
        division = { type = 'string', required = false, max = 64 },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    PersonnelRosterGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    PersonnelRosterUpdate = {
        id = { type = 'integer', required = true, min = 1 },
        badgeNumber = { type = 'string', required = false, max = 16 },
        division = { type = 'string', required = false, max = 64 },
    },

    PersonnelShiftStart = {

    },

    PersonnelShiftEnd = {

    },

    PersonnelEquipmentAssign = {
        officerId = { type = 'integer', required = true, min = 1 },
        itemKey = { type = 'string', required = true, min = 1, max = 64 },
        firearmId = { type = 'integer', required = false, min = 1 },
        serial = { type = 'string', required = false, max = 64 },
    },

    PersonnelEquipmentReturn = {
        id = { type = 'integer', required = true, min = 1 },
        officerId = { type = 'integer', required = true, min = 1 },
    },

    PersonnelCertificationIssue = {
        officerId = { type = 'integer', required = true, min = 1 },
        certKey = { type = 'string', required = true, min = 1, max = 64 },
        expiresAt = { type = 'integer', required = false, min = 0 },
    },

    PersonnelCertificationRevoke = {
        id = { type = 'integer', required = true, min = 1 },
        officerId = { type = 'integer', required = true, min = 1 },
    },

    PersonnelDisciplineList = {
        officerId = { type = 'integer', required = true, min = 1 },
    },

    PersonnelDisciplineOpen = {
        officerId = { type = 'integer', required = true, min = 1 },
        category = { type = 'string', required = true, min = 1, max = 64 },
        summary = { type = 'string', required = true, min = 1, max = 2000 },
    },

    PersonnelDisciplineClose = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        outcomeKey = { type = 'string', required = true, min = 1, max = 64 },
    },

    BookingList = {
        open = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    BookingGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    BookingBook = {
        frihetId = { type = 'integer', required = true, min = 1 },
        cell = { type = 'string', required = false, max = 32 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    BookingPropertyAdd = {
        bookingId = { type = 'integer', required = true, min = 1 },
        itemLabel = { type = 'string', required = true, min = 1, max = 191 },
        quantity = { type = 'integer', required = false, min = 1 },
    },

    BookingPropertyRelease = {
        id = { type = 'integer', required = true, min = 1 },
        bookingId = { type = 'integer', required = true, min = 1 },
    },

    BookingRelease = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        releaseReasonKey = { type = 'string', required = true, min = 1, max = 64 },
    },

    ImpoundList = {
        held = { type = 'boolean', required = false },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    ImpoundGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    ImpoundCreate = {
        plate = { type = 'string', required = true, min = 1, max = 16 },
        model = { type = 'string', required = false, max = 191 },
        heldReasonKey = { type = 'enum', required = true, values = { 'investigative', 'evidence', 'abandoned', 'dui', 'unregistered', 'other' } },
        feePerDay = { type = 'integer', required = false, min = 0 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    ImpoundAuthorize = {
        id = { type = 'integer', required = true, min = 1 },
    },

    ImpoundRelease = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        feePaid = { type = 'boolean', required = true },
    },

    OrdningsbotTariffList = {

    },

    OrdningsbotList = {
        status = { type = 'enum', required = false, values = { 'issued', 'paid', 'contested', 'void' } },
        limit = { type = 'integer', required = false, min = 1, max = 200 },
    },

    OrdningsbotGet = {
        id = { type = 'integer', required = true, min = 1 },
    },

    OrdningsbotIssue = {
        tariffId = { type = 'integer', required = true, min = 1 },
        personId = { type = 'integer', required = false, min = 1 },
        vehicleId = { type = 'integer', required = false, min = 1 },
        classification = { type = 'enum', required = false, values = { 'open', 'internal', 'restricted', 'confidential', 'secret' } },
    },

    OrdningsbotVoid = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
        voidReasonKey = { type = 'string', required = true, min = 1, max = 64 },
    },

    OrdningsbotContest = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
    },

    OrdningsbotPay = {
        id = { type = 'integer', required = true, min = 1 },
        version = { type = 'integer', required = true, min = 1 },
    },
}
