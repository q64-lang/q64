import { Hono } from "hono";
import type { Env } from "../env.ts";
import { upsertUserByEmail } from "../lib/users.ts";
import { issueToken } from "../lib/tokens.ts";

// =============================================================================
// BYPASS — DELETE WHEN OAUTH LANDS.
// Single hardcoded credential pair until GitHub/Google OAuth apps are wired.
// =============================================================================
const BYPASS_EMAIL = "***";
const BYPASS_PASSWORD = "***";
// =============================================================================

export const auth = new Hono<{ Bindings: Env }>();

// POST /v1/auth/token
// Body: { email, password, description? }
// Returns: { token, id, expires_at, user: { id, username, email } }
// Token is shown once; the CLI stores it locally in ~/.qube/credentials.toml.
auth.post("/token", async (c) => {
  let body: { email?: string; password?: string; description?: string };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ code: "AUT400", message: "expected JSON body" }, 400);
  }
  const email = (body.email ?? "").trim().toLowerCase();
  const password = body.password ?? "";

  if (email !== BYPASS_EMAIL || password !== BYPASS_PASSWORD) {
    return c.json({ code: "AUT401", message: "invalid credentials" }, 401);
  }

  const user = await upsertUserByEmail(c.env.DB, email);
  const issued = await issueToken(c.env.DB, user.id, body.description);

  return c.json({
    token: issued.token,
    id: issued.id,
    expires_at: issued.expires_at,
    user: {
      id: user.id,
      username: user.username,
      email: user.email,
    },
  }, 201);
});
