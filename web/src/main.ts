import { mount } from 'svelte';

import App from './App.svelte';
import './app.css';
import { isLocale, setLocale } from './lib/i18n';
import { nui } from './lib/nui';

/**
 * NUI entry point.
 *
 * In game the shell is hidden until the client opens it. In a browser the mock
 * bridge opens it immediately, so `pnpm dev:web` shows the real interface with
 * no game server attached.
 */

const root = document.getElementById('app');
if (!root) throw new Error('#app is missing from index.html');

// `?locale=sv` switches language in the browser; in game the client sends the
// server's configured locale with the open message.
const requested = new URLSearchParams(window.location.search).get('locale');
if (requested !== null && isLocale(requested)) setLocale(requested);

if (nui.isMock) {
  // Give the standalone page a backdrop and the night theme the MDC defaults to.
  document.body.dataset['standalone'] = 'true';
  document.documentElement.dataset['theme'] = 'night';
}

root.hidden = !nui.isMock;

nui.on('fredpd:open', () => {
  root.hidden = false;
});

nui.on('fredpd:close', () => {
  root.hidden = true;
});

// Escape asks the client to close, so focus and visibility change in one place.
window.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') void nui.call('fredpd:close');
});

mount(App, { target: root });
