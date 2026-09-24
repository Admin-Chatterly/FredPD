import { nui } from '../../lib/nui';
import { t } from '../../lib/i18n';
import { formatDate } from '../../lib/time';
import {
  isStub,
  type PersonResult,
  type PersonSearchResult,
  type VehicleResult,
  type VehicleSearchResult,
} from '../records/types';
import { PickerRefusal, type PickerResult } from './picker-result';
import { personName } from './names';

/**
 * The searches behind the person and vehicle pickers (PersonPicker,
 * VehiclePicker). An officer types a name or a plate and picks a record;
 * nobody copies an internal id off another screen any more.
 *
 * Both call the registers' own search routes, so access, logging, the reason
 * rule and the rate limit are theirs (7.2, invariant 4). A refusal is thrown
 * so the box says why rather than "no matches". A restricted row comes back
 * as a stub with no id and cannot be picked; the box says rows were withheld
 * and where to search for them with a reason.
 */

/**
 * Shorter than this, nothing is asked. Three rather than the registers' two:
 * a picker searches on every pause in typing, and it shares the search
 * route's rate limit with the Query tab.
 */
const MIN_TERM = 3;

export async function searchPersonOptions(term: string): Promise<PickerResult<PersonResult>> {
  const trimmed = term.trim();
  if (trimmed.length < MIN_TERM) return [];

  const response = await nui.call<PersonSearchResult>('person.search', { term: trimmed });
  if (!response.ok) throw new PickerRefusal(response.err);

  const rows = response.data.persons;
  const items = rows.filter((row): row is PersonResult => !isStub(row));
  const withheld = rows.length - items.length > 0 || response.data.restrictedWithheld;

  return { items, note: withheld ? t('picker.withheld') : null };
}

export function personLabel(person: PersonResult): string {
  const name = personName(person);
  return name ? `${name} (${person.personNumber})` : person.personNumber;
}

export function personDetail(person: PersonResult): string | null {
  return person.dateOfBirth ? formatDate(person.dateOfBirth) : null;
}

export async function searchVehicleOptions(term: string): Promise<PickerResult<VehicleResult>> {
  const trimmed = term.trim();
  if (trimmed.length < MIN_TERM) return [];

  const response = await nui.call<VehicleSearchResult>('vehicle.search', { term: trimmed });
  if (!response.ok) throw new PickerRefusal(response.err);

  const rows = response.data.vehicles;
  const items = rows.filter((row): row is VehicleResult => !isStub(row));

  return { items, note: rows.length > items.length ? t('picker.withheld') : null };
}

export function vehicleLabel(vehicle: VehicleResult): string {
  return vehicle.plate;
}

export function vehicleDetail(vehicle: VehicleResult): string | null {
  return [vehicle.model, vehicle.colour].filter(Boolean).join(' · ') || null;
}
