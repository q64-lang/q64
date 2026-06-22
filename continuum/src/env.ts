export type Env = {
  API: Fetcher;
  ENV: "dev" | "prod";
  // Public host of the registry API (browser-facing archive / .wit links). Must
  // match the env the UI is serving — stage UI → stage API — or those links 404.
  // Set per-env in wrangler.jsonc vars; defaults to prod.
  REGISTRY_HOST?: string;
};
