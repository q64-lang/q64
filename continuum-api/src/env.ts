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
};

export function adminEmails(env: Env): Set<string> {
  return new Set(
    env.ADMIN_EMAILS.split(",")
      .map((e) => e.trim().toLowerCase())
      .filter(Boolean),
  );
}
