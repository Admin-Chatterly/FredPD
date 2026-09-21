/**
 * The virus-scan hook (spec 9's "generation pipeline" and 11's "no unscanned
 * file reaches storage a signed URL can serve").
 *
 * Pluggable rather than a single implementation, because there is no
 * scanning binary to integrate against in every environment this repository
 * runs in -- CI included -- and a hook that only worked where ClamAV happened
 * to be installed would be untestable everywhere else. `NoopScanner` is the
 * shipped default and is not a stand-in for a real scanner: it is what a
 * fresh install runs until an operator configures one, and it says so in its
 * own result rather than silently answering "clean" the way a stub with no
 * opinion would.
 *
 * A real deployment supplies a `Scanner` that shells out to `clamdscan` or
 * calls a scanning API, and nothing above `scanUpload` in the route needs to
 * change.
 */

export interface ScanResult {
  clean: boolean;
  /** Locale-key-shaped where possible, so a refusal can be translated later. */
  reason?: string;
}

export type Scanner = (filePath: string) => Promise<ScanResult>;

/**
 * Always reports clean, and says so on every call rather than pretending to
 * have scanned anything. A deployment that has not configured a real scanner
 * is a deployment an administrator can see is running one, in the gateway's
 * own logs -- not a silent gap.
 */
export const noopScanner: Scanner = async () => ({ clean: true, reason: 'not_configured' });
