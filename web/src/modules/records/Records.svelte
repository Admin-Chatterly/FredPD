<script module lang="ts">
  /**
   * The Records tab the officer was last on, kept while the MDT is open so
   * coming back to Records does not drop them on Query every time.
   */
  let rememberedTab: string | null = null;
</script>

<script lang="ts">
  import { nui } from '../../lib/nui';
  import Query from './Query.svelte';
  import Anmalan from './Anmalan.svelte';
  import Fu from './Fu.svelte';
  import Brott from './Brott.svelte';
  import Frihet from './Frihet.svelte';
  import Tvang from './Tvang.svelte';
  import Efterlysning from './Efterlysning.svelte';
  import Spaning from './Spaning.svelte';
  import Ordningsbot from './Ordningsbot.svelte';
  import Impound from './Impound.svelte';
  import Locations from './Locations.svelte';
  import { t } from '../../lib/i18n';
  import { formatDate, formatMoment } from '../../lib/time';
  import {
    CLASSIFICATIONS,
    FIREARM_STATUSES,
    FIREARM_TYPES,
    PERSON_CAUTION_KINDS,
    PERSON_SEXES,
    VEHICLE_FLAG_KINDS,
    VEHICLE_INSURANCE_STATUSES,
    VEHICLE_REGISTRATION_STATUSES,
  } from '@fredpd/schema';
  import { fieldList, type Failure } from '../shared/failure';
  import EntityPicker from '../shared/EntityPicker.svelte';
  import { onIntent, peekIntent, type Intent } from '../../lib/intent';
  import {
    isStub,
    type FirearmDetail,
    type FirearmResult,
    type FirearmSearchResult,
    type FirearmTrace,
    type Maybe,
    type Moment,
    type PersonDetail,
    type PersonRecord,
    type PersonResult,
    type PersonSearchResult,
    type Restricted,
    type VehicleDetail,
    type VehicleResult,
    type VehicleSearchResult,
  } from './types';
  import PersonPicker from '../shared/PersonPicker.svelte';

  /**
   * Records — the master name index and the two registers (spec 7.2–7.5).
   *
   * Three tabs over the three things M2's server answers: persons, vehicles and
   * firearms. One screen rather than three rail entries because the rail draws
   * the modules the *server* opened, and all three sit behind `page.records`.
   *
   * Four things the server does that this screen renders rather than second-guesses:
   *
   *   * **A record the reader may not know about is simply not sent.** A short
   *     list is the access control working (invariant 4), so there is no "no
   *     access" row for it and no count of what was dropped — a count would be
   *     the disclosure the filtering exists to prevent. A record the reader may
   *     be *told about* arrives as a stub and is drawn as one: "Restricted
   *     record — contact <unit>", which is all a stub carries.
   *   * **`restrictedWithheld` is a boolean.** True only when this reader is
   *     cleared for the rows being held back and the query reached them with no
   *     reason given. It is drawn as an offer to run the search again with a
   *     reason, never as "N records hidden" — the number is not sent and asking
   *     for it would be asking the server to disclose what it withheld.
   *   * **A query into restricted data needs a reason or a case number** (7.2).
   *     The registers refuse outright and the name index withholds, so the two
   *     boxes are part of the search form on every tab rather than something
   *     the officer discovers from a refusal they cannot act on.
   *   * **Field-level redaction is real.** An address may be absent from a
   *     record the officer can otherwise read. `addressRestricted` is what tells
   *     "withheld" from "nothing on file", and the two read differently here.
   *
   * Nothing on this screen is hidden by permission and no button is greyed out
   * by one. What a session may do is the server's answer, and a refusal is
   * drawn as a refusal (invariant 4, spec 6.4).
   */

  type Tab =
    | 'query'
    | 'persons'
    | 'vehicles'
    | 'firearms'
    | 'anmalan'
    | 'fu'
    | 'frihet'
    | 'brott'
    | 'tvang'
    | 'efterlysning'
    | 'spaning'
    | 'ordningsbot'
    | 'impound'
    | 'locations';

  /** Which form's label a rejected field belongs to (spec 3.5). */
  const FIELD_LABELS: Record<string, string> = {
    // `person.update` answers `nothing_to_change` against this pseudo-field
    // when the diff is empty. Without a label it would read as `_input`.
    _input: 'records.person.edit.title',
    term: 'records.search.term',
    dateOfBirth: 'records.person.field.dateOfBirth',
    reason: 'records.authority.reason',
    caseNumber: 'records.authority.caseNumber',
    limit: 'records.search.term',

    id: 'records.search.term',
    personId: 'records.person.column.number',
    cautionId: 'records.person.caution.title',
    kind: 'records.person.caution.kind',
    detail: 'records.person.caution.detail',
    sourceCase: 'records.person.caution.sourceCase',
    expiresInDays: 'records.person.caution.expires',

    firstName: 'records.person.field.firstName',
    middleName: 'records.person.field.middleName',
    lastName: 'records.person.field.lastName',
    sex: 'records.person.field.sex',
    phone: 'records.person.field.phone',
    address: 'records.person.field.address',
    classification: 'records.person.field.classification',

    plate: 'records.vehicle.field.plate',
    vin: 'records.vehicle.field.vin',
    model: 'records.vehicle.field.model',
    colour: 'records.vehicle.field.colour',
    colourSecondary: 'records.vehicle.field.colourSecondary',
    registrationStatus: 'records.vehicle.field.registration',
    registrationExpires: 'records.vehicle.field.registrationExpires',
    insuranceStatus: 'records.vehicle.field.insurance',
    insuranceExpires: 'records.vehicle.field.insuranceExpires',
    ownerIdentifier: 'records.field.ownerIdentifier',
    vehicleId: 'records.vehicle.column.plate',
    flagId: 'records.vehicle.flags',
    expiresIn: 'records.vehicle.flag.expiresIn',

    serial: 'records.firearm.field.serial',
    type: 'records.firearm.field.type',
    calibre: 'records.firearm.field.calibre',
    status: 'records.firearm.field.status',
    assignedOfficer: 'records.firearm.field.assignedOfficer',
    ownerParty: 'records.firearm.field.ownerParty',
    toPersonId: 'records.firearm.transfer.toPersonId',
    toIdentifier: 'records.firearm.transfer.toIdentifier',
    toParty: 'records.firearm.transfer.toParty',
    fromParty: 'records.firearm.transfer.fromParty',
  };

  let tab = $state<Tab>((rememberedTab as Tab | null) ?? 'query');

  $effect(() => {
    rememberedTab = tab;
  });
  let failure = $state<Failure | null>(null);
  let busy = $state(false);

  /**
   * The reason a query is being run, and the case it belongs to (7.2).
   *
   * One pair for the whole screen, because it is one authority: an officer
   * running a name and then the plate that came back is working one case, and
   * retyping the case number per register is how a reason stops being given.
   * Whichever search runs next carries whatever is in these two boxes; the
   * server decides whether that was enough.
   */
  let authority = $state({ reason: '', caseNumber: '' });
  let reasonBox = $state<HTMLInputElement | null>(null);

  /** Moves the officer to the box the withheld notice is asking them to fill. */
  function askForReason(): void {
    reasonBox?.focus();
  }

  /** What a date box has to be bound to: `YYYY-MM-DD` or empty. */
  function dateInput(value: Moment): string {
    return formatDate(value);
  }

  /**
   * A person's name for a list.
   *
   * All three name columns are nullable, so a record with none is a real state
   * (an unidentified person on file) rather than a broken row, and it says so
   * rather than rendering an empty cell.
   */
  function personName(person: PersonRecord): string {
    const parts = [person.firstName, person.middleName].filter((part) => part) as string[];
    const surname = person.lastName ?? '';
    const given = parts.join(' ');

    if (surname && given) return `${surname}, ${given}`;
    if (surname) return surname;
    if (given) return given;

    return t('records.person.unnamed');
  }

  /** The contact unit a stub names, as a sentence the officer can act on. */
  function stubContact(row: Restricted): string {
    return t('records.restricted.contact', { unit: t(`access.unit.${row.contact}`) });
  }

  /** Runs a write, then refreshes whatever it could have changed. */
  async function submit(
    route: string,
    input: Record<string, unknown>,
    after: () => Promise<void>,
  ): Promise<boolean> {
    if (busy) return false;
    busy = true;

    const response = await nui.call(route, input);

    if (response.ok) {
      failure = null;
      await after();
    } else {
      failure = response;
    }

    busy = false;
    return response.ok;
  }

  // ------------------------------------------------------------- persons

  interface PersonForm {
    firstName: string;
    middleName: string;
    lastName: string;
    dateOfBirth: string;
    sex: string;
    phone: string;
    address: string;
    classification: string;
    deceased: boolean;
    missing: boolean;
  }

  /** The text fields of the person editor, in the order the form draws them. */
  const PERSON_TEXT = [
    'firstName',
    'middleName',
    'lastName',
    'dateOfBirth',
    'sex',
    'phone',
    'address',
    'classification',
  ] as const;

  const EMPTY_PERSON: PersonForm = {
    firstName: '',
    middleName: '',
    lastName: '',
    dateOfBirth: '',
    sex: '',
    phone: '',
    address: '',
    classification: '',
    deceased: false,
    missing: false,
  };

  let personQuery = $state({ term: '', dateOfBirth: '' });
  let personApplied = $state<{
    term: string;
    dateOfBirth: string;
    reason: string;
    caseNumber: string;
  } | null>(null);

  let personRows = $state<Maybe<PersonResult>[]>([]);
  let personWithheld = $state(false);
  let personLoading = $state(false);

  let selectedPersonId = $state<number | null>(null);
  let personDetail = $state<PersonDetail | null>(null);
  let personForm = $state<PersonForm>({ ...EMPTY_PERSON });
  let personBase = $state<PersonForm>({ ...EMPTY_PERSON });

  let cautionKind = $state<string>(PERSON_CAUTION_KINDS[0]);
  let cautionDetail = $state('');
  let cautionCase = $state('');
  let cautionClassification = $state('');
  let cautionDays = $state('');

  function runPersonSearch(event: SubmitEvent): void {
    event.preventDefault();
    personApplied = { ...personQuery, ...authority };
  }

  // ------------------------------------------------------ creating a person

  interface EsxCharacterOption {
    identifier: string;
    firstName: string | null;
    lastName: string | null;
    dateOfBirth: string | null;
    phone: string | null;
  }

  /**
   * "Citizens fetched from the character database", in practice: the master
   * index had a working `Repo.createPerson` since 7.3 was written and no
   * route that ever called it, because identity was meant to come from
   * whichever path first meets a person rather than from typing a new file
   * into existence by hand. Picking a real ESX character here is that path.
   */
  async function searchEsxCharacters(term: string): Promise<EsxCharacterOption[]> {
    const response = await nui.call<{ characters: EsxCharacterOption[] }>('esx.character.search', {
      term,
      limit: 8,
    });

    return response.ok ? response.data.characters : [];
  }

  let createPersonOpen = $state(false);
  let createPersonForm = $state({
    identifier: '',
    firstName: '',
    middleName: '',
    lastName: '',
    dateOfBirth: '',
    sex: '',
    phone: '',
    address: '',
    classification: '',
  });

  function applyEsxCharacter(character: EsxCharacterOption): void {
    createPersonForm.identifier = character.identifier;
    if (character.firstName) createPersonForm.firstName = character.firstName;
    if (character.lastName) createPersonForm.lastName = character.lastName;
    if (character.dateOfBirth) createPersonForm.dateOfBirth = character.dateOfBirth;
    if (character.phone) createPersonForm.phone = character.phone;
  }

  async function createPerson(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    busy = true;

    const response = await nui.call<{ id: number }>('person.create', {
      identifier: createPersonForm.identifier || undefined,
      firstName: createPersonForm.firstName.trim() || undefined,
      middleName: createPersonForm.middleName.trim() || undefined,
      lastName: createPersonForm.lastName.trim() || undefined,
      dateOfBirth: createPersonForm.dateOfBirth || undefined,
      sex: createPersonForm.sex || undefined,
      phone: createPersonForm.phone.trim() || undefined,
      address: createPersonForm.address.trim() || undefined,
      classification: createPersonForm.classification || undefined,
    });

    if (response.ok) {
      failure = null;
      createPersonForm = {
        identifier: '',
        firstName: '',
        middleName: '',
        lastName: '',
        dateOfBirth: '',
        sex: '',
        phone: '',
        address: '',
        classification: '',
      };
      createPersonOpen = false;
      selectedPersonId = response.data.id;
    } else {
      failure = response;
    }

    busy = false;
  }

  async function loadPersons(applied: NonNullable<typeof personApplied>): Promise<void> {
    personLoading = true;

    const response = await nui.call<PersonSearchResult>('person.search', {
      term: applied.term.trim(),
      dateOfBirth: applied.dateOfBirth.trim() || undefined,
      reason: applied.reason.trim() || undefined,
      caseNumber: applied.caseNumber.trim() || undefined,
    });

    if (response.ok) {
      personRows = response.data.persons;
      personWithheld = response.data.restrictedWithheld;
      failure = null;
    } else {
      personRows = [];
      personWithheld = false;
      failure = response;
    }

    personLoading = false;
  }

  $effect(() => {
    const applied = personApplied;
    if (applied === null) return;

    void loadPersons(applied);
  });

  /**
   * The record, and the editor seeded from it.
   *
   * `personBase` is what arrived and `personForm` is what the officer has
   * typed; the save sends the difference. That is what makes "clear this field"
   * expressible — an empty string travels and the repo writes NULL — while an
   * untouched field is not sent at all, so a save that changes nothing is
   * refused as `nothing_to_change` rather than bumping the version for nobody.
   */
  async function loadPerson(id: number): Promise<void> {
    const response = await nui.call<PersonDetail>('person.get', { id });

    if (!response.ok) {
      personDetail = null;
      failure = response;
      return;
    }

    failure = null;
    personDetail = response.data;

    const record = response.data.person;

    if (response.data.restricted || isStub(record as Maybe<PersonRecord>)) {
      personForm = { ...EMPTY_PERSON };
      personBase = { ...EMPTY_PERSON };
      return;
    }

    const person = record as PersonRecord;
    const seeded: PersonForm = {
      firstName: person.firstName ?? '',
      middleName: person.middleName ?? '',
      lastName: person.lastName ?? '',
      dateOfBirth: dateInput(person.dateOfBirth),
      sex: person.sex ?? '',
      phone: person.phone ?? '',
      address: person.address ?? '',
      classification: person.classification,
      // `!= null`, not `!== null`: a person who is alive has no `deceased_at`,
      // so the key is absent from the row and arrives as `undefined`. Under
      // the strict comparison this was true for everybody.
      deceased: person.deceasedAt != null,
      missing: person.missingSince != null,
    };

    personForm = { ...seeded };
    personBase = { ...seeded };
  }

  $effect(() => {
    const id = selectedPersonId;
    if (id === null) return;

    void loadPerson(id);
  });

  const openPerson = $derived(
    personDetail && !personDetail.restricted && !isStub(personDetail.person as Maybe<PersonRecord>)
      ? (personDetail.person as PersonRecord)
      : null,
  );

  async function savePerson(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const person = openPerson;
    if (!person) return;

    const payload: Record<string, unknown> = { id: person.id, version: person.version };

    for (const key of PERSON_TEXT) {
      if (personForm[key] === personBase[key]) continue;

      // `sex` and `classification` are enums and have no empty member: a
      // cleared select means "leave it alone", not a value to send, because ''
      // would come back as a field error the officer cannot act on.
      if ((key === 'sex' || key === 'classification') && personForm[key] === '') continue;

      payload[key] = personForm[key];
    }

    if (personForm.deceased !== personBase.deceased) payload['deceased'] = personForm.deceased;
    if (personForm.missing !== personBase.missing) payload['missing'] = personForm.missing;

    await submit('person.update', payload, () => loadPerson(person.id));
  }

  async function addCaution(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const person = openPerson;
    if (!person) return;

    const days = Number.parseInt(cautionDays, 10);

    const done = await submit(
      'person.caution.set',
      {
        personId: person.id,
        kind: cautionKind,
        detail: cautionDetail.trim() || undefined,
        sourceCase: cautionCase.trim() || undefined,
        classification: cautionClassification || undefined,
        expiresInDays: Number.isFinite(days) ? days : undefined,
      },
      () => loadPerson(person.id),
    );

    if (done) {
      cautionDetail = '';
      cautionCase = '';
      cautionDays = '';
    }
  }

  async function withdrawCaution(cautionId: number): Promise<void> {
    const person = openPerson;
    if (!person) return;

    await submit('person.caution.set', { cancel: true, cautionId }, () => loadPerson(person.id));
  }

  // ------------------------------------------------------------ vehicles

  /** A plate read, as far as this screen needs it (mirrors `Alpr.svelte`'s own). */
  interface VehicleAlprRead {
    id: number;
    readAt: string;
    camera: string;
    hit: boolean;
    x: number;
    y: number;
  }

  interface VehicleForm {
    model: string;
    colour: string;
    colourSecondary: string;
    ownerIdentifier: string;
    registrationStatus: string;
    registrationExpires: string;
    insuranceStatus: string;
    insuranceExpires: string;
    classification: string;
  }

  const VEHICLE_FIELDS = [
    'model',
    'colour',
    'colourSecondary',
    'ownerIdentifier',
    'registrationStatus',
    'registrationExpires',
    'insuranceStatus',
    'insuranceExpires',
    'classification',
  ] as const;

  /** The three enum fields, which have no empty member to clear them with. */
  const VEHICLE_ENUMS = new Set(['registrationStatus', 'insuranceStatus', 'classification']);

  const EMPTY_VEHICLE: VehicleForm = {
    model: '',
    colour: '',
    colourSecondary: '',
    ownerIdentifier: '',
    registrationStatus: '',
    registrationExpires: '',
    insuranceStatus: '',
    insuranceExpires: '',
    classification: '',
  };

  let vehicleQuery = $state({ term: '' });
  let vehicleApplied = $state<{ term: string; reason: string; caseNumber: string } | null>(null);

  let vehicleRows = $state<Maybe<VehicleResult>[]>([]);
  let vehicleHitCount = $state(0);
  let vehicleLoading = $state(false);

  let selectedVehicleId = $state<number | null>(null);
  let vehicleDetail = $state<VehicleDetail | null>(null);
  let vehicleAlprReads = $state<VehicleAlprRead[]>([]);
  let vehicleForm = $state<VehicleForm>({ ...EMPTY_VEHICLE });
  let vehicleBase = $state<VehicleForm>({ ...EMPTY_VEHICLE });

  /**
   * Which hot-file banner the officer has read (7.2, spec 6.4).
   *
   * A confirmed hit is not recorded anywhere: there is no hit-confirmation
   * route, so this is an acknowledgement on this screen and says so. It exists
   * so the banner is something the officer has to act on rather than something
   * they scroll past, which is the whole point of hit confirmation.
   */
  let confirmedVehicleHit = $state<number | null>(null);
  let confirmedFirearmHit = $state<number | null>(null);

  let newPlate = $state('');
  let plateReason = $state('');

  let flagKind = $state<string>(VEHICLE_FLAG_KINDS[0]);
  let flagDetail = $state('');
  let flagCase = $state('');
  let flagClassification = $state('');
  let flagExpiresIn = $state('');

  let registerVehicleForm = $state({
    plate: '',
    model: '',
    colour: '',
    colourSecondary: '',
    ownerIdentifier: '',
    registrationStatus: '',
    insuranceStatus: '',
    registrationExpires: '',
    insuranceExpires: '',
    classification: '',
    reason: '',
  });

  interface OwnedVehicleOption {
    plate: string;
    owner: string | null;
    model: string | null;
  }

  /**
   * Suggests a vehicle ESX already knows about while an officer is filling in
   * a registration -- "fetched from the vehicle's own database" in practice:
   * the plate and the owner's ESX identifier come from `owned_vehicles`
   * itself rather than being retyped from memory.
   *
   * `model` is drawn exactly as ESX stored it, which on most servers is a
   * hash number rather than a name (`Framework.searchOwnedVehicles` explains
   * why FredPD does not try to resolve it) -- shown anyway, because a hash an
   * officer recognises from the vehicle they are looking at is still useful,
   * and a blank field would hide that this suggestion came from a real row.
   */
  async function searchOwnedVehicles(term: string): Promise<OwnedVehicleOption[]> {
    const response = await nui.call<{ vehicles: OwnedVehicleOption[] }>('esx.vehicle.search', {
      term,
      limit: 8,
    });

    return response.ok ? response.data.vehicles : [];
  }

  function applyOwnedVehicle(vehicle: OwnedVehicleOption): void {
    registerVehicleForm.plate = vehicle.plate;
    if (vehicle.owner) registerVehicleForm.ownerIdentifier = vehicle.owner;
    if (vehicle.model) registerVehicleForm.model = vehicle.model;
  }

  function runVehicleSearch(event: SubmitEvent): void {
    event.preventDefault();
    vehicleApplied = { ...vehicleQuery, ...authority };
  }

  async function loadVehicles(applied: NonNullable<typeof vehicleApplied>): Promise<void> {
    vehicleLoading = true;

    const response = await nui.call<VehicleSearchResult>('vehicle.search', {
      term: applied.term.trim() || undefined,
      reason: applied.reason.trim() || undefined,
      caseNumber: applied.caseNumber.trim() || undefined,
    });

    if (response.ok) {
      vehicleRows = response.data.vehicles;
      vehicleHitCount = response.data.hits;
      failure = null;
    } else {
      vehicleRows = [];
      vehicleHitCount = 0;
      failure = response;
    }

    vehicleLoading = false;
  }

  $effect(() => {
    const applied = vehicleApplied;
    if (applied === null) return;

    void loadVehicles(applied);
  });

  async function loadVehicle(id: number): Promise<void> {
    // By id, never by plate: the query that found the record was logged when it
    // was run, and logging the click as well would fill the officer's own query
    // history with searches they never made (7.2).
    const response = await nui.call<VehicleDetail>('vehicle.get', { id });

    if (!response.ok) {
      vehicleDetail = null;
      failure = response;
      return;
    }

    failure = null;
    vehicleDetail = response.data;
    confirmedVehicleHit = null;

    // Best-effort, the same way the FU screen's linked evidence is: a reader
    // who may open the vehicle but not `alpr.read.view` simply sees no recent
    // reads, rather than the whole record failing to open over it.
    const readsResponse = await nui.call<{ reads: VehicleAlprRead[] }>('alpr.read.list', {
      plate: response.data.vehicle.plate,
      limit: 5,
    });
    vehicleAlprReads = readsResponse.ok ? readsResponse.data.reads : [];

    const vehicle = response.data.vehicle;
    const seeded: VehicleForm = {
      model: vehicle.model ?? '',
      colour: vehicle.colour ?? '',
      colourSecondary: vehicle.colourSecondary ?? '',
      ownerIdentifier: vehicle.ownerIdentifier ?? '',
      registrationStatus: vehicle.registrationStatus,
      registrationExpires: dateInput(vehicle.registrationExpires),
      insuranceStatus: vehicle.insuranceStatus,
      insuranceExpires: dateInput(vehicle.insuranceExpires),
      classification: vehicle.classification,
    };

    vehicleForm = { ...seeded };
    vehicleBase = { ...seeded };
  }

  $effect(() => {
    const id = selectedVehicleId;
    if (id === null) return;

    void loadVehicle(id);
  });

  async function saveVehicle(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const vehicle = vehicleDetail?.vehicle;
    if (!vehicle) return;

    const payload: Record<string, unknown> = { id: vehicle.id, version: vehicle.version };

    for (const key of VEHICLE_FIELDS) {
      if (vehicleForm[key] === vehicleBase[key]) continue;
      if (VEHICLE_ENUMS.has(key) && vehicleForm[key] === '') continue;

      payload[key] = vehicleForm[key];
    }

    await submit('vehicle.update', payload, () => loadVehicle(vehicle.id));
  }

  async function changePlate(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const vehicle = vehicleDetail?.vehicle;
    if (!vehicle) return;

    const done = await submit(
      'vehicle.plate.change',
      {
        id: vehicle.id,
        version: vehicle.version,
        plate: newPlate.trim(),
        reason: plateReason.trim() || undefined,
      },
      () => loadVehicle(vehicle.id),
    );

    if (done) {
      newPlate = '';
      plateReason = '';
    }
  }

  async function addFlag(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const vehicle = vehicleDetail?.vehicle;
    if (!vehicle) return;

    const seconds = Number.parseInt(flagExpiresIn, 10);

    const done = await submit(
      'vehicle.flag',
      {
        vehicleId: vehicle.id,
        kind: flagKind,
        detail: flagDetail.trim() || undefined,
        caseNumber: flagCase.trim() || undefined,
        classification: flagClassification || undefined,
        expiresIn: Number.isFinite(seconds) ? seconds : undefined,
      },
      () => loadVehicle(vehicle.id),
    );

    if (done) {
      flagDetail = '';
      flagCase = '';
      flagExpiresIn = '';
    }
  }

  async function clearFlag(flagId: number): Promise<void> {
    const vehicle = vehicleDetail?.vehicle;
    if (!vehicle) return;

    await submit('vehicle.flag.clear', { flagId }, () => loadVehicle(vehicle.id));
  }

  async function registerVehicle(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const form = registerVehicleForm;

    // The VIN is absent on purpose: the register generates it once and a client
    // that could name one could give a stolen car a clean identity (invariant 1).
    const response = await nui.call<{ id: number }>('vehicle.register', {
      plate: form.plate.trim(),
      model: form.model.trim() || undefined,
      colour: form.colour.trim() || undefined,
      colourSecondary: form.colourSecondary.trim() || undefined,
      ownerIdentifier: form.ownerIdentifier.trim() || undefined,
      registrationStatus: form.registrationStatus || undefined,
      insuranceStatus: form.insuranceStatus || undefined,
      registrationExpires: form.registrationExpires.trim() || undefined,
      insuranceExpires: form.insuranceExpires.trim() || undefined,
      classification: form.classification || undefined,
      reason: form.reason.trim() || undefined,
    });

    if (!response.ok) {
      failure = response;
      return;
    }

    failure = null;
    registerVehicleForm = {
      plate: '',
      model: '',
      colour: '',
      colourSecondary: '',
      ownerIdentifier: '',
      registrationStatus: '',
      insuranceStatus: '',
      registrationExpires: '',
      insuranceExpires: '',
      classification: '',
      reason: '',
    };

    selectedVehicleId = response.data.id;
  }

  // ------------------------------------------------------------ firearms

  interface FirearmForm {
    make: string;
    model: string;
    type: string;
    calibre: string;
    classification: string;
  }

  const FIREARM_FIELDS = ['make', 'model', 'type', 'calibre', 'classification'] as const;
  const FIREARM_ENUMS = new Set(['type', 'classification']);

  const EMPTY_FIREARM: FirearmForm = {
    make: '',
    model: '',
    type: '',
    calibre: '',
    classification: '',
  };

  let firearmQuery = $state({ term: '', status: '', assignedOfficer: '' });
  let firearmApplied = $state<{
    term: string;
    status: string;
    assignedOfficer: string;
    reason: string;
    caseNumber: string;
  } | null>(null);

  let firearmRows = $state<Maybe<FirearmResult>[]>([]);
  let firearmHitCount = $state(0);
  let firearmLoading = $state(false);

  let selectedFirearmId = $state<number | null>(null);
  let firearmDetail = $state<FirearmDetail | null>(null);
  let firearmForm = $state<FirearmForm>({ ...EMPTY_FIREARM });
  let firearmBase = $state<FirearmForm>({ ...EMPTY_FIREARM });
  let trace = $state<FirearmTrace | null>(null);

  let transferPersonId = $state('');
  let transferIdentifier = $state('');
  let transferToParty = $state('');
  let transferFromParty = $state('');
  let transferCase = $state('');
  let transferReason = $state('');

  let statusValue = $state<string>(FIREARM_STATUSES[0]);
  let statusCase = $state('');
  let statusReason = $state('');

  let assignOfficer = $state('');
  let assignCase = $state('');
  let assignReason = $state('');

  let registerFirearmForm = $state({
    serial: '',
    make: '',
    model: '',
    type: '',
    calibre: '',
    status: '',
    ownerIdentifier: '',
    ownerParty: '',
    assignedOfficer: '',
    classification: '',
    caseNumber: '',
    reason: '',
  });

  function runFirearmSearch(event: SubmitEvent): void {
    event.preventDefault();
    firearmApplied = { ...firearmQuery, ...authority };
  }

  async function loadFirearms(applied: NonNullable<typeof firearmApplied>): Promise<void> {
    firearmLoading = true;

    const response = await nui.call<FirearmSearchResult>('firearm.search', {
      term: applied.term.trim() || undefined,
      status: applied.status || undefined,
      assignedOfficer: applied.assignedOfficer.trim() || undefined,
      reason: applied.reason.trim() || undefined,
      caseNumber: applied.caseNumber.trim() || undefined,
    });

    if (response.ok) {
      firearmRows = response.data.firearms;
      firearmHitCount = response.data.hits;
      failure = null;
    } else {
      firearmRows = [];
      firearmHitCount = 0;
      failure = response;
    }

    firearmLoading = false;
  }

  $effect(() => {
    const applied = firearmApplied;
    if (applied === null) return;

    void loadFirearms(applied);
  });

  async function loadFirearm(id: number): Promise<void> {
    const response = await nui.call<FirearmDetail>('firearm.get', { id });

    if (!response.ok) {
      firearmDetail = null;
      failure = response;
      return;
    }

    failure = null;
    firearmDetail = response.data;
    confirmedFirearmHit = null;
    trace = null;

    const firearm = response.data.firearm;
    const seeded: FirearmForm = {
      make: firearm.make ?? '',
      model: firearm.model ?? '',
      type: firearm.type ?? '',
      calibre: firearm.calibre ?? '',
      classification: firearm.classification,
    };

    firearmForm = { ...seeded };
    firearmBase = { ...seeded };
    statusValue = firearm.status;
    assignOfficer = firearm.assignedOfficer ?? '';
  }

  $effect(() => {
    const id = selectedFirearmId;
    if (id === null) return;

    void loadFirearm(id);
  });

  async function saveFirearm(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const firearm = firearmDetail?.firearm;
    if (!firearm) return;

    const payload: Record<string, unknown> = { id: firearm.id, version: firearm.version };

    for (const key of FIREARM_FIELDS) {
      if (firearmForm[key] === firearmBase[key]) continue;
      if (FIREARM_ENUMS.has(key) && firearmForm[key] === '') continue;

      payload[key] = firearmForm[key];
    }

    await submit('firearm.update', payload, () => loadFirearm(firearm.id));
  }

  async function transferFirearm(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const firearm = firearmDetail?.firearm;
    if (!firearm) return;

    const personId = Number.parseInt(transferPersonId, 10);

    const done = await submit(
      'firearm.transfer',
      {
        id: firearm.id,
        version: firearm.version,
        toPersonId: Number.isFinite(personId) ? personId : undefined,
        toIdentifier: transferIdentifier.trim() || undefined,
        toParty: transferToParty.trim() || undefined,
        fromParty: transferFromParty.trim() || undefined,
        caseNumber: transferCase.trim() || undefined,
        reason: transferReason.trim() || undefined,
      },
      () => loadFirearm(firearm.id),
    );

    if (done) {
      transferPersonId = '';
      transferIdentifier = '';
      transferToParty = '';
      transferFromParty = '';
      transferCase = '';
      transferReason = '';
    }
  }

  async function setFirearmStatus(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const firearm = firearmDetail?.firearm;
    if (!firearm) return;

    const done = await submit(
      'firearm.status',
      {
        id: firearm.id,
        version: firearm.version,
        status: statusValue,
        caseNumber: statusCase.trim() || undefined,
        reason: statusReason.trim() || undefined,
      },
      () => loadFirearm(firearm.id),
    );

    if (done) {
      statusCase = '';
      statusReason = '';
    }
  }

  async function assignFirearm(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const firearm = firearmDetail?.firearm;
    if (!firearm) return;

    // Blank is the return to the armoury, so it travels as an empty string
    // rather than being dropped: the server's `blankToNull` is what turns it
    // into "nobody", and omitting the field would mean "leave it alone".
    const done = await submit(
      'firearm.assign',
      {
        id: firearm.id,
        version: firearm.version,
        assignedOfficer: assignOfficer.trim(),
        caseNumber: assignCase.trim() || undefined,
        reason: assignReason.trim() || undefined,
      },
      () => loadFirearm(firearm.id),
    );

    if (done) {
      assignCase = '';
      assignReason = '';
    }
  }

  /**
   * The trace report (7.5) — the ownership chain back to the first purchaser.
   *
   * A separate call because it is a separate permission: `rms.firearm.trace` on
   * top of the clearance that opened the record. A session without it is
   * refused, and the refusal is what says so.
   */
  async function runTrace(): Promise<void> {
    const firearm = firearmDetail?.firearm;
    if (!firearm || busy) return;

    busy = true;
    const response = await nui.call<FirearmTrace>('firearm.trace', { id: firearm.id });

    if (response.ok) {
      trace = response.data;
      failure = null;
    } else {
      trace = null;
      failure = response;
    }

    busy = false;
  }

  async function registerFirearm(event: SubmitEvent): Promise<void> {
    event.preventDefault();

    const form = registerFirearmForm;

    const response = await nui.call<{ id: number }>('firearm.register', {
      serial: form.serial.trim(),
      make: form.make.trim() || undefined,
      model: form.model.trim() || undefined,
      type: form.type || undefined,
      calibre: form.calibre.trim() || undefined,
      status: form.status || undefined,
      ownerIdentifier: form.ownerIdentifier.trim() || undefined,
      ownerParty: form.ownerParty.trim() || undefined,
      assignedOfficer: form.assignedOfficer.trim() || undefined,
      classification: form.classification || undefined,
      caseNumber: form.caseNumber.trim() || undefined,
      reason: form.reason.trim() || undefined,
    });

    if (!response.ok) {
      failure = response;
      return;
    }

    failure = null;
    registerFirearmForm = {
      serial: '',
      make: '',
      model: '',
      type: '',
      calibre: '',
      status: '',
      ownerIdentifier: '',
      ownerParty: '',
      assignedOfficer: '',
      classification: '',
      caseNumber: '',
      reason: '',
    };

    selectedFirearmId = response.data.id;
  }

  /** Opens a vehicle or firearm named on a person's record, on its own tab. */
  function openVehicle(id: number): void {
    tab = 'vehicles';
    selectedVehicleId = id;
  }

  function openFirearm(id: number): void {
    tab = 'firearms';
    selectedFirearmId = id;
  }

  const tabs: Tab[] = [
    // First, because it is what an officer reaches for: one box for a name, a
    // plate or a serial. The three register tabs behind it are for working a
    // record once it has been found.
    'query',
    'persons',
    'vehicles',
    'firearms',
    'anmalan',
    'fu',
    'frihet',
    'tvang',
    'efterlysning',
    'spaning',
    'brott',
    'ordningsbot',
    'impound',
    // The address index and its hazards (7.6).
    'locations',
  ];

  /**
   * A field action's "Open in MDT" (lib/intent.ts): switch to the tab it
   * names. Peeked, not taken -- the tab's own screen (Query) takes the rest.
   */
  function followIntent(intent: Intent | null): void {
    if (!intent || intent.module !== 'records' || !intent.tab) return;
    if ((tabs as string[]).includes(intent.tab)) tab = intent.tab as Tab;
  }

  followIntent(peekIntent());
  $effect(() => onIntent(followIntent));

  /**
   * The tabs whose searches go into the name index and the registers (7.2).
   *
   * Only these take a reason and a case number, and only here is the authority
   * fieldset drawn. The workflow tabs below read records the officer is
   * already working on, through routes that take neither field.
   */
  const REGISTER_TABS = new Set<Tab>(['persons', 'vehicles', 'firearms']);
  const messages = $derived(fieldList(failure, FIELD_LABELS));

  const openVehicleRecord = $derived(vehicleDetail?.vehicle ?? null);
  const openFirearmRecord = $derived(firearmDetail?.firearm ?? null);

  /** The hot-file kinds on the open record, as the officer reads them. */
  function vehicleHitText(hits: string[]): string {
    return hits.map((kind) => t(`registry.flag.${kind}`)).join(' · ');
  }

  function firearmHitText(hits: string[]): string {
    return hits.map((status) => t(`registry.firearm.status.${status}`)).join(' · ');
  }

  function cautionText(kinds: string[]): string {
    return kinds.map((kind) => t(`records.cautionKind.${kind}`)).join(' · ');
  }
