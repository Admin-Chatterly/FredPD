/**
 * What the M2 records routes send back (spec 7.2–7.5).
 *
 * These mirror what `persons/repo.lua` and `registry/repo.lua` actually select,
 * column for column, and nothing more. Two columns are deliberately absent from
 * every shape below because the server never selects them: `fpd_persons.identifier`
 * (the ESX character key) and anything that would name a compartment. If a field
 * appears here that the server does not send, the interface is inventing it.
 *
 * The important shape in this file is `Restricted`. A row that reaches the NUI
 * is one of three things and the difference matters on screen:
 *
 *   1. **A record.** It has an `id` and its fields.
 *   2. **A stub** — `{ restricted: true, recordType, contact }`, built from
 *      nothing (`Access.stub`). No id, no name, no number, no classification.
 *      It is the "Restricted record — contact <unit>" of 4.5, and `contact` is
 *      a *key* the NUI renders as `access.unit.<contact>` (invariant 6).
 *   3. **Absent.** A record the reader may not even be told exists was removed
 *      on the server and left no gap. There is nothing here to model, which is
 *      the point: a shorter list is the access control working, not an error.
 */

/**
 * A timestamp as it arrives from the server.
 *
 * `string` when oxmysql hands the column over as text and `number` when it
 * hands over epoch milliseconds. Both happen depending on the driver's date
 * handling, and a screen that assumed one of the two would print `[object
 * Object]` on somebody's record. `formatMoment` and `formatDate` take either.
 */
export type Moment = string | number | null;

/**
 * A row the reader may know exists but may not read (4.5).
 *
 * It carries no id, and that absence is what tells the two apart everywhere in
 * this module: `isStub(row)` is `row.id === undefined`.
 */
export interface Restricted {
  restricted: true;
  /** `person`, `vehicle`, `firearm`, `vehicle_flag` — what is being withheld. */
  recordType: string;
  /** A locale key suffix, never a sentence: `access.unit.<contact>`. */
  contact: string;
}

/** Either the record or the stub that stands in for it. */
export type Maybe<T> = T | Restricted;

// ---------------------------------------------------------------- persons

/** One caution as a search result carries it: the kind and the expiry only. */
export interface CautionFlag {
  kind: string;
  expiresAt: Moment;
}

/**
 * A caution in full, as the person record carries it (7.3).
 *
 * `fieldKey` is present when the caution is gated on a `fields.<key>.view`
 * permission. A reader without that permission is not sent the caution at all —
 * not the caution with its detail blanked — so a row arriving here is one this
 * session is cleared for, whatever `fieldKey` says.
 */
export interface PersonCaution {
  id: number;
  personId: number;
  kind: string;
  detail: string | null;
  fieldKey: string | null;
  sourceCase: string | null;
  classification: string;
  expiresAt: Moment;
  createdBy: string | null;
  createdAt: Moment;
}

export interface PersonRecord {
  id: number;
  agencyId: string;
  personNumber: string;
  firstName: string | null;
  middleName: string | null;
  lastName: string | null;
  dateOfBirth: Moment;
  sex: string | null;
  phone: string | null;
  /**
   * Absent when the reader holds `fields.victim_address.view` and there is no
   * address on file, *and* absent when they do not hold it. The two are told
   * apart by `addressRestricted` below, never by this field being empty.
   */
  address: string | null;
  /**
   * True when the address was removed on the way out because this session is
   * not cleared for it (`redactAddress`, persons/routes.lua). It is a flag and
   * not a sentence: "no address on file" and "you may not see the address" are
   * different facts about a person and the screen has to say which.
   */
  addressRestricted?: boolean;
  deceasedAt: Moment;
  missingSince: Moment;
  classification: string;
  version: number;
  createdBy: string | null;
  createdAt: Moment;
  updatedBy: string | null;
  updatedAt: Moment;
}

/** A person as the search returns them: the record plus how it matched. */
export interface PersonResult extends PersonRecord {
  recordType: string;
  matchScore: number;
  /** The alias the term matched, when it was an alias rather than the name. */
  matchedAlias: string | null;
  /** Kind and expiry only. The detail of a caution never reaches a list. */
  cautions: CautionFlag[];
}

export interface PersonSearchResult {
  persons: Maybe<PersonResult>[];
  /**
   * True only when this reader is cleared for the rows being held back, and the
   * query reached them without a reason or a case number (7.2).
   *
   * It is a break-glass signal, not a count and never a disclosure: a reader
   * who is not cleared for those rows never sees this set, because for them the
   * rows were gone before the flag was computed. The screen draws it as an
   * offer to run the search again with a reason — never as "N records hidden".
   */
  restrictedWithheld: boolean;
}

export interface PersonAlias {
  id: number;
  alias: string;
  kind: string;
  source: string | null;
  createdBy: string | null;
  createdAt: Moment;
}

/** The physical description (7.3). One row or none. */
export interface PersonDescriptors {
  heightCm: number | null;
  weightKg: number | null;
  build: string | null;
  hairColour: string | null;
  hairStyle: string | null;
  eyeColour: string | null;
  complexion: string | null;
  glasses: boolean | null;
  notes: string | null;
  updatedBy: string | null;
  updatedAt: Moment;
}

/**
 * A photograph on the file.
 *
 * `mediaRef` is a store reference and not a URL: media is served through the
 * gateway behind a signed URL (invariant 9), and a client holding this cannot
 * fetch anything with it. The screen lists what is on file and does not render
 * the image, because there is no media route in `NUI_ROUTES` to render it from.
 */
