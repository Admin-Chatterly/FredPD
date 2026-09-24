/** "Doe, John": the order the record header and the Query tab use. */
export function personName(person: {
  firstName?: string | null;
  middleName?: string | null;
  lastName?: string | null;
}): string {
  const given = [person.firstName, person.middleName].filter(Boolean).join(' ');
  const surname = person.lastName ?? '';

  if (surname && given) return `${surname}, ${given}`;
  return surname || given;
}
