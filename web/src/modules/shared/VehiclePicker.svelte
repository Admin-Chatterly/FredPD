<script lang="ts">
  import EntityPicker from './EntityPicker.svelte';
  import { t } from '../../lib/i18n';
  import { searchVehicleOptions, vehicleDetail, vehicleLabel } from './pickers';

  /**
   * Picks a vehicle from the register by plate, for any form that used to
   * ask for a vehicle's internal id. `value` is that id as a string, empty
   * for none. `initialLabel` names a vehicle handed over from another screen.
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
  placeholder={t('picker.vehicle.placeholder')}
  search={searchVehicleOptions}
  label={vehicleLabel}
  detail={vehicleDetail}
  getKey={(vehicle) => vehicle.id}
  selectedLabel={shown}
  {disabled}
  {labelledby}
  {required}
  onSelect={(vehicle) => {
    value = String(vehicle.id);
    chosen = { value: value, label: vehicleLabel(vehicle) };
  }}
  onClear={() => {
    value = '';
    chosen = null;
  }}
/>
