import { describe, expect, it } from 'vitest';

import en from '@locales/en.json';
import sv from '@locales/sv.json';
import { t } from '../../lib/i18n';
import { fieldList } from './failure';

/**
 * The rejection codes the route validator can answer with
 * (`server/core/validate.lua`). Every one of them has to reach the officer as a
 * sentence in their own language: a code that is not in `REASONS` renders as
 * the raw English word in both locales, which is how `too_long` and friends
 * were shown before.
 */
const VALIDATOR_CODES = [
  'required',
  'type',
  'too_short',
  'too_long',
  'too_small',
  'too_large',
  'not_integer',
  'not_allowed',
  'too_many',
];

function failure(fields: Record<string, string>) {
  return { err: 'invalid' as const, fields };
}

describe('fieldList', () => {
  it('translates every code the validator can answer with', () => {
    const fields = Object.fromEntries(VALIDATOR_CODES.map((code) => [code, code]));
    const messages = fieldList(failure(fields), {});

    expect(messages).toHaveLength(VALIDATOR_CODES.length);

    for (const message of messages) {
      // `t` renders an unknown key as the key itself, so this catches a code
      // that never reached `REASONS` as well as a missing locale entry.
      expect(message.reason, message.name).toBe(t(`fieldError.${message.name}`));
      expect(message.reason, message.name).not.toBe(`fieldError.${message.name}`);
    }
  });

  it('has a Swedish sentence for each of them too', () => {
    for (const code of VALIDATOR_CODES) {
      const english = (en.fieldError as Record<string, string>)[code];
      const swedish = (sv.fieldError as Record<string, string>)[code];

      expect(english, code).toBeTruthy();
      expect(swedish, code).toBeTruthy();
      // A gloss left untranslated is a missing translation wearing a disguise.
      expect(swedish, code).not.toBe(english);
    }
  });

  it('names the box the officer can see, not the column', () => {
    const [message] = fieldList(failure({ radius: 'too_small' }), {
      radius: 'evidence.scene.radius',
    });

    expect(message?.label).toBe(t('evidence.scene.radius'));
    expect(message?.reason).toBe(t('fieldError.too_small'));
  });

  it('falls back to the field name when no label is mapped', () => {
    const [message] = fieldList(failure({ placementId: 'required' }), {});
    expect(message?.label).toBe('placementId');
  });

  it('shows an unknown code as it arrived, rather than as a missing translation', () => {
    const [message] = fieldList(failure({ status: 'collected' }), {});
    expect(message?.reason).toBe('collected');
  });

  it('has nothing to say about a refusal with no fields', () => {
    expect(fieldList({ err: 'context' }, {})).toEqual([]);
    expect(fieldList(null, {})).toEqual([]);
  });
});

describe('every fieldError key actually reaches the officer', () => {
  /**
   * The failure this exists for.
   *
   * `fieldList` renders `t('fieldError.<code>')` only for codes on its internal
   * allowlist, and falls back to printing the raw code otherwise. So adding a
   * `fieldError.*` key without adding its code to that list produces a key that
   * is *complete in both locales* — `pnpm i18n:check` passes — and is never
   * reached. The officer reads the bare English identifier in both languages.
   *
   * That is what happened to all 28 codes the M2 records workflow added: a
   * Swedish officer refused for approving their own anmälan read `own_report`.
   * The i18n checker, svelte-check and Playwright all passed, because each was
   * looking at a different half of the pair.
   *
   * Driven through `fieldList` rather than by exporting the allowlist, so it
   * asserts the behaviour rather than the implementation.
   */
  // `en.fieldError` is flat, but `en` as a whole is not: `shell.module.records`
  // is three levels deep, so a `Record<string, Record<string, string>>` cast
  // over the whole file does not typecheck. Narrow to the one branch instead,
  // which is also the branch that has to stay flat for `t()` to reach it.
  const codes = Object.keys(en.fieldError as Record<string, string>);

  it('has at least the codes the M2 records workflow answers with', () => {
    // A floor, so the test fails if the keys are deleted rather than silently
    // passing over an empty set.
    expect(codes).toContain('own_report');
    expect(codes.length).toBeGreaterThan(40);
  });

  it.each(codes)('translates %s rather than falling through to the raw code', (code) => {
    const [message] = fieldList({ err: 'invalid', fields: { field: code } }, {});

    // Equality with the translation is the whole contract. A "must not equal
    // the code" assertion would be a tempting proxy and is wrong: a couple of
    // pre-existing English strings legitimately *are* the word (`unknown`),
    // and failing on those would say the guard works when it only nags.
    //
    // This still catches the real bug. Drop a code from the allowlist and
    // `fieldList` answers the bare identifier while `t()` answers the
    // sentence, so the two stop matching.
    expect(message?.reason).toBe(t(`fieldError.${code}`));
  });
});
