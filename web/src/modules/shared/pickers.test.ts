import { describe, expect, it } from 'vitest';
import { personName } from './names';
import { PickerRefusal } from './picker-result';

describe('personName', () => {
  it('puts the surname first, as the record header and Query do', () => {
    expect(personName({ firstName: 'John', middleName: 'A.', lastName: 'Doe' })).toBe('Doe, John A.');
  });

  it('copes with half a name, and none', () => {
    expect(personName({ lastName: 'Doe' })).toBe('Doe');
    expect(personName({ firstName: 'John' })).toBe('John');
    expect(personName({})).toBe('');
  });
});

describe('PickerRefusal', () => {
  it('carries the route error code for the box to translate', () => {
    expect(new PickerRefusal('forbidden').code).toBe('forbidden');
  });
});
