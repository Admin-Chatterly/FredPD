<script lang="ts">
  import EntityPicker from './EntityPicker.svelte';
  import { t } from '../../lib/i18n';
  import { personDetail, personLabel, searchPersonOptions } from './pickers';

  /**
   * Picks a person from the master name index by name or person number, for
   * any form that used to ask for a person's internal id. `value` is that id
   * as the forms already hold it (a string, empty for none).
   *
   * `initialLabel` names a person handed over from another screen (a query
   * row, a field check), so a pre-filled form says who it is filled with.
   */
  interface Props {
    value: string;
    initialLabel?: string | null;
    disabled?: boolean;
    /** The id of the visible caption naming this field. */
    labelledby?: string | undefined;
    required?: boolean;
  }

  let {
    value = $bindable(''),
    initialLabel = null,
    disabled = false,
    labelledby,
    required = false,
  }: Props = $props();

  /** The label of what was picked here, and for which value. */
  let chosen = $state<{ value: string; label: string } | null>(null);

  // Never the raw id: an id from a different kind of record would read as
  // a choice the officer did not make.
  const shown = $derived(
    value ? (chosen?.value === value ? chosen.label : (initialLabel ?? t('picker.chosen'))) : null,
  );
</script>

<EntityPicker
  placeholder={t('picker.person.placeholder')}
  search={searchPersonOptions}
  label={personLabel}
  detail={personDetail}
  getKey={(person) => person.id}
  selectedLabel={shown}
  {disabled}
  {labelledby}
  {required}
  onSelect={(person) => {
    value = String(person.id);
    chosen = { value: value, label: personLabel(person) };
  }}
  onClear={() => {
    value = '';
    chosen = null;
  }}
/>
