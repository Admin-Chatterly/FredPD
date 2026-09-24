<script lang="ts">
  import { nui } from '../../lib/nui';
  import { t } from '../../lib/i18n';
  import { fieldList, type Failure } from '../shared/failure';
  import type { PopulationPerson, PopulationVehicle } from './types';

  /**
   * The population register under a search (folkbokföringen): citizens and
   * cars the game knows that have no record here yet. The officer's own
   * character is one, until somebody opens it.
   *
   * Opening one asks the server to create the record from the game's own
   * data (`person.fromCharacter`, `vehicle.fromOwned`) and then opens it like
   * any other. The server decides what is offered and re-checks the open.
   */

  interface Props {
    persons?: PopulationPerson[];
    vehicles?: PopulationVehicle[];
    onOpenPerson?: ((id: number) => void) | undefined;
    onOpenVehicle?: ((id: number) => void) | undefined;
  }

  let { persons = [], vehicles = [], onOpenPerson, onOpenVehicle }: Props = $props();
  const uid = $props.id();
  const titleId = `population-${uid}`;

  let busy = $state(false);
  let failure = $state<Failure | null>(null);
  const messages = $derived(fieldList(failure, { ref: 'records.population.person' }));

  function name(person: PopulationPerson): string {
    return [person.firstName, person.lastName].filter(Boolean).join(' ') || t('records.population.noName');
  }

  async function openPerson(person: PopulationPerson): Promise<void> {
    if (busy) return;
    busy = true;
    const response = await nui.call<{ id: number }>('person.fromCharacter', { ref: person.ref });
    busy = false;

    if (!response.ok) {
      failure = response;
      return;
    }
    failure = null;
    onOpenPerson?.(response.data.id);
  }

  async function openVehicle(vehicle: PopulationVehicle): Promise<void> {
    if (busy) return;
    busy = true;
    const response = await nui.call<{ id: number }>('vehicle.fromOwned', { ref: vehicle.ref });
    busy = false;

    if (!response.ok) {
      failure = response;
      return;
    }
    failure = null;
    onOpenVehicle?.(response.data.id);
  }

  const button =
    'border border-[var(--color-border)] px-2 py-0.5 hover:bg-[var(--color-surface)] focus-visible:outline-2 focus-visible:outline-[var(--color-focus)] aria-disabled:opacity-60';
</script>

{#if persons.length > 0 || vehicles.length > 0}
  <section class="border border-[var(--color-border)] px-3 py-2 text-xs" aria-labelledby={titleId}>
    <h3 id={titleId} class="font-semibold">{t('records.population.title')}</h3>
    <p class="mt-0.5 text-[var(--color-ink-muted)]">{t('records.population.hint')}</p>

    {#if failure}
      <div class="mt-2 border border-[var(--color-alert)] px-2 py-1" role="alert">
        <p>{t(`error.${failure.err}`)}</p>
        {#each messages as message (message.name)}
          <p class="text-[var(--color-ink-muted)]">{message.label} — {message.reason}</p>
        {/each}
      </div>
    {/if}

    <ul class="mt-1">
      {#each persons as person (person.ref)}
        <li class="flex items-center justify-between gap-3 border-t border-[var(--color-border)] py-1 first:border-t-0">
          <span>
            {name(person)}
            {#if person.dateOfBirth}
              <span class="ml-2 font-[family-name:var(--font-mono)] text-[var(--color-ink-muted)]">{person.dateOfBirth}</span>
            {/if}
          </span>
          <button
            type="button"
            class={button}
            aria-disabled={busy}
            aria-label={t('records.population.openLabel', { name: name(person) })}
            onclick={() => void openPerson(person)}
          >
            {t('records.population.open')}
          </button>
        </li>
      {/each}
      {#each vehicles as vehicle (vehicle.ref)}
        <li class="flex items-center justify-between gap-3 border-t border-[var(--color-border)] py-1 first:border-t-0">
          <span class="font-[family-name:var(--font-mono)]">{vehicle.plate}</span>
          <button
            type="button"
            class={button}
            aria-disabled={busy}
            aria-label={t('records.population.openLabel', { name: vehicle.plate })}
            onclick={() => void openVehicle(vehicle)}
          >
            {t('records.population.open')}
          </button>
        </li>
      {/each}
    </ul>
  </section>
{/if}