</script>

<section class="flex min-h-0 flex-col gap-4">
  <!--
    Wraps. Nine tabs of Swedish ("Frihetsberövanden", "Spaningsuppdrag") run
    past the workspace at 1280 px and at the 125% text scale 6.4 allows, and
    with `#app` now clipping rather than scrolling the page, a tab that runs
    off the edge is a tab that cannot be reached at all.
  -->
  <nav class="flex flex-wrap gap-1 border-b border-[var(--color-border)]">
    {#each tabs as name (name)}
      <button
        type="button"
        class="px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        class:font-semibold={tab === name}
        onclick={() => (tab = name)}
      >
        {t(`records.tab.${name}`)}
      </button>
    {/each}
  </nav>

  {#if failure}
    <div class="border border-[var(--color-border)] px-3 py-2 text-sm">
      <p>{t(`error.${failure.err}`)}</p>
      {#if messages.length > 0}
        <ul class="mt-1 text-xs text-[var(--color-ink-muted)]">
          {#each messages as message (message.name)}
            <li>{message.label} — {message.reason}</li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}

  <!--
    Query authority (7.2). Part of the form on the three *register* tabs,
    because a refusal the officer cannot act on is a dead end: the registers
    refuse a result that would open a restricted record without one of these
    two, and the name index withholds the rows until one is given.

    It is not drawn on the workflow tabs. `anmalan.list`, `frihet.open`,
    `tvang.list` and their siblings do not take `reason` or `caseNumber` —
    those routes are reads of a case the officer is already working, not
    queries into the name index — so the boxes there were a form that asked for
    something and then threw it away. An officer who typed a reason into them
    had every ground to believe the search had been logged with it.
  -->
  {#if REGISTER_TABS.has(tab)}
  <fieldset class="flex flex-wrap items-end gap-3 border border-[var(--color-border)] p-3">
    <legend class="px-1 text-xs font-semibold">{t('records.authority.title')}</legend>

    <p class="w-full text-xs text-[var(--color-ink-muted)]">{t('records.authority.intro')}</p>

    <label class="flex flex-col gap-1 text-xs">
      <span>{t('records.authority.reason')}</span>
      <input
        class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
        bind:this={reasonBox}
        bind:value={authority.reason}
        maxlength="255"
        placeholder={t('records.authority.reasonPlaceholder')}
      />
    </label>

    <label class="flex flex-col gap-1 text-xs">
      <span>{t('records.authority.caseNumber')}</span>
      <input
        class="w-48 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
        bind:value={authority.caseNumber}
        maxlength="32"
      />
    </label>
  </fieldset>
  {/if}

  {#if tab === 'query'}
    <!--
      The unified query (7.2). Its own component, and its own authority boxes:
      it carries the same reason and case number as the registers but runs a
      different route, and a refusal for want of one is drawn here as an offer
      to run the search again rather than as a dead end.
    -->
    <Query />
  {:else if tab === 'persons'}
    <!-- ------------------------------------------------------- persons -->
    <form class="flex flex-wrap items-end gap-3" onsubmit={runPersonSearch}>
      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.person.search.term')}</span>
        <input
          class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={personQuery.term}
          maxlength="191"
          placeholder={t('records.person.search.termPlaceholder')}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.person.field.dateOfBirth')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          type="date"
          bind:value={personQuery.dateOfBirth}
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
      >
        {t('records.search.run')}
      </button>
    </form>

    <!-- The break-glass offer (4.5, 7.2). A boolean, never a count: the number
         of rows held back is not sent, and printing one would disclose exactly
         what the reason requirement exists to make somebody answer for. -->
    {#if personWithheld}
      <div class="border border-[var(--color-border)] px-3 py-2">
        <p class="text-xs font-semibold">{t('records.withheld.title')}</p>
        <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('records.withheld.body')}</p>
        <button
          type="button"
          class="mt-2 border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
          onclick={askForReason}
        >
          {t('records.withheld.action')}
        </button>
      </div>
    {/if}

    {#if personLoading}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:else if personApplied !== null}
      <div class="overflow-x-auto border border-[var(--color-border)]">
        <table class="w-full border-collapse text-xs">
          <thead>
            <tr class="border-b border-[var(--color-border)] text-left">
              <th class="px-3 py-2 font-semibold">{t('records.person.column.number')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.person.column.name')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.person.field.dateOfBirth')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.person.field.sex')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.person.column.cautions')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.person.column.alias')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.person.field.phone')}</th>
            </tr>
          </thead>
          <tbody>
            {#each personRows as row, index (index)}
              {#if isStub(row)}
                <tr class="border-b border-[var(--color-border)] last:border-b-0">
                  <td class="px-3 py-2 text-[var(--color-ink-muted)]" colspan="7">
                    {t('records.restricted.title')} — {stubContact(row)}
                  </td>
                </tr>
              {:else}
                <tr class="border-b border-[var(--color-border)] last:border-b-0">
                  <td class="px-3 py-2">
                    <button
                      type="button"
                      class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                      class:font-semibold={selectedPersonId === row.id}
                      onclick={() => (selectedPersonId = row.id)}
                    >
                      {row.personNumber}
                    </button>
                  </td>
                  <td class="px-3 py-2">{personName(row)}</td>
                  <td class="px-3 py-2 font-[family-name:var(--font-mono)]">
                    {formatDate(row.dateOfBirth)}
                  </td>
                  <td class="px-3 py-2">{row.sex ? t(`records.sex.${row.sex}`) : ''}</td>
                  <td class="px-3 py-2">
                    {cautionText(row.cautions.map((caution) => caution.kind))}
                  </td>
                  <td class="px-3 py-2">{row.matchedAlias ?? ''}</td>
                  <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{row.phone ?? ''}</td>
                </tr>
              {/if}
            {:else}
              <tr>
                <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="7">
                  {t('records.person.empty')}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}

    {#if personDetail?.restricted}
      <!-- The stub in full (4.5): three fields, built from nothing. There is no
           record here to draw and nothing to reveal by drawing it. -->
      <article class="border border-[var(--color-border)] p-3">
        <h2 class="text-sm font-semibold">{t('records.restricted.title')}</h2>
        <p class="mt-1 text-xs text-[var(--color-ink-muted)]">
          {stubContact(personDetail.person as Restricted)}
        </p>
        <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('records.restricted.body')}</p>
      </article>
    {:else if openPerson && personDetail}
      <article class="flex flex-col gap-4 border border-[var(--color-border)] p-3">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="text-sm font-semibold">{personName(openPerson)}</h2>
          <span class="font-[family-name:var(--font-mono)] text-xs text-[var(--color-ink-muted)]">
            {openPerson.personNumber}
          </span>
        </header>

        <!-- Cautions, at the top, because that is what an officer opens a name
             for before they get out of the car (7.3). A caution the reader is
             not cleared for was never sent, so this is the whole list. -->
        {#if (personDetail.cautions ?? []).length > 0}
          <div class="border-2 border-[var(--color-ink)] px-3 py-2">
            <p class="text-xs font-semibold">{t('records.person.cautions')}</p>
            <ul class="mt-1 flex flex-col gap-0.5 text-xs">
              {#each personDetail.cautions ?? [] as caution (caution.id)}
                <li class="flex flex-wrap items-baseline gap-2">
                  <span class="font-semibold">{t(`records.cautionKind.${caution.kind}`)}</span>
                  {#if caution.detail}<span>{caution.detail}</span>{/if}
                  {#if caution.sourceCase}
                    <span class="font-[family-name:var(--font-mono)] text-[var(--color-ink-muted)]">
                      {caution.sourceCase}
                    </span>
                  {/if}
                  <span class="text-[var(--color-ink-muted)]">
                    {caution.expiresAt
                      ? t('records.person.caution.expiresAt', {
                          moment: formatMoment(caution.expiresAt),
                        })
                      : t('records.person.caution.noExpiry')}
                  </span>
                  <button
                    type="button"
                    class="border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)]"
                    disabled={busy}
                    onclick={() => withdrawCaution(caution.id)}
                  >
                    {t('records.person.caution.cancel')}
                  </button>
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-xs md:grid-cols-4">
          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.dateOfBirth')}</dt>
          <dd class="font-[family-name:var(--font-mono)]">{formatDate(openPerson.dateOfBirth)}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.sex')}</dt>
          <dd>{openPerson.sex ? t(`records.sex.${openPerson.sex}`) : ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.phone')}</dt>
          <dd class="font-[family-name:var(--font-mono)]">{openPerson.phone ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.classification')}</dt>
          <dd>{t(`records.classification.${openPerson.classification}`)}</dd>

          <!-- Three states, not two. An address that is present is shown; an
               address the reader is not cleared for says so; and a record with
               no address on file shows nothing. Absent is not empty (4.5). -->
          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.address')}</dt>
          <dd class="col-span-3">
            {#if openPerson.address}
              {openPerson.address}
            {:else if openPerson.addressRestricted}
              <span class="text-[var(--color-ink-muted)]">{t('records.field.restricted')}</span>
            {/if}
          </dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.deceased')}</dt>
          <dd>{formatMoment(openPerson.deceasedAt)}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.missing')}</dt>
          <dd>{formatMoment(openPerson.missingSince)}</dd>
        </dl>

        <!-- Description -->
        <div>
          <h3 class="text-xs font-semibold">{t('records.person.descriptors')}</h3>
          {#if personDetail.descriptors}
            <dl class="mt-1 grid grid-cols-2 gap-x-6 gap-y-1 text-xs md:grid-cols-4">
              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.height')}</dt>
              <dd>{personDetail.descriptors.heightCm ?? ''}</dd>

              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.weight')}</dt>
              <dd>{personDetail.descriptors.weightKg ?? ''}</dd>

              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.build')}</dt>
              <dd>{personDetail.descriptors.build ?? ''}</dd>

              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.hair')}</dt>
              <dd>{personDetail.descriptors.hairColour ?? ''}</dd>

              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.hairStyle')}</dt>
              <dd>{personDetail.descriptors.hairStyle ?? ''}</dd>

              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.eyes')}</dt>
              <dd>{personDetail.descriptors.eyeColour ?? ''}</dd>

              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.complexion')}</dt>
              <dd>{personDetail.descriptors.complexion ?? ''}</dd>

              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.glasses')}</dt>
              <dd>{personDetail.descriptors.glasses ? t('records.yes') : t('records.no')}</dd>

              <dt class="text-[var(--color-ink-muted)]">{t('records.descriptor.notes')}</dt>
              <dd class="col-span-3">{personDetail.descriptors.notes ?? ''}</dd>
            </dl>
          {:else}
            <p class="mt-1 text-xs text-[var(--color-ink-muted)]">
              {t('records.person.descriptor.empty')}
            </p>
          {/if}
        </div>

        <!-- Aliases -->
        <div>
          <h3 class="text-xs font-semibold">{t('records.person.aliases')}</h3>
          <ul class="mt-1 flex flex-wrap gap-3 text-xs">
            {#each personDetail.aliases ?? [] as alias (alias.id)}
              <li>
                <span>{alias.alias}</span>
                <span class="text-[var(--color-ink-muted)]">
                  {t(`records.aliasKind.${alias.kind}`)}
                </span>
              </li>
            {:else}
              <li class="text-[var(--color-ink-muted)]">{t('records.person.alias.empty')}</li>
            {/each}
          </ul>
        </div>

        <!-- Photographs. The image itself is media and is served through the
             gateway behind a signed URL (invariant 9); there is no media route
             in this build, so what is on file is listed and not rendered. -->
        <div>
          <h3 class="text-xs font-semibold">{t('records.person.photos')}</h3>
          <div class="mt-1 overflow-x-auto border border-[var(--color-border)]">
            <table class="w-full border-collapse text-xs">
              <thead>
                <tr class="border-b border-[var(--color-border)] text-left">
                  <th class="px-3 py-2 font-semibold">{t('records.person.photo.kind')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.person.photo.taken')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.person.photo.location')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.person.photo.description')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.person.photo.case')}</th>
                </tr>
              </thead>
              <tbody>
                {#each personDetail.photos ?? [] as photo (photo.id)}
                  <tr class="border-b border-[var(--color-border)] last:border-b-0">
                    <td class="px-3 py-2">{t(`records.photoKind.${photo.kind}`)}</td>
                    <td class="px-3 py-2">{formatMoment(photo.takenAt)}</td>
                    <td class="px-3 py-2">{photo.bodyLocation ?? ''}</td>
                    <td class="px-3 py-2">{photo.description ?? ''}</td>
                    <td class="px-3 py-2 font-[family-name:var(--font-mono)]">
                      {photo.sourceCase ?? ''}
                    </td>
                  </tr>
                {:else}
                  <tr>
                    <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="5">
                      {t('records.person.photo.empty')}
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
          <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('records.person.photo.note')}</p>
        </div>

        <!-- Biometrics: on file or not, never a value (8.1). -->
        <div>
          <h3 class="text-xs font-semibold">{t('records.person.biometrics')}</h3>
          <ul class="mt-1 flex flex-wrap gap-4 text-xs">
            {#each personDetail.biometrics ?? [] as biometric (biometric.kind)}
              <li>
                <span>{t(`records.biometric.${biometric.kind}`)}</span>
                <span class="text-[var(--color-ink-muted)]">
                  {biometric.onFile
                    ? t('records.biometric.onFile')
                    : t('records.biometric.notOnFile')}
                </span>
                {#if biometric.indexName}
                  <span class="font-[family-name:var(--font-mono)] text-[var(--color-ink-muted)]">
                    {biometric.indexName}
                  </span>
                {/if}
              </li>
            {:else}
              <li class="text-[var(--color-ink-muted)]">{t('records.person.biometric.empty')}</li>
            {/each}
          </ul>
        </div>

        <!-- Linked records, each read under its own record type on the server:
             a person an officer may read never carries a restricted vehicle or
             firearm out with them, so these lists carry stubs of their own. -->
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <h3 class="text-xs font-semibold">{t('records.person.vehicles')}</h3>
            <ul class="mt-1 flex flex-col text-xs">
              {#each personDetail.vehicles ?? [] as linked, index (index)}
                {#if isStub(linked)}
                  <li class="border-b border-[var(--color-border)] py-1 text-[var(--color-ink-muted)] last:border-b-0">
                    {t('records.restricted.title')} — {stubContact(linked)}
                  </li>
                {:else}
                  <li class="flex flex-wrap items-baseline gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
                    <button
                      type="button"
                      class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                      onclick={() => openVehicle(linked.id)}
                    >
                      {linked.plate}
                    </button>
                    <span>{linked.model ?? ''}</span>
                    <span class="text-[var(--color-ink-muted)]">{linked.colour ?? ''}</span>
                    <span class="text-[var(--color-ink-muted)]">
                      {t(`registry.registration.${linked.registrationStatus}`)}
                    </span>
                  </li>
                {/if}
              {:else}
                <li class="text-[var(--color-ink-muted)]">{t('records.person.vehicle.empty')}</li>
              {/each}
            </ul>
          </div>

          <div>
            <h3 class="text-xs font-semibold">{t('records.person.firearms')}</h3>
            <ul class="mt-1 flex flex-col text-xs">
              {#each personDetail.firearms ?? [] as linked, index (index)}
                {#if isStub(linked)}
                  <li class="border-b border-[var(--color-border)] py-1 text-[var(--color-ink-muted)] last:border-b-0">
                    {t('records.restricted.title')} — {stubContact(linked)}
                  </li>
                {:else}
                  <li class="flex flex-wrap items-baseline gap-2 border-b border-[var(--color-border)] py-1 last:border-b-0">
                    <button
                      type="button"
                      class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                      onclick={() => openFirearm(linked.id)}
                    >
                      {linked.serial}
                    </button>
                    <span>{linked.make ?? ''}</span>
                    <span>{linked.model ?? ''}</span>
                    <span class="text-[var(--color-ink-muted)]">
                      {t(`registry.firearm.status.${linked.status}`)}
                    </span>
                  </li>
                {/if}
              {:else}
                <li class="text-[var(--color-ink-muted)]">{t('records.person.firearm.empty')}</li>
              {/each}
            </ul>
          </div>
        </div>

        <!-- The editor. The address box is drawn only when the record did not
             come back with the address withheld: a reader who was not shown it
             must not overwrite it, and the server refuses the field outright.
             That refusal is still the control — this only keeps the officer
             from walking into it (invariant 4). -->
        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={savePerson}
        >
          <p class="w-full text-xs font-semibold">{t('records.person.edit.title')}</p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.firstName')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={personForm.firstName}
              maxlength="96"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.middleName')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={personForm.middleName}
              maxlength="96"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.lastName')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={personForm.lastName}
              maxlength="96"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.dateOfBirth')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              type="date"
              bind:value={personForm.dateOfBirth}
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.sex')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={personForm.sex}
            >
              <option value="">{t('records.form.unchanged')}</option>
              {#each PERSON_SEXES as value (value)}
                <option {value}>{t(`records.sex.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.phone')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={personForm.phone}
              maxlength="32"
            />
          </label>

          {#if !openPerson.addressRestricted}
            <label class="flex flex-col gap-1 text-xs">
              <span>{t('records.person.field.address')}</span>
              <input
                class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
                bind:value={personForm.address}
                maxlength="191"
              />
            </label>
          {/if}

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.classification')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={personForm.classification}
            >
              {#each CLASSIFICATIONS as value (value)}
                <option {value}>{t(`records.classification.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex items-center gap-1.5 text-xs">
            <input type="checkbox" bind:checked={personForm.deceased} />
            <span>{t('records.person.field.deceased')}</span>
          </label>

          <label class="flex items-center gap-1.5 text-xs">
            <input type="checkbox" bind:checked={personForm.missing} />
            <span>{t('records.person.field.missing')}</span>
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.person.edit.submit')}
          </button>
        </form>

        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={addCaution}
        >
          <p class="w-full text-xs font-semibold">{t('records.person.caution.title')}</p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.caution.kind')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={cautionKind}
            >
              {#each PERSON_CAUTION_KINDS as value (value)}
                <option {value}>{t(`records.cautionKind.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.caution.detail')}</span>
            <input
              class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={cautionDetail}
              maxlength="512"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.caution.sourceCase')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={cautionCase}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.classification')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={cautionClassification}
            >
              <option value="">{t('records.form.serverDefault')}</option>
              {#each CLASSIFICATIONS as value (value)}
                <option {value}>{t(`records.classification.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.caution.expires')}</span>
            <input
              class="w-24 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={cautionDays}
              inputmode="numeric"
              placeholder={t('records.person.caution.expiresPlaceholder')}
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.person.caution.add')}
          </button>
        </form>
      </article>
    {:else if personApplied !== null && personRows.length > 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('records.person.detail.none')}</p>
    {/if}

    <div class="mt-3 border-t border-[var(--color-border)] pt-3">
      <button
        type="button"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        onclick={() => (createPersonOpen = !createPersonOpen)}
      >
        {createPersonOpen ? t('records.person.create.hide') : t('records.person.create.show')}
      </button>

      {#if createPersonOpen}
        <form class="mt-3 flex flex-wrap items-end gap-3" onsubmit={createPerson}>
          <p class="w-full text-xs font-semibold">{t('records.person.create.title')}</p>
          <p class="w-full text-xs text-[var(--color-ink-muted)]">
            {t('records.person.create.intro')}
          </p>

          <label class="flex w-72 flex-col gap-1 text-xs">
            <span>{t('records.person.create.esxSearch')}</span>
            <EntityPicker
              placeholder={t('records.person.create.esxSearchPlaceholder')}
              search={searchEsxCharacters}
              label={(character) =>
                [character.firstName, character.lastName].filter(Boolean).join(' ') ||
                character.identifier}
              detail={(character) => character.dateOfBirth}
              getKey={(character) => character.identifier}
              selectedLabel={createPersonForm.identifier || null}
              onSelect={applyEsxCharacter}
              onClear={() => (createPersonForm.identifier = '')}
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.firstName')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={createPersonForm.firstName}
              maxlength="96"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.middleName')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={createPersonForm.middleName}
              maxlength="96"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.lastName')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={createPersonForm.lastName}
              maxlength="96"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.dateOfBirth')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              type="date"
              bind:value={createPersonForm.dateOfBirth}
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.sex')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={createPersonForm.sex}
            >
              <option value="">{t('records.form.serverDefault')}</option>
              {#each PERSON_SEXES as value (value)}
                <option {value}>{t(`records.person.sex.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.phone')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={createPersonForm.phone}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.address')}</span>
            <input
              class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={createPersonForm.address}
              maxlength="191"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.classification')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={createPersonForm.classification}
            >
              <option value="">{t('records.form.serverDefault')}</option>
              {#each CLASSIFICATIONS as value (value)}
                <option {value}>{t(`records.classification.${value}`)}</option>
              {/each}
            </select>
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.person.create.submit')}
          </button>
        </form>
      {/if}
    </div>
  {:else if tab === 'vehicles'}
    <!-- ------------------------------------------------------ vehicles -->
    <form class="flex flex-wrap items-end gap-3" onsubmit={runVehicleSearch}>
      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.search.term')}</span>
        <input
          class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={vehicleQuery.term}
          maxlength="24"
          placeholder={t('records.vehicle.search.termPlaceholder')}
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
      >
        {t('records.search.run')}
      </button>
    </form>

    {#if vehicleHitCount > 0}
      <div class="border-2 border-[var(--color-ink)] px-3 py-2">
        <p class="text-xs font-semibold">{t('records.hit.title')}</p>
        <p class="mt-0.5 text-xs">{t('records.hit.inResults', { count: vehicleHitCount })}</p>
      </div>
    {/if}

    {#if vehicleLoading}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:else if vehicleApplied !== null}
      <div class="overflow-x-auto border border-[var(--color-border)]">
        <table class="w-full border-collapse text-xs">
          <thead>
            <tr class="border-b border-[var(--color-border)] text-left">
              <th class="px-3 py-2 font-semibold">{t('records.vehicle.column.plate')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.vehicle.field.model')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.vehicle.field.colour')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.vehicle.field.registration')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.vehicle.field.insurance')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.hit.column')}</th>
            </tr>
          </thead>
          <tbody>
            {#each vehicleRows as row, index (index)}
              {#if isStub(row)}
                <tr class="border-b border-[var(--color-border)] last:border-b-0">
                  <td class="px-3 py-2 text-[var(--color-ink-muted)]" colspan="6">
                    {t('records.restricted.title')} — {stubContact(row)}
                  </td>
                </tr>
              {:else}
                <tr class="border-b border-[var(--color-border)] last:border-b-0">
                  <td class="px-3 py-2">
                    <button
                      type="button"
                      class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                      class:font-semibold={selectedVehicleId === row.id}
                      onclick={() => (selectedVehicleId = row.id)}
                    >
                      {row.plate}
                    </button>
                  </td>
                  <td class="px-3 py-2">{row.model ?? ''}</td>
                  <td class="px-3 py-2">{row.colour ?? ''}</td>
                  <td class="px-3 py-2">
                    {t(`registry.registration.${row.registrationStatus}`)}
                  </td>
                  <td class="px-3 py-2">{t(`registry.insurance.${row.insuranceStatus}`)}</td>
                  <td class="px-3 py-2 font-semibold">{vehicleHitText(row.hits)}</td>
                </tr>
              {/if}
            {:else}
              <tr>
                <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="6">
                  {t('records.vehicle.empty')}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}

    {#if openVehicleRecord && vehicleDetail}
      <article class="flex flex-col gap-4 border border-[var(--color-border)] p-3">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">
            {openVehicleRecord.plate}
          </h2>
          <span class="font-[family-name:var(--font-mono)] text-xs text-[var(--color-ink-muted)]">
            {openVehicleRecord.vin}
          </span>
        </header>

        <!-- Hot-file hit (7.2). A banner with a confirmation step, never a
             toast (6.4). The confirmation is an acknowledgement on this screen:
             there is no hit-confirmation route, so nothing is recorded by it
             and the text says as much rather than implying a receipt. -->
        {#if vehicleDetail.hits.length > 0}
          <div class="border-2 border-[var(--color-ink)] px-3 py-2">
            <p class="text-sm font-semibold">{t('records.hit.title')}</p>
            <p class="mt-0.5 text-xs">{vehicleHitText(vehicleDetail.hits)}</p>

            {#if confirmedVehicleHit === openVehicleRecord.id}
              <p class="mt-1 text-xs text-[var(--color-ink-muted)]">
                {t('records.hit.confirmed')}
              </p>
            {:else}
              <p class="mt-1 text-xs">{t('records.hit.body')}</p>
              <button
                type="button"
                class="mt-2 border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
                onclick={() => (confirmedVehicleHit = selectedVehicleId)}
              >
                {t('records.hit.confirm')}
              </button>
            {/if}
          </div>
        {/if}

        <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-xs md:grid-cols-4">
          <dt class="text-[var(--color-ink-muted)]">{t('records.vehicle.field.model')}</dt>
          <dd>{openVehicleRecord.model ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.vehicle.field.colour')}</dt>
          <dd>{openVehicleRecord.colour ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.vehicle.field.colourSecondary')}</dt>
          <dd>{openVehicleRecord.colourSecondary ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.field.ownerIdentifier')}</dt>
          <dd class="font-[family-name:var(--font-mono)]">
            {openVehicleRecord.ownerIdentifier ?? ''}
          </dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.vehicle.field.registration')}</dt>
          <dd>
            {t(`registry.registration.${openVehicleRecord.registrationStatus}`)}
            {formatDate(openVehicleRecord.registrationExpires)}
          </dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.vehicle.field.insurance')}</dt>
          <dd>
            {t(`registry.insurance.${openVehicleRecord.insuranceStatus}`)}
            {formatDate(openVehicleRecord.insuranceExpires)}
          </dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.classification')}</dt>
          <dd>{t(`records.classification.${openVehicleRecord.classification}`)}</dd>
        </dl>

        <!-- Recent plate reads (7.18), surfaced on the vehicle itself so an
             officer sees where it was last seen without a separate trip to
             the ALPR screen. Best-effort: a reader without `alpr.read.view`
             simply sees none, the same way a refused read draws as nothing
             rather than an error (4.5). -->
        <div>
          <h3 class="text-xs font-semibold">{t('records.vehicle.section.alpr')}</h3>
          {#if vehicleAlprReads.length === 0}
            <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('records.vehicle.alpr.empty')}</p>
          {:else}
            <ul class="mt-1 text-xs">
              {#each vehicleAlprReads as read (read.id)}
                <li class="flex justify-between border-t border-[var(--color-border)] py-1">
                  <span class="font-[family-name:var(--font-mono)]">{formatMoment(read.readAt)}</span>
                  <span class="text-[var(--color-ink-muted)]">
                    {Math.round(read.x)}, {Math.round(read.y)}
                    {#if read.hit}· {t('records.vehicle.alpr.hit')}{/if}
                  </span>
                </li>
              {/each}
            </ul>
          {/if}
        </div>

        <!-- Flags. A flag can be more sensitive than the vehicle it sits on, so
             this list carries stubs of its own (4.5). -->
        <div>
          <h3 class="text-xs font-semibold">{t('records.vehicle.flags')}</h3>
          <div class="mt-1 overflow-x-auto border border-[var(--color-border)]">
            <table class="w-full border-collapse text-xs">
              <thead>
                <tr class="border-b border-[var(--color-border)] text-left">
                  <th class="px-3 py-2 font-semibold">{t('records.vehicle.flag.kind')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.vehicle.flag.detail')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.authority.caseNumber')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.vehicle.flag.expires')}</th>
                  <th class="px-3 py-2"></th>
                </tr>
              </thead>
              <tbody>
                {#each vehicleDetail.flags as flag, index (index)}
                  {#if isStub(flag)}
                    <tr class="border-b border-[var(--color-border)] last:border-b-0">
                      <td class="px-3 py-2 text-[var(--color-ink-muted)]" colspan="5">
                        {t('records.restricted.title')} — {stubContact(flag)}
                      </td>
                    </tr>
                  {:else}
                    <tr class="border-b border-[var(--color-border)] last:border-b-0">
                      <td class="px-3 py-2">{t(`registry.flag.${flag.kind}`)}</td>
                      <td class="px-3 py-2">{flag.detail ?? ''}</td>
                      <td class="px-3 py-2 font-[family-name:var(--font-mono)]">
                        {flag.caseNumber ?? ''}
                      </td>
                      <td class="px-3 py-2">
                        {flag.expiresAt
                          ? formatMoment(flag.expiresAt)
                          : t('records.person.caution.noExpiry')}
                      </td>
                      <td class="px-3 py-2 text-right">
                        <button
                          type="button"
                          class="border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-surface)]"
                          disabled={busy}
                          onclick={() => clearFlag(flag.id)}
                        >
                          {t('records.vehicle.flag.clear')}
                        </button>
                      </td>
                    </tr>
                  {/if}
                {:else}
                  <tr>
                    <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="5">
                      {t('records.vehicle.flag.empty')}
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        </div>

        <form class="flex flex-wrap items-end gap-3" onsubmit={addFlag}>
          <p class="w-full text-xs font-semibold">{t('records.vehicle.flag.add')}</p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.flag.kind')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={flagKind}
            >
              {#each VEHICLE_FLAG_KINDS as value (value)}
                <option {value}>{t(`registry.flag.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.flag.detail')}</span>
            <input
              class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={flagDetail}
              maxlength="512"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.authority.caseNumber')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={flagCase}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.classification')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={flagClassification}
            >
              <option value="">{t('records.form.serverDefault')}</option>
              {#each CLASSIFICATIONS as value (value)}
                <option {value}>{t(`records.classification.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.flag.expiresIn')}</span>
            <input
              class="w-28 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={flagExpiresIn}
              inputmode="numeric"
              placeholder={t('records.vehicle.flag.expiresInPlaceholder')}
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.vehicle.flag.submit')}
          </button>
        </form>

        <!-- Plate history: append-only on the server, read-only here. -->
        <div>
          <h3 class="text-xs font-semibold">{t('records.vehicle.plates')}</h3>
          <div class="mt-1 overflow-x-auto border border-[var(--color-border)]">
            <table class="w-full border-collapse text-xs">
              <thead>
                <tr class="border-b border-[var(--color-border)] text-left">
                  <th class="px-3 py-2 font-semibold">{t('records.vehicle.column.plate')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.vehicle.plate.from')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.vehicle.plate.until')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.vehicle.plate.reason')}</th>
                </tr>
              </thead>
              <tbody>
                {#each vehicleDetail.plates as period (period.id)}
                  <tr class="border-b border-[var(--color-border)] last:border-b-0">
                    <td class="px-3 py-2 font-[family-name:var(--font-mono)]">{period.plate}</td>
                    <td class="px-3 py-2">{formatMoment(period.heldFrom)}</td>
                    <td class="px-3 py-2">{formatMoment(period.heldUntil)}</td>
                    <td class="px-3 py-2">{period.reason ?? ''}</td>
                  </tr>
                {:else}
                  <tr>
                    <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="4">
                      {t('records.vehicle.plate.empty')}
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        </div>

        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={changePlate}
        >
          <p class="w-full text-xs font-semibold">{t('records.vehicle.plate.change')}</p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.plate.new')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={newPlate}
              maxlength="16"
              required
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.plate.reason')}</span>
            <input
              class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={plateReason}
              maxlength="191"
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.vehicle.plate.submit')}
          </button>
        </form>

        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={saveVehicle}
        >
          <p class="w-full text-xs font-semibold">{t('records.vehicle.edit.title')}</p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.field.model')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={vehicleForm.model}
              maxlength="64"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.field.colour')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={vehicleForm.colour}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.field.colourSecondary')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={vehicleForm.colourSecondary}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.field.ownerIdentifier')}</span>
            <input
              class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={vehicleForm.ownerIdentifier}
              maxlength="191"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.field.registration')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={vehicleForm.registrationStatus}
            >
              {#each VEHICLE_REGISTRATION_STATUSES as value (value)}
                <option {value}>{t(`registry.registration.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.field.registrationExpires')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              type="date"
              bind:value={vehicleForm.registrationExpires}
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.field.insurance')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={vehicleForm.insuranceStatus}
            >
              {#each VEHICLE_INSURANCE_STATUSES as value (value)}
                <option {value}>{t(`registry.insurance.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.vehicle.field.insuranceExpires')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              type="date"
              bind:value={vehicleForm.insuranceExpires}
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.classification')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={vehicleForm.classification}
            >
              {#each CLASSIFICATIONS as value (value)}
                <option {value}>{t(`records.classification.${value}`)}</option>
              {/each}
            </select>
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.vehicle.edit.submit')}
          </button>
        </form>
      </article>
    {:else if vehicleApplied !== null && vehicleRows.length > 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('records.vehicle.detail.none')}</p>
    {/if}

    <form
      class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
      onsubmit={registerVehicle}
    >
      <p class="w-full text-xs font-semibold">{t('records.vehicle.register.title')}</p>
      <p class="w-full text-xs text-[var(--color-ink-muted)]">
        {t('records.vehicle.register.intro')}
      </p>

      <label class="flex w-72 flex-col gap-1 text-xs">
        <span>{t('records.vehicle.register.esxSearch')}</span>
        <EntityPicker
          placeholder={t('records.vehicle.register.esxSearchPlaceholder')}
          search={searchOwnedVehicles}
          label={(vehicle) => vehicle.plate}
          detail={(vehicle) => [vehicle.model, vehicle.owner].filter(Boolean).join(' · ')}
          getKey={(vehicle) => vehicle.plate}
          onSelect={applyOwnedVehicle}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.field.plate')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={registerVehicleForm.plate}
          maxlength="16"
          required
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.field.model')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerVehicleForm.model}
          maxlength="64"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.field.colour')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerVehicleForm.colour}
          maxlength="32"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.field.colourSecondary')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerVehicleForm.colourSecondary}
          maxlength="32"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.field.ownerIdentifier')}</span>
        <input
          class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={registerVehicleForm.ownerIdentifier}
          maxlength="191"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.field.registration')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerVehicleForm.registrationStatus}
        >
          <option value="">{t('records.form.serverDefault')}</option>
          {#each VEHICLE_REGISTRATION_STATUSES as value (value)}
            <option {value}>{t(`registry.registration.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.field.registrationExpires')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          type="date"
          bind:value={registerVehicleForm.registrationExpires}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.field.insurance')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerVehicleForm.insuranceStatus}
        >
          <option value="">{t('records.form.serverDefault')}</option>
          {#each VEHICLE_INSURANCE_STATUSES as value (value)}
            <option {value}>{t(`registry.insurance.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.field.insuranceExpires')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          type="date"
          bind:value={registerVehicleForm.insuranceExpires}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.person.field.classification')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerVehicleForm.classification}
        >
          <option value="">{t('records.form.serverDefault')}</option>
          {#each CLASSIFICATIONS as value (value)}
            <option {value}>{t(`records.classification.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.vehicle.register.reason')}</span>
        <input
          class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerVehicleForm.reason}
          maxlength="191"
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('records.vehicle.register.submit')}
      </button>
    </form>
  {:else if tab === 'firearms'}
    <!-- ------------------------------------------------------ firearms -->
    <form class="flex flex-wrap items-end gap-3" onsubmit={runFirearmSearch}>
      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.search.term')}</span>
        <input
          class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={firearmQuery.term}
          maxlength="64"
          placeholder={t('records.firearm.search.termPlaceholder')}
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.status')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={firearmQuery.status}
        >
          <option value="">{t('records.form.any')}</option>
          {#each FIREARM_STATUSES as value (value)}
            <option {value}>{t(`registry.firearm.status.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.assignedOfficer')}</span>
        <input
          class="w-48 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={firearmQuery.assignedOfficer}
          maxlength="32"
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
      >
        {t('records.search.run')}
      </button>
    </form>

    {#if firearmHitCount > 0}
      <div class="border-2 border-[var(--color-ink)] px-3 py-2">
        <p class="text-xs font-semibold">{t('records.hit.title')}</p>
        <p class="mt-0.5 text-xs">{t('records.hit.inResults', { count: firearmHitCount })}</p>
      </div>
    {/if}

    {#if firearmLoading}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
    {:else if firearmApplied !== null}
      <div class="overflow-x-auto border border-[var(--color-border)]">
        <table class="w-full border-collapse text-xs">
          <thead>
            <tr class="border-b border-[var(--color-border)] text-left">
              <th class="px-3 py-2 font-semibold">{t('records.firearm.field.serial')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.firearm.field.make')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.firearm.field.model')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.firearm.field.type')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.firearm.field.calibre')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.firearm.field.status')}</th>
              <th class="px-3 py-2 font-semibold">{t('records.hit.column')}</th>
            </tr>
          </thead>
          <tbody>
            {#each firearmRows as row, index (index)}
              {#if isStub(row)}
                <tr class="border-b border-[var(--color-border)] last:border-b-0">
                  <td class="px-3 py-2 text-[var(--color-ink-muted)]" colspan="7">
                    {t('records.restricted.title')} — {stubContact(row)}
                  </td>
                </tr>
              {:else}
                <tr class="border-b border-[var(--color-border)] last:border-b-0">
                  <td class="px-3 py-2">
                    <button
                      type="button"
                      class="font-[family-name:var(--font-mono)] underline-offset-2 hover:underline"
                      class:font-semibold={selectedFirearmId === row.id}
                      onclick={() => (selectedFirearmId = row.id)}
                    >
                      {row.serial}
                    </button>
                  </td>
                  <td class="px-3 py-2">{row.make ?? ''}</td>
                  <td class="px-3 py-2">{row.model ?? ''}</td>
                  <td class="px-3 py-2">{row.type ? t(`registry.firearm.type.${row.type}`) : ''}</td>
                  <td class="px-3 py-2">{row.calibre ?? ''}</td>
                  <td class="px-3 py-2">{t(`registry.firearm.status.${row.status}`)}</td>
                  <td class="px-3 py-2 font-semibold">{firearmHitText(row.hits)}</td>
                </tr>
              {/if}
            {:else}
              <tr>
                <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="7">
                  {t('records.firearm.empty')}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}

    {#if openFirearmRecord && firearmDetail}
      <article class="flex flex-col gap-4 border border-[var(--color-border)] p-3">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-[family-name:var(--font-mono)] text-sm font-semibold">
            {openFirearmRecord.serial}
          </h2>
          <span class="text-xs text-[var(--color-ink-muted)]">
            {t(`registry.firearm.status.${openFirearmRecord.status}`)}
          </span>
        </header>

        {#if firearmDetail.hits.length > 0}
          <div class="border-2 border-[var(--color-ink)] px-3 py-2">
            <p class="text-sm font-semibold">{t('records.hit.title')}</p>
            <p class="mt-0.5 text-xs">{firearmHitText(firearmDetail.hits)}</p>

            {#if confirmedFirearmHit === openFirearmRecord.id}
              <p class="mt-1 text-xs text-[var(--color-ink-muted)]">{t('records.hit.confirmed')}</p>
            {:else}
              <p class="mt-1 text-xs">{t('records.hit.body')}</p>
              <button
                type="button"
                class="mt-2 border border-[var(--color-border)] px-3 py-1 text-xs hover:bg-[var(--color-surface)]"
                onclick={() => (confirmedFirearmHit = selectedFirearmId)}
              >
                {t('records.hit.confirm')}
              </button>
            {/if}
          </div>
        {/if}

        <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-xs md:grid-cols-4">
          <dt class="text-[var(--color-ink-muted)]">{t('records.firearm.field.make')}</dt>
          <dd>{openFirearmRecord.make ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.firearm.field.model')}</dt>
          <dd>{openFirearmRecord.model ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.firearm.field.type')}</dt>
          <dd>
            {openFirearmRecord.type ? t(`registry.firearm.type.${openFirearmRecord.type}`) : ''}
          </dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.firearm.field.calibre')}</dt>
          <dd>{openFirearmRecord.calibre ?? ''}</dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.field.ownerIdentifier')}</dt>
          <dd class="font-[family-name:var(--font-mono)]">
            {openFirearmRecord.ownerIdentifier ?? ''}
          </dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.firearm.field.assignedOfficer')}</dt>
          <dd class="font-[family-name:var(--font-mono)]">
            {openFirearmRecord.assignedOfficer ?? ''}
          </dd>

          <dt class="text-[var(--color-ink-muted)]">{t('records.person.field.classification')}</dt>
          <dd>{t(`records.classification.${openFirearmRecord.classification}`)}</dd>
        </dl>

        <!-- The ownership history. Part of the record; the trace below is the
             same events read as a report and behind its own permission (7.5). -->
        <div>
          <h3 class="text-xs font-semibold">{t('records.firearm.events')}</h3>
          <div class="mt-1 overflow-x-auto border border-[var(--color-border)]">
            <table class="w-full border-collapse text-xs">
              <thead>
                <tr class="border-b border-[var(--color-border)] text-left">
                  <th class="px-3 py-2 font-semibold">{t('records.firearm.event.occurred')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.firearm.event.event')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.firearm.event.from')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.firearm.event.to')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.authority.caseNumber')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.authority.reason')}</th>
                  <th class="px-3 py-2 font-semibold">{t('records.firearm.event.recordedBy')}</th>
                </tr>
              </thead>
              <tbody>
                {#each firearmDetail.events as event (event.id)}
                  <tr class="border-b border-[var(--color-border)] last:border-b-0">
                    <td class="px-3 py-2">{formatMoment(event.occurredAt)}</td>
                    <td class="px-3 py-2">{t(`registry.firearm.event.${event.event}`)}</td>
                    <td class="px-3 py-2">{event.fromParty ?? ''}</td>
                    <td class="px-3 py-2">{event.toParty ?? ''}</td>
                    <td class="px-3 py-2 font-[family-name:var(--font-mono)]">
                      {event.caseNumber ?? ''}
                    </td>
                    <td class="px-3 py-2">{event.reason ?? ''}</td>
                    <td class="px-3 py-2 font-[family-name:var(--font-mono)]">
                      {event.recordedBy ?? ''}
                    </td>
                  </tr>
                {:else}
                  <tr>
                    <td class="px-3 py-3 text-[var(--color-ink-muted)]" colspan="7">
                      {t('records.firearm.event.empty')}
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        </div>

        <div class="flex flex-wrap items-baseline gap-3">
          <button
            type="button"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
            onclick={runTrace}
          >
            {t('records.firearm.trace.run')}
          </button>
          <p class="text-xs text-[var(--color-ink-muted)]">{t('records.firearm.trace.intro')}</p>
        </div>

        {#if trace}
          <div class="border border-[var(--color-border)] px-3 py-2 text-xs">
            <p class="font-semibold">{t('records.firearm.trace.title')}</p>
            {#if trace.origin}
              <p class="mt-1">
                {t('records.firearm.trace.origin', {
                  event: t(`registry.firearm.event.${trace.origin.event}`),
                  moment: formatMoment(trace.origin.occurredAt),
                  party: trace.origin.toParty ?? '',
                })}
              </p>
            {:else}
              <p class="mt-1 text-[var(--color-ink-muted)]">
                {t('records.firearm.trace.noOrigin')}
              </p>
            {/if}
            <p class="mt-1 text-[var(--color-ink-muted)]">
              {t('records.firearm.trace.links', { count: trace.events.length })}
            </p>
          </div>
        {/if}

        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={saveFirearm}
        >
          <p class="w-full text-xs font-semibold">{t('records.firearm.edit.title')}</p>
          <p class="w-full text-xs text-[var(--color-ink-muted)]">
            {t('records.firearm.edit.intro')}
          </p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.field.make')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={firearmForm.make}
              maxlength="64"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.field.model')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={firearmForm.model}
              maxlength="64"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.field.type')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={firearmForm.type}
            >
              <option value="">{t('records.form.unchanged')}</option>
              {#each FIREARM_TYPES as value (value)}
                <option {value}>{t(`registry.firearm.type.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.field.calibre')}</span>
            <input
              class="w-28 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={firearmForm.calibre}
              maxlength="24"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.person.field.classification')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={firearmForm.classification}
            >
              {#each CLASSIFICATIONS as value (value)}
                <option {value}>{t(`records.classification.${value}`)}</option>
              {/each}
            </select>
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.firearm.edit.submit')}
          </button>
        </form>

        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={setFirearmStatus}
        >
          <p class="w-full text-xs font-semibold">{t('records.firearm.status.title')}</p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.field.status')}</span>
            <select
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={statusValue}
            >
              {#each FIREARM_STATUSES as value (value)}
                <option {value}>{t(`registry.firearm.status.${value}`)}</option>
              {/each}
            </select>
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.authority.caseNumber')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={statusCase}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.authority.reason')}</span>
            <input
              class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={statusReason}
              maxlength="512"
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.firearm.status.submit')}
          </button>
        </form>

        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={transferFirearm}
        >
          <p class="w-full text-xs font-semibold">{t('records.firearm.transfer.title')}</p>
          <p class="w-full text-xs text-[var(--color-ink-muted)]">
            {t('records.firearm.transfer.intro')}
          </p>

          <div class="flex w-64 flex-col gap-1 text-xs">
            <span id="firearm-transfer-person-label">{t('records.firearm.transfer.toPersonId')}</span>
            <PersonPicker bind:value={transferPersonId} labelledby="firearm-transfer-person-label" />
          </div>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.transfer.toIdentifier')}</span>
            <input
              class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={transferIdentifier}
              maxlength="191"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.transfer.toParty')}</span>
            <input
              class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={transferToParty}
              maxlength="191"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.transfer.fromParty')}</span>
            <input
              class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={transferFromParty}
              maxlength="191"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.authority.caseNumber')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={transferCase}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.authority.reason')}</span>
            <input
              class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={transferReason}
              maxlength="512"
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.firearm.transfer.submit')}
          </button>
        </form>

        <form
          class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
          onsubmit={assignFirearm}
        >
          <p class="w-full text-xs font-semibold">{t('records.firearm.assign.title')}</p>
          <p class="w-full text-xs text-[var(--color-ink-muted)]">
            {t('records.firearm.assign.intro')}
          </p>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.firearm.field.assignedOfficer')}</span>
            <input
              class="w-48 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={assignOfficer}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.authority.caseNumber')}</span>
            <input
              class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
              bind:value={assignCase}
              maxlength="32"
            />
          </label>

          <label class="flex flex-col gap-1 text-xs">
            <span>{t('records.authority.reason')}</span>
            <input
              class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
              bind:value={assignReason}
              maxlength="512"
            />
          </label>

          <button
            type="submit"
            class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
            disabled={busy}
          >
            {t('records.firearm.assign.submit')}
          </button>
        </form>
      </article>
    {:else if firearmApplied !== null && firearmRows.length > 0}
      <p class="text-sm text-[var(--color-ink-muted)]">{t('records.firearm.detail.none')}</p>
    {/if}

    <form
      class="flex flex-wrap items-end gap-3 border-t border-[var(--color-border)] pt-3"
      onsubmit={registerFirearm}
    >
      <p class="w-full text-xs font-semibold">{t('records.firearm.register.title')}</p>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.serial')}</span>
        <input
          class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={registerFirearmForm.serial}
          maxlength="64"
          required
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.make')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerFirearmForm.make}
          maxlength="64"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.model')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerFirearmForm.model}
          maxlength="64"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.type')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerFirearmForm.type}
        >
          <option value="">{t('records.form.notStated')}</option>
          {#each FIREARM_TYPES as value (value)}
            <option {value}>{t(`registry.firearm.type.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.calibre')}</span>
        <input
          class="w-28 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerFirearmForm.calibre}
          maxlength="24"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.status')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerFirearmForm.status}
        >
          <option value="">{t('records.form.serverDefault')}</option>
          {#each FIREARM_STATUSES as value (value)}
            <option {value}>{t(`registry.firearm.status.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.field.ownerIdentifier')}</span>
        <input
          class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={registerFirearmForm.ownerIdentifier}
          maxlength="191"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.ownerParty')}</span>
        <input
          class="w-56 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerFirearmForm.ownerParty}
          maxlength="191"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.firearm.field.assignedOfficer')}</span>
        <input
          class="w-48 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={registerFirearmForm.assignedOfficer}
          maxlength="32"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.person.field.classification')}</span>
        <select
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerFirearmForm.classification}
        >
          <option value="">{t('records.form.serverDefault')}</option>
          {#each CLASSIFICATIONS as value (value)}
            <option {value}>{t(`records.classification.${value}`)}</option>
          {/each}
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.authority.caseNumber')}</span>
        <input
          class="border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1 font-[family-name:var(--font-mono)]"
          bind:value={registerFirearmForm.caseNumber}
          maxlength="32"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span>{t('records.authority.reason')}</span>
        <input
          class="w-72 border border-[var(--color-border)] bg-[var(--color-panel)] px-2 py-1"
          bind:value={registerFirearmForm.reason}
          maxlength="512"
        />
      </label>

      <button
        type="submit"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        disabled={busy}
      >
        {t('records.firearm.register.submit')}
      </button>
    </form>
  {:else if tab === 'anmalan'}
    <!--
      Its own component. `Records.svelte` is the tab host for the three
      registers and would be five thousand lines with the report workflow
      inlined; `cad/` is split the same way and for the same reason.

      It takes no props: what the session may do with a record comes back on
      `anmalan.get` as the server's own answer, rather than being inferred here
      from an identifier the interface would have to be sent first.
    -->
    <Anmalan />
  {:else if tab === 'fu'}
    <!--
      The investigation (7.8). The anmälan tab beside it holds the *reports*;
      this is the case opened off the back of one, with its own leader and its
      own three ways to end.
    -->
    <Fu />
  {:else if tab === 'frihet'}
    <!--
      Its own component for the same reason, and one more: it holds a ticking
      clock. The countdown interval belongs to the screen that draws it and is
      cleared when that screen goes away, which a branch inside the tab host
      could not do.
    -->
    <Frihet />
  {:else if tab === 'tvang'}
    <!--
      Coercive measures (7.12). Its own component for the reason the two above
      are: the decide form, the execution record and the revocation are a
      workflow, not a register search.
    -->
    <Tvang />
  {:else if tab === 'efterlysning'}
    <!--
      Wanted notices (7.13). Separate from tvångsmedel although the two share a
      counter and a module on the server: an efterlysning names a person and
      feeds the hot-file check, and a husrannsakan names a place and opens a
      door. Putting them on one tab would be inviting the confusion
      `EFTERLYSNING` was given its own record type to prevent.
    -->
    <Efterlysning />
  {:else if tab === 'brott'}
    <!--
      Brottskatalogen (7.10) and BrB 26:2's arithmetic. Reference rather than
      workflow, and last in the rail for that reason — but it is where the
      combined range an officer quotes to a prosecutor is computed.
    -->
    <Brott />
  {:else if tab === 'spaning'}
    <!--
      The patrol lookout (7.13), which is emphatically not the tab beside it.
    -->
    <Spaning />
  {:else if tab === 'ordningsbot'}
    <!-- Citations (7.11) sit on the Records rail rather than a rail of
         their own -- the plan for this module states that choice plainly. -->
    <Ordningsbot />
  {:else if tab === 'impound'}
    <Impound />
  {:else if tab === 'locations'}
    <Locations />
  {/if}
</section>
