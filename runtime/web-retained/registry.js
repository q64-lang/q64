// Widget draw registry — the shared registration surface for the retained host.
// Widget impls live in widgets/<kind>.js and call register() at import time.
// This file holds ONLY the registry + shared theme; it is not edited per-widget.
const registry = new Map();
export function register(kind, impl) {
  if (registry.has(kind)) console.warn(`[qview] kind ${kind} registered twice`);
  registry.set(kind, impl);
}
export function widgetFor(kind) { return registry.get(kind); }

// The theme is per-platform and lives in theme.js (the single source of truth).
// Widgets never import a palette directly — they read `r.theme` from the render
// context, which the host sets to the resolved platform's tokens. This re-export
// is a back-compat default (desktop) for any non-context consumer.
export { THEME } from './theme.js';
