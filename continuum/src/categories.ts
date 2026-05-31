// Closed-vocabulary category list for the Continuum.
// v0 — intentionally Q64-shaped, not a generic taxonomy.
// Grows by spec edit + migration; never via user submission.

export const CATEGORIES = [
  "ai",
  "agents",
  "audio",
  "video",
  "multimedia",
  "network",
  "web",
  "rpc",
  "streams",
  "dev-tools",
  "system",
  "embedded",
  "wasm",
  "data",
  "parsing",
  "crypto",
  "ui",
  "games",
  "math",
  "science",
] as const;

export type Category = (typeof CATEGORIES)[number];

export function isCategory(s: string): s is Category {
  return (CATEGORIES as readonly string[]).includes(s);
}
