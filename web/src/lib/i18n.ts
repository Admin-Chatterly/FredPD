import en from '@locales/en.json';
import sv from '@locales/sv.json';

/**
 * Locale handling for the NUI (spec 5).
 *
 * The JSON comes from the resource's own `locales/` folder, so the game and the
 * NUI can never drift apart: there is one set of files and `pnpm i18n:check`
 * holds `en` and `sv` to the same keys.
 *
 * Invariant 6: no user-facing string is written in a component. The ESLint rule
 * `fredpd/no-literal-text` fails the build if one is.
 */

export const SUPPORTED_LOCALES = ['en', 'sv'] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];

const FALLBACK: Locale = 'en';

type LocaleTree = { [key: string]: string | LocaleTree };

/** `{ a: { b: 'x' } }` becomes `{ 'a.b': 'x' }`, matching the Lua loader. */
function flatten(tree: LocaleTree, prefix = ''): Record<string, string> {
  const out: Record<string, string> = {};

  for (const [key, value] of Object.entries(tree)) {
    const path = prefix ? `${prefix}.${key}` : key;

    if (typeof value === 'string') {
      out[path] = value;
    } else {
      Object.assign(out, flatten(value, path));
    }
  }

  return out;
}

const tables: Record<Locale, Record<string, string>> = {
  en: flatten(en as LocaleTree),
  sv: flatten(sv as LocaleTree),
};

export function isLocale(value: string): value is Locale {
  return (SUPPORTED_LOCALES as readonly string[]).includes(value);
}

let current: Locale = FALLBACK;

export function setLocale(locale: Locale): void {
  current = locale;
  document.documentElement.lang = locale;
}

export function getLocale(): Locale {
  return current;
}

/**
 * Translates `key`, substituting `{name}` placeholders.
 *
 * An unknown key renders as the key itself rather than as an empty string, so a
 * gap is visible in a screenshot instead of silently disappearing.
 */
export function t(key: string, params?: Record<string, string | number>): string {
  const template = tables[current][key] ?? tables[FALLBACK][key] ?? key;

  if (!params) return template;

  return template.replace(/\{(\w+)\}/g, (match, name: string) =>
    name in params ? String(params[name]) : match,
  );
}
