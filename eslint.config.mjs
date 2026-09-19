import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import svelte from 'eslint-plugin-svelte';
import svelteParser from 'svelte-eslint-parser';

import fredpd from './tools/eslint/no-literal-text.js';

export default tseslint.config(
  {
    // Vendored and generated code is not ours to lint.
    ignores: [
      '**/node_modules/**',
      '**/dist/**',
      '**/build/**',
      '**/.svelte-kit/**',
      'vendor/**',
      'packages/schema/generated/**',
      'resources/**/web/dist/**',
      'playwright-report/**',
      'test-results/**',
    ],
  },

  js.configs.recommended,
  ...tseslint.configs.recommended,

  {
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'module',
      globals: { ...globals.node },
    },
    rules: {
      // `== null` is allowed, and everything else still needs `===`.
      //
      // This is not a style preference, it is a bug class. A SQL NULL comes back
      // from oxmysql as Lua `nil`, a nil field is simply absent from the row
      // table, and the client JSON-encodes that table -- so a nullable column
      // reaches the NUI as `undefined`, never as `null`. Under `always`, the
      // only spelling the linter permitted for "is this empty" was `=== null`,
      // which is false for every one of those fields.
      //
      // It had shipped three times before anyone noticed: every living person's
      // edit form opened with "deceased" ticked and "missing" ticked, because
      // `person.deceasedAt !== null` is true when the key is absent.
      // `== null` is the one comparison that means "null or undefined", which is
      // the question these checks are actually asking.
      eqeqeq: ['error', 'always', { null: 'ignore' }],
      'no-console': ['warn', { allow: ['warn', 'error'] }],
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      '@typescript-eslint/consistent-type-imports': 'error',
    },
  },

  // The NUI runs in a browser, not in Node.
  {
    files: ['web/**/*.{ts,js,svelte}'],
    languageOptions: {
      globals: { ...globals.browser },
    },
  },

  ...svelte.configs.recommended,

  {
    files: ['**/*.svelte'],
    languageOptions: {
      parser: svelteParser,
      parserOptions: {
        parser: tseslint.parser,
        extraFileExtensions: ['.svelte'],
      },
      globals: { ...globals.browser },
    },
    plugins: { fredpd },
    rules: {
      // Invariant 6: every user-facing string goes through a locale key.
      'fredpd/no-literal-text': 'error',
    },
  },

  // Config files and tooling are developer-facing: logging and literals are fine.
  {
    files: [
      '**/*.config.{ts,js,mjs}',
      'tools/**/*.{ts,js,mjs}',
      'packages/schema/src/generate.ts',
      '**/*.spec.ts',
      '**/*.test.ts',
    ],
    rules: {
      'no-console': 'off',
    },
  },
);
