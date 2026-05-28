export type DbUser = {
  id: string;
  username: string;
  email: string;
  avatar_url: string | null;
  status: string;
};

export function newId(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return prefix + btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

// BYPASS — upsert by email only. Replace with upsert-by-(provider, provider_id)
// when OAuth lands. Bypass users get status='approved' so they can publish
// immediately for testing.
export async function upsertUserByEmail(
  db: D1Database,
  email: string,
): Promise<DbUser> {
  const lower = email.toLowerCase();
  const existing = await db.prepare(
    `SELECT id, username, email, avatar_url, status FROM users WHERE email = ?`,
  ).bind(lower).first<DbUser>();
  if (existing) return existing;

  const id = newId("usr_");
  const username = lower.split("@")[0];
  await db.prepare(
    `INSERT INTO users (id, provider, provider_id, username, email, avatar_url, created_at, status)
     VALUES (?, 'bypass', ?, ?, ?, NULL, ?, 'approved')`,
  ).bind(id, lower, username, lower, new Date().toISOString()).run();

  return { id, username, email: lower, avatar_url: null, status: "approved" };
}
