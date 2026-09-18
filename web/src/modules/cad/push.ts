import { nui } from '../../lib/nui';
import type { NuiMessage } from '../../lib/nui';

/**
 * How the console subscribes to the live pushes the CAD routes send (spec 3.6).
 *
 * In game this is `nui.on` and nothing else: the real bridge already receives a
 * push as a CEF `window` message and fans it out to its own handlers, so the
 * relay below is never installed and the game path is byte for byte what it was.
 *
 * The relay exists because of what the mock bridge could *not* do. It has an
 * `emit`, but it is private to the closure and only ever fires `fredpd:open`,
 * so no fixture and no test could raise a `fredpd:cad:*` message — and half of
 * this module is push-driven. The officer-down banner, the welfare prompt, the
 * live queue merge, the AVL trail and the broadcast board had therefore never
 * been rendered in `pnpm dev:web` and no Playwright test could reach any of
 * them. That is how a banner shipped whose only actionable button was
 * guaranteed to be refused for most of the officers it was pushed to: nothing
 * had ever drawn it outside the game.
 *
 * So in mock mode a CAD subscription also listens for the same message on
 * `window`, which is the shape the real transport uses anyway. `fixtures.ts`
 * pushes through it (press the emergency button on the unit board and the
 * banner arrives, as it would in game), and a test — or anybody poking at
 * `pnpm dev:web` from the devtools console — can post one:
 *
 *     window.postMessage({ type: 'fredpd:cad:emergency', call, callsign: '3A-12',
 *                          mayAcknowledge: true })
 *
 * It is deliberately not a general `nui` capability: the bridge interface is
 * the contract every module shares, and widening it for the convenience of one
 * module's tests is how a mock stops resembling the thing it mocks.
 */
export function onPush(type: string, handler: (message: NuiMessage) => void): () => void {
  const off = nui.on(type, handler);
  if (!nui.isMock) return off;

  const relay = (event: MessageEvent<unknown>): void => {
    const message = event.data;

    // Anything at all can postMessage to a page — a dev-server client, an
    // extension, an embedded frame — so the shape is checked rather than
    // assumed, and only the one type this subscription asked for is delivered.
    if (typeof message !== 'object' || message === null) return;
    if ((message as NuiMessage).type !== type) return;

    handler(message as NuiMessage);
  };

  window.addEventListener('message', relay);

  return () => {
    off();
    window.removeEventListener('message', relay);
  };
}
