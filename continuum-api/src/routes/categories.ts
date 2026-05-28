import { Hono } from "hono";
import type { Env } from "../env.ts";

export const categories = new Hono<{ Bindings: Env }>();

// GET /v1/categories/counts — { slug: count } for every category that has ≥1 qube.
// Categories with 0 qubes are simply absent from the map.
categories.get("/counts", async (c) => {
  // `categories` is space-joined in the qubes table (denormalized for FTS5).
  // For v0 we just scan the rows; population is small enough for SQLite.
  const { results } = await c.env.DB.prepare(
    `SELECT categories FROM qubes WHERE categories <> ''`,
  ).all<{ categories: string }>();

  const counts: Record<string, number> = {};
  for (const row of results) {
    for (const slug of row.categories.split(/\s+/).filter(Boolean)) {
      counts[slug] = (counts[slug] ?? 0) + 1;
    }
  }
  return c.json({ counts });
});
