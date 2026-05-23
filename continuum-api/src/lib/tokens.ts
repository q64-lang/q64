import { newId } from "./users.ts";

const TOKEN_PREFIX = "qube_pat_";

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export type IssuedToken = {
  token: string;       // raw bearer — returned to caller ONCE
  id: string;          // 'tok_...'
  expires_at: string;  // ISO8601
};

export async function issueToken(
  db: D1Database,
  userId: string,
  description?: string,
  scopes: string = "publish",
  ttlSeconds: number = 60 * 60 * 24 * 90, // 90 days default
): Promise<IssuedToken> {
  const random = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const token = TOKEN_PREFIX + random;
  const hash = await sha256Hex(token);
  const id = newId("tok_");
  const now = new Date();
  const expires = new Date(now.getTime() + ttlSeconds * 1000);

  await db.prepare(
    `INSERT INTO tokens (id, user_id, hash, scopes, description, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  ).bind(id, userId, hash, scopes, description ?? null, now.toISOString(), expires.toISOString()).run();

  return { token, id, expires_at: expires.toISOString() };
}

// Look up the user for a bearer token. Used by the publish endpoint (future).
export async function verifyToken(
  db: D1Database,
  bearer: string,
): Promise<{ user_id: string; scopes: string } | null> {
  if (!bearer.startsWith(TOKEN_PREFIX)) return null;
  const hash = await sha256Hex(bearer);
  const row = await db.prepare(
    `SELECT user_id, scopes, expires_at, revoked_at
     FROM tokens WHERE hash = ?`,
  ).bind(hash).first<{
    user_id: string;
    scopes: string;
    expires_at: string | null;
    revoked_at: string | null;
  }>();
  if (!row) return null;
  if (row.revoked_at) return null;
  if (row.expires_at && new Date(row.expires_at) < new Date()) return null;
  // best-effort last_used_at update
  await db.prepare(
    `UPDATE tokens SET last_used_at = ? WHERE hash = ?`,
  ).bind(new Date().toISOString(), hash).run();
  return { user_id: row.user_id, scopes: row.scopes };
}
