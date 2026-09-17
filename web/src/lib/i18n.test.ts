import { describe, expect, it } from 'vitest';

import { SUPPORTED_LOCALES, isLocale, t } from './i18n';

describe('i18n', () => {
  it('translates a key', () => {
    expect(t('app.name')).toBe('FredPD');
  });

  it('substitutes named placeholders', () => {
    expect(t('shell.status.unit', { callsign: '12-40' })).toBe('Unit 12-40');
  });

  it('leaves an unknown placeholder in place rather than blanking it', () => {
    expect(t('shell.status.unit')).toBe('Unit {callsign}');
  });

  it('renders an unknown key as the key, so a gap is visible', () => {
    expect(t('nope.not.a.key')).toBe('nope.not.a.key');
  });

  it('recognises supported locales only', () => {
    expect(SUPPORTED_LOCALES.every(isLocale)).toBe(true);
    expect(isLocale('de')).toBe(false);
  });
});
