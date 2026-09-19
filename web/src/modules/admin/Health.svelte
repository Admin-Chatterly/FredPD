<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import type { ErrorCode } from '@fredpd/schema';

  /**
   * System health (spec 7.30, ADR-013).
   *
   * Counters, and only counters. 7.30's full health screen — gateway status,
   * database latency, route timings, queue depths — is `[S]` and lands in M7;
   * nothing in the tree computes any of those four today, so nothing here
   * claims to show them. What `admin.health` returns is what the server already
   * holds in memory plus one aggregate over the Discord snapshot table.
   *
   * The forensics block is the reason this screen exists at all. ADR-013 gives
   * two routes to every connected player with no permission in front of them,
   * and one of them destroys evidence. Destruction writes no audit row, because
   * a caller with no session has no `discordId` to attribute one to, so the
   * grid's `destroyed` counter is the only mark the act leaves anywhere on the
   * server — and a counter nobody can read is not a signal. This is the reader.
   *
   * **Totals only.** The route returns no trace, no player and no owner, and
   * this screen must never grow a control that asks for one: a count of what is
   * lying in the world tells an operator the grid is filling up, while a list of
   * it would tell anyone who opened this tab where the evidence is (spec 8.11).
   */

  interface Health {
    version: string;
    env: string;
    routes: number;
    sessions: { open: number; stale: number; readOnly: number };
    discord: { enabled: boolean; snapshotAgeSeconds: number | null };
    grid: {
      items: number;
      cells: number;
      subscribers: number;
      placed: number;
      merged: number;
      evicted: number;
      refused: number;
      collected: number;
      destroyed: number;
    };
  }

  let health = $state<Health | null>(null);
  let error = $state<ErrorCode | null>(null);
  let loading = $state(true);

  async function load(): Promise<void> {
    loading = true;

    const response = await nui.call<Health>('admin.health');

    if (response.ok) {
      health = response.data;
      error = null;
    } else {
      error = response.err;
    }

    loading = false;
  }

  $effect(() => {
    void load();
  });

  // The grid counters are written out row by row below rather than looped over
  // a list of key names. `pnpm i18n:check` finds a missing translation by
  // reading translate calls with a literal key out of the source, and a key
  // assembled at runtime is one it cannot see — which is how a label ships
  // rendering as its own key in game.
</script>

<section class="flex min-h-0 flex-col gap-4">
  <header>
    <h1 class="text-base font-semibold">{t('admin.health.title')}</h1>
    <p class="mt-1 max-w-prose text-xs text-[var(--color-ink-muted)]">{t('admin.health.intro')}</p>
  </header>

  {#if error}
    <p class="border border-[var(--color-border)] px-3 py-2 text-sm">{t(`error.${error}`)}</p>
  {/if}

  {#if loading}
    <p class="text-sm text-[var(--color-ink-muted)]">{t('app.loading')}</p>
  {:else if health}
    <div class="flex flex-wrap items-start gap-4">
      <table class="border-collapse border border-[var(--color-border)] text-xs">
        <caption class="border-x border-t border-[var(--color-border)] px-3 py-2 text-left font-semibold">
          {t('admin.health.server')}
        </caption>
        <tbody>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">{t('admin.health.version')}</th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.version}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">{t('admin.health.env')}</th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">{health.env}</td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">{t('admin.health.routes')}</th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.routes}
            </td>
          </tr>
        </tbody>
      </table>

      <table class="border-collapse border border-[var(--color-border)] text-xs">
        <caption class="border-x border-t border-[var(--color-border)] px-3 py-2 text-left font-semibold">
          {t('admin.health.sessions')}
        </caption>
        <tbody>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">{t('admin.health.open')}</th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.sessions.open}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">{t('admin.health.stale')}</th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.sessions.stale}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.readOnly')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.sessions.readOnly}
            </td>
          </tr>
        </tbody>
      </table>

      <table class="border-collapse border border-[var(--color-border)] text-xs">
        <caption class="border-x border-t border-[var(--color-border)] px-3 py-2 text-left font-semibold">
          {t('admin.health.discord')}
        </caption>
        <tbody>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">{t('admin.health.sync')}</th>
            <td class="px-3 py-1.5 text-right">
              {health.discord.enabled ? t('admin.health.on') : t('admin.health.off')}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.snapshot')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              <!-- An absent aggregate means the sync has never written a row,
                   which is a different thing from "0 s ago". It arrives as
                   undefined rather than null when the server's MAX() was NULL,
                   so both are tested for. -->
              {typeof health.discord.snapshotAgeSeconds === 'number'
                ? t('admin.health.seconds', { seconds: health.discord.snapshotAgeSeconds })
                : t('admin.health.never')}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="max-w-md">
      <table class="w-full border-collapse border border-[var(--color-border)] text-xs">
        <caption class="border-x border-t border-[var(--color-border)] px-3 py-2 text-left font-semibold">
          {t('admin.health.gridTitle')}
        </caption>
        <tbody>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.items')}
            </th>
            <td class="w-24 px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.items}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.cells')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.cells}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.subscribers')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.subscribers}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.placed')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.placed}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.merged')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.merged}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.collected')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.collected}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.destroyed')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.destroyed}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.evicted')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.evicted}
            </td>
          </tr>
          <tr class="border-t border-[var(--color-border)]">
            <th scope="row" class="px-3 py-1.5 text-left font-normal">
              {t('admin.health.grid.refused')}
            </th>
            <td class="px-3 py-1.5 text-right font-[family-name:var(--font-mono)]">
              {health.grid.refused}
            </td>
          </tr>
        </tbody>
      </table>

      <p class="mt-2 text-xs text-[var(--color-ink-muted)]">{t('admin.health.gridNote')}</p>
    </div>

    <div>
      <button
        type="button"
        class="border border-[var(--color-border)] px-3 py-1.5 text-xs hover:bg-[var(--color-surface)]"
        onclick={() => void load()}
      >
        {t('admin.health.refresh')}
      </button>
    </div>
  {/if}
</section>
