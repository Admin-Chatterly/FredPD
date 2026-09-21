<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '../../lib/i18n';
  import { fieldList, type Failure } from './failure';

  /**
   * The confirmation a legal action asks for (spec 6.4).
   *
   * Every screen in this module had its own copy of this box, and each copy had
   * the same three holes. They are worth naming, because two of them are the
   * kind that only show up with a keyboard and the third only shows up when the
   * server says no:
   *
   *   * **`aria-modal` without a focus trap is a lie.** Tab from the last
   *     button and focus lands on the page behind — and once it is there,
   *     Escape is no longer caught by the dialog. `main.ts` listens for Escape
   *     on `window` and asks the client to close the NUI, so in game the whole
   *     MDT shut with a revocation dialog still open on screen. The trap below
   *     is what makes the `aria-modal` true.
   *   * **Focusing a bare `div` is invisible.** `tabindex="-1"` takes focus but
   *     draws nothing, so a keyboard officer pressing the button saw no change
   *     at all. Focus goes to the heading, and the box carries a visible ring
   *     in `--color-focus` — a token 6.2 defines and nothing was using.
   *   * **Closing before the server answers throws the officer's work away.**
   *     A stale `version` is the likeliest refusal of all here, because the
   *     version came from a list that was loaded before the dialog opened. The
   *     dialog stays up until the call succeeds, and a refusal is drawn *in*
   *     it, beside the field the server named.
   *
   * The caller owns the action and the state; this owns the box, the focus and
   * the refusal.
   */

  interface Props {
    /** The verb, as 6.4 wants it on the button and on the heading. */
    label: string;
    /** The sentence explaining what is about to happen. */
    question: string;
    busy?: boolean;
    /** Drawn inside the dialog, so a refusal lands where the officer is looking. */
    failure?: Failure | null;
    /** Field name to locale key, for the refusal's field list (3.5). */
    fieldLabels?: Record<string, string>;
    confirm: () => void;
    cancel: () => void;
    /** The form controls this dialog asks for, above the buttons (6.4). */
    children?: Snippet;
  }

  let {
    label,
    question,
    busy = false,
    failure = null,
    fieldLabels = {},
    confirm,
    cancel,
    children,
  }: Props = $props();

  let box = $state<HTMLDivElement | null>(null);
  let heading = $state<HTMLHeadingElement | null>(null);

  const messages = $derived(fieldList(failure ?? null, fieldLabels));

  /** Focus starts on the heading, so what opened is announced and visible. */
  $effect(() => {
    heading?.focus();
  });

  /** Everything inside the box a keyboard can reach, in document order. */
  function focusable(): HTMLElement[] {
    if (!box) return [];

    return [
      ...box.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    ];
  }

  function onKeydown(event: KeyboardEvent): void {
    if (event.key === 'Escape') {
      // Stopped here, or `main.ts` closes the whole interface.
      event.stopPropagation();
      event.preventDefault();
      cancel();

      return;
    }

    if (event.key !== 'Tab') return;

    const items = focusable();
    if (items.length === 0) return;

    const first = items[0];
    const last = items[items.length - 1];

    // The trap. Wrapping at both ends is what keeps Escape inside the dialog,
    // which is the whole reason it matters here rather than being a nicety.
    if (event.shiftKey && (document.activeElement === first || document.activeElement === box)) {
      event.preventDefault();
      last?.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first?.focus();
    }
  }
</script>

<!--
  `tabindex="-1"` on the box itself is load-bearing rather than decorative: the
  box is what catches Tab and Escape, and a shift-Tab from the first control
  lands on it before the trap wraps. Focus moves to the heading on open, which
  is where it is visible.
-->
<div
  bind:this={box}
  role="dialog"
  aria-modal="true"
  aria-label={label}
  tabindex="-1"
  class="max-w-xl border border-[var(--color-focus)] px-3 py-2 text-xs"
  onkeydown={onKeydown}
>
  <h3
    bind:this={heading}
    tabindex="-1"
    class="mb-1 font-semibold outline-offset-2 focus-visible:outline focus-visible:outline-[var(--color-focus)]"
  >
    {label}
  </h3>

  <p>{question}</p>

  {#if failure}
    <!--
      In the dialog, not in the banner at the top of a screen the officer is
      no longer looking at. A `conflict` here means somebody else moved the
      record while this box was open, and that is a sentence worth reading
      before the ground they chose is discarded.
    -->
    <div class="mt-2 border border-[var(--color-alert)] px-2 py-1" role="alert">
      <p>{t(`error.${failure.err}`)}</p>
      {#if messages.length > 0}
        <ul class="mt-1 text-[var(--color-ink-muted)]">
          {#each messages as message (message.name)}
            <li>{message.label} — {message.reason}</li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}

  {@render children?.()}

  <div class="mt-2 flex gap-2">
    <button
      type="button"
      class="border border-[var(--color-border)] px-3 py-1"
      disabled={busy}
      onclick={confirm}
    >
      {label}
    </button>
    <button type="button" class="border border-[var(--color-border)] px-3 py-1" onclick={cancel}>
      {t('form.cancel')}
    </button>
  </div>
</div>
