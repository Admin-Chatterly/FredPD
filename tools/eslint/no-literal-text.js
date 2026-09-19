/**
 * Enforces invariant 6: no hardcoded user-facing text.
 *
 * Flags literal text in Svelte markup and literal values of the attributes a
 * user actually reads. Everything visible must come from a locale key, so the
 * fix is always the same shape: `{t('some.key')}` instead of the bare string.
 *
 * Text that carries no message on its own -- whitespace, digits, punctuation,
 * a lone separator -- is allowed, as is anything inside <style> and <script>.
 */

/** Attributes whose value is rendered to the player. */
const USER_FACING_ATTRIBUTES = new Set([
  'alt',
  'aria-description',
  'aria-label',
  'aria-placeholder',
  'aria-roledescription',
  'aria-valuetext',
  'label',
  'placeholder',
  'title',
]);

/** Elements whose text content is code or styling, not prose. */
const NON_PROSE_ELEMENTS = new Set(['script', 'style', 'template']);

/**
 * True when the string carries no translatable message: whitespace, digits,
 * punctuation and symbols only. `12`, `-`, `/` and `()` stay legal.
 */
function isNonProse(value) {
  return !/\p{Letter}/u.test(value);
}

function elementName(node) {
  const name = node?.name;
  if (!name) return undefined;
  return typeof name.name === 'string' ? name.name.toLowerCase() : undefined;
}

/** True when the node sits inside <script>, <style> or <template>. */
function insideNonProseElement(node) {
  for (let current = node.parent; current; current = current.parent) {
    if (current.type === 'SvelteScriptElement' || current.type === 'SvelteStyleElement') {
      return true;
    }
    if (current.type === 'SvelteElement' && NON_PROSE_ELEMENTS.has(elementName(current) ?? '')) {
      return true;
    }
  }
  return false;
}

/** @type {import('eslint').Rule.RuleModule} */
export const noLiteralText = {
  meta: {
    type: 'problem',
    docs: {
      description: 'Disallow hardcoded user-facing text in Svelte markup (invariant 6)',
    },
    schema: [],
    messages: {
      literalText:
        'Hardcoded user-facing text "{{text}}". Use a locale key instead, e.g. {t(\'module.key\')} (spec 5, invariant 6).',
      literalAttribute:
        'Hardcoded text in the user-facing attribute "{{name}}". Use a locale key instead (spec 5, invariant 6).',
    },
  },

  create(context) {
    return {
      SvelteText(node) {
        const text = node.value;
        if (isNonProse(text) || insideNonProseElement(node)) return;

        context.report({
          node,
          messageId: 'literalText',
          data: { text: text.trim().slice(0, 40) },
        });
      },

      SvelteAttribute(node) {
        const name = node.key?.name;
        if (typeof name !== 'string' || !USER_FACING_ATTRIBUTES.has(name.toLowerCase())) return;

        const values = Array.isArray(node.value) ? node.value : [];
        const hasProseLiteral = values.some(
          (value) => value.type === 'SvelteLiteral' && !isNonProse(value.value),
        );
        if (!hasProseLiteral) return;

        context.report({ node, messageId: 'literalAttribute', data: { name } });
      },
    };
  },
};

export default {
  rules: {
    'no-literal-text': noLiteralText,
  },
};
