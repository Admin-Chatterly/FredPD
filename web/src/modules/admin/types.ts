/**
 * What the two editors read (spec 4.3, 7.31).
 *
 * Both routes send more than the rows themselves: `admin.group.list` says
 * whether this session may edit each group, and `admin.permission.list` says
 * whether it could grant each key at all. Those are the server's answers, drawn
 * as they arrive — the refusal that counts is still the one on the write
 * (invariant 4).
 */

export interface GroupRow {
  key: string;
  name: string;
  inherits: string | null;
  description: string | null;
  createdAt: string;
  /** Groups inheriting from this one; deleting it is refused while any exist. */
  childCount: number;
  roleMapCount: number;
  agencyRoleMapCount: number;
  /** Granted by this group itself. */
  permissions: string[];
  /** Everything it grants once inheritance is expanded. */
  effective: string[];
  /** The administration group: it cannot be renamed, emptied or deleted. */
  locked: boolean;
  /** False when the session does not itself hold everything the group grants. */
  editable: boolean;
}

export interface PermissionRow {
  key: string;
  /** The first segment of the key, so the editor can section the list. */
  area: string;
  groupCount: number;
  /** Whether this session could put the key in a group at all. */
  grantable: boolean;
}

export interface FleetEntry {
  id: number;
  /** Spawn name. */
  model: string;
  /** A locale key, never a written-out vehicle name (invariant 6). */
  labelKey: string;
  permission: string | null;
  certification: string | null;
  livery: number | null;
  sortOrder: number;
  enabled: boolean;
  /** Either gate opens the vehicle; both null means everyone may draw it. */
  requiredGroup: string | null;
  requiredDiscordRole: string | null;
}
