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
