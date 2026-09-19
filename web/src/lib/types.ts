/** Shapes the NUI receives from routes. Mirrors what the Lua handlers return. */

export interface Session {
  callsign: string | null;
  name: string;
  agencyId: string;
  agencyName: string;
  onDuty: boolean;
  modules: string[];
  permissionsStale: boolean;
}

export interface PermissionGroup {
  key: string;
  name: string;
  inherits: string | null;
  description: string | null;
}

export interface RoleMapping {
  id: number;
  discordRoleId: string;
  discordRoleName: string | null;
  groupKey: string;
  groupName: string;
  agencyId: string;
}

export interface RoleMapView {
  mappings: RoleMapping[];
  groups: PermissionGroup[];
  /** Null when Discord has never synced, which is different from "0 seconds ago". */
  snapshotAgeSeconds: number | null;
}

// ------------------------------------------------------------- intelligence

export interface IntelNote {
  id: number;
  personId: number | null;
  orgId: number | null;
  caseId: number | null;
  body: string;
  /** Absent when the reader is not cleared to see a protected source. */
  source: string | null;
  /** True when a source exists but is withheld (spec 10.6). */
  sourceProtected?: boolean;
  confidence: string;
  tags: string[];
  createdBy: string | null;
  createdAt: string;
  version: number;
}

export interface IntelTag {
  tag: string;
  uses: number;
}

export interface IntelPerson {
  id: number;
  /** Null for a person with neither a name nor an alias — the UI renders the key. */
  name: string | null;
  alias: string | null;
  description: string | null;
  status: string;
  noteCount?: number;
  lastNoteAt?: string | null;
  /** Comma-separated by the query, because MariaDB has no array type. */
  plates?: string | null;
  version: number;
}

export interface IntelOrg {
  id: number;
  name: string;
  type: string | null;
  territory: string | null;
  status: string;
  memberCount?: number;
  confirmedCount?: number;
  noteCount?: number;
  version: number;
}

export interface IntelCase {
  id: number;
  title: string;
  description: string | null;
  status: string;
  personCount?: number;
  orgCount?: number;
  noteCount?: number;
  version: number;
}

export interface IntelSearchResult {
  kind: string;
  id: number;
  title: string | null;
  subtitle: string | null;
  status: string | null;
}
