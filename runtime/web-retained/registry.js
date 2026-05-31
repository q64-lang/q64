// Widget draw registry — the shared registration surface for the retained host.
// Widget impls live in widgets/<kind>.js and call register() at import time.
// This file holds ONLY the registry + shared theme; it is not edited per-widget.
const registry = new Map();
export function register(kind, impl) {
  if (registry.has(kind)) console.warn(`[qview] kind ${kind} registered twice`);
  registry.set(kind, impl);
}
export function widgetFor(kind) { return registry.get(kind); }

// Shared palette so widgets look consistent. One place to tune.
export const THEME = {
  fg:          [0.90, 0.95, 1.00, 1],
  muted:       [0.62, 0.69, 0.78, 1],
  surface:     [0.10, 0.13, 0.18, 1],
  accent:      [0.37, 0.83, 1.00, 1],
  accentDim:   [0.20, 0.55, 0.75, 1],
  border:      [0.16, 0.45, 0.62, 1],
  track:       [0.18, 0.22, 0.28, 1],
  inkOnAccent: [0.03, 0.05, 0.08, 1],
};