export interface PersonPhoto {
  id: number;
  kind: string;
  mediaRef: string;
  bodyLocation: string | null;
  description: string | null;
  takenAt: Moment;
  sourceCase: string | null;
  classification: string;
  createdBy: string | null;
  createdAt: Moment;
}

/** "Fingerprints on file", "DNA on file" — never a biometric value (8.1). */
export interface PersonBiometric {
  kind: string;
  onFile: boolean;
  indexName: string | null;
  recordedOn: Moment;
  updatedAt: Moment;
}

/** A vehicle as the person record lists it: fewer columns than the register. */
export interface LinkedVehicle {
  id: number;
  agencyId: string;
  plate: string;
  model: string | null;
  colour: string | null;
  registrationStatus: string;
  insuranceStatus: string;
  classification: string;
  recordType: string;
}

export interface LinkedFirearm {
  id: number;
  agencyId: string;
  serial: string;
  make: string | null;
  model: string | null;
  type: string | null;
  calibre: string | null;
  status: string;
  classification: string;
  recordType: string;
}

/**
 * `person.get`, both ways it can answer.
 *
 * `restricted` is the stub answer: the reader may be told the record exists and
 * who to ring about it, and `person` is then the three-field stub rather than a
 * record with its contents removed.
 */
export interface PersonDetail {
  id: number;
  restricted?: boolean;
  person: PersonRecord | Restricted;
  aliases?: PersonAlias[];
  descriptors?: PersonDescriptors | null;
  photos?: PersonPhoto[];
  cautions?: PersonCaution[];
  biometrics?: PersonBiometric[];
  vehicles?: Maybe<LinkedVehicle>[];
  firearms?: Maybe<LinkedFirearm>[];
}

// --------------------------------------------------------------- vehicles

export interface VehicleFlag {
  id: number;
  agencyId: string;
  vehicleId: number;
  kind: string;
  detail: string | null;
  caseNumber: string | null;
  classification: string;
  expiresAt: Moment;
  createdBy: string | null;
  createdAt: Moment;
}

export interface VehicleRecord {
  id: number;
  agencyId: string;
  plate: string;
  vin: string;
  model: string | null;
  colour: string | null;
  colourSecondary: string | null;
  ownerPersonId: number | null;
  ownerIdentifier: string | null;
  registrationStatus: string;
  registrationExpires: Moment;
  insuranceStatus: string;
  insuranceExpires: Moment;
  classification: string;
  version: number;
  createdBy: string | null;
  createdAt: Moment;
  updatedBy: string | null;
  updatedAt: Moment;
}

/** A search row: the record, plus the hot file read off its live flags (7.2). */
export interface VehicleResult extends VehicleRecord {
  recordType: string;
  /** Flag kinds only, computed by the server. Keys, never sentences. */
  hits: string[];
  flags: Maybe<VehicleFlag>[];
}

export interface VehicleSearchResult {
  vehicles: Maybe<VehicleResult>[];
  /** How many rows carry a hit. The server counts; the screen does not. */
  hits: number;
}

/** One period a plate was held for (7.4). Append-only history. */
export interface PlatePeriod {
  id: number;
  plate: string;
  heldFrom: Moment;
  heldUntil: Moment;
  reason: string | null;
  createdBy: string | null;
  createdAt: Moment;
}

export interface VehicleDetail {
  id: number;
  vehicle: VehicleRecord;
  flags: Maybe<VehicleFlag>[];
  hits: string[];
  plates: PlatePeriod[];
}

// --------------------------------------------------------------- firearms

export interface FirearmRecord {
  id: number;
  agencyId: string;
  serial: string;
  make: string | null;
  model: string | null;
  type: string | null;
  calibre: string | null;
  status: string;
  ownerPersonId: number | null;
  ownerIdentifier: string | null;
  assignedOfficer: string | null;
  classification: string;
  version: number;
  createdBy: string | null;
  createdAt: Moment;
  updatedBy: string | null;
  updatedAt: Moment;
}

export interface FirearmResult extends FirearmRecord {
  recordType: string;
  /** A firearm's hot file is its own status, so this is computed from the row. */
  hits: string[];
}

export interface FirearmSearchResult {
  firearms: Maybe<FirearmResult>[];
  hits: number;
}

/** One event in the life of a weapon (7.5). The history a trace reconstructs. */
export interface FirearmEvent {
  id: number;
  event: string;
  occurredAt: Moment;
  fromPersonId: number | null;
  toPersonId: number | null;
  fromParty: string | null;
  toParty: string | null;
  caseNumber: string | null;
  reason: string | null;
  recordedBy: string | null;
}

export interface FirearmDetail {
  id: number;
  firearm: FirearmRecord;
  hits: string[];
  events: FirearmEvent[];
}

/** `firearm.trace` — the same events read as a report, behind its own permission. */
export interface FirearmTrace {
  id: number;
  firearm: FirearmRecord;
  events: FirearmEvent[];
  /** The first link in the chain: where the weapon entered the register. */
  origin: FirearmEvent | null;
}

/**
 * True when a row came back as a stub rather than as a record.
 *
 * The test is the id, because that is the whole of a stub's design: it is built
 * fresh from nothing and carries no identifier to pair with anything else.
 */
export function isStub<T extends { id: number }>(row: Maybe<T>): row is Restricted {
  return (row as { id?: number }).id === undefined;
}
