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
      eqeqeq: ['error', 'always'],
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
