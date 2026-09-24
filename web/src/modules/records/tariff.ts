import { t } from '../../lib/i18n';

/** One current tariff line (spec 7.11, 0036). */
export interface Tariff {
  id: number;
  code: string;
  labelKey: string;
  /** A line the agency wrote itself is named in its own words. */
  label?: string | null;
  amount: number;
  licencePoints?: number;
  version: number;
}

/** What a tariff line is called: its own label, or the shipped locale key. */
export function tariffName(tariff: Pick<Tariff, 'label' | 'labelKey'>): string {
  return tariff.label ?? t(tariff.labelKey);
}

/** A licence's standing (ADR-018), as the server computed it. */
export interface LicenceStanding {
  points: number;
  threshold: number;
  standing: 'valid' | 'warning' | 'revoked';
}
