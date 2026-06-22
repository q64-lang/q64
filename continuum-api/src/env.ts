export type Env = {
  DB: D1Database;
  ARCHIVES: R2Bucket;
  CACHE: KVNamespace;

  ENV: "dev" | "prod";
  ADMIN_EMAILS: string;

  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  SESSION_SECRET: string;

  // Pre-OAuth dev bypass: a single email/password pair that issues a publish
  // token. Disabled unless BOTH are set per-deploy (no defaults in the source
  // or in wrangler.example.jsonc). Delete the bypass route when OAuth lands.
  BYPASS_EMAIL?: string;
  BYPASS_PASSWORD?: string;

  // Taluvi tracing (shared observability). Inert unless BOTH the endpoint and
  // the per-project ingest token are set — so it "logs in" to the platform with
  // its own credential and emits OTLP spans under app `q64-continuum`. See
  // src/lib/tracing (vendored @taluvi/tracing) + tracing/CLAUDE.md.
  TRACING_OTLP_ENDPOINT?: string;
  TRACING_TENANT_ID?: string;
  TRACING_INGEST_TOKEN?: string;
  SERVICE_NAME?: string;
};

export function adminEmails(env: Env): Set<string> {
  return new Set(
    env.ADMIN_EMAILS.split(",")
      .map((e) => e.trim().toLowerCase())
      .filter(Boolean),
  );
}
