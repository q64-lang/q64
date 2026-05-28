import { Hono } from "hono";
import JSON5 from "json5";
import type { Env } from "../env.ts";
import { verifyToken } from "../lib/tokens.ts";

export const qubes = new Hono<{ Bindings: Env }>();

// POST /v1/qubes/:name — publish a new version.
// Auth: Bearer token. Body: multipart with `manifest` (text) + `archive` (zip).
qubes.post("/:name", async (c) => {
  const urlName = decodeURIComponent(c.req.param("name"));

  const authHeader = c.req.header("authorization") ?? "";
  const bearer = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  if (!bearer) return c.json({ code: "AUT401", message: "missing bearer token" }, 401);
  const token = await verifyToken(c.env.DB, bearer);
  if (!token) return c.json({ code: "AUT401", message: "invalid or expired token" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await c.req.parseBody();
  } catch {
    return c.json({ code: "PUB400", message: "expected multipart/form-data" }, 400);
  }
  const manifestText = typeof body.manifest === "string" ? body.manifest : "";
  const archiveBlob = body.archive;
  if (!manifestText || !(archiveBlob instanceof Blob)) {
    return c.json({ code: "PUB400", message: "fields 'manifest' (text) and 'archive' (file) required" }, 400);
  }

  let manifest: Record<string, unknown>;
  try {
    manifest = JSON5.parse(manifestText);
  } catch (e) {
    return c.json({ code: "PUB422", message: `invalid manifest: ${(e as Error).message}` }, 422);
  }

  const manifestName = typeof manifest.name === "string" ? manifest.name : "";
  const version = typeof manifest.version === "string" ? manifest.version : "";
  if (manifestName !== urlName) {
    return c.json(
      { code: "PUB422", message: `manifest name '${manifestName}' does not match URL '${urlName}'` },
      422,
    );
  }
  // Publishable names: reverse-DNS dotted, ≥2 identifier segments, snake_case
  // (spec/qube.json5.md). Enforced here so the registry never stores a name it
  // can't serve as a single URL segment or resolve as a module path.
  if (!PUBLISHABLE_NAME.test(manifestName) || manifestName.length > 128) {
    return c.json(
      { code: "PUB422", message: `invalid qube name '${manifestName}': use a reverse-DNS dotted name with ≥2 lowercase identifier segments, e.g. dev.q64.webmcp_client` },
      422,
    );
  }
  if (manifestName === "q64" || manifestName.startsWith("q64.")) {
    return c.json(
      { code: "PUB422", message: "the 'q64.*' namespace is reserved for the built-in standard library" },
      422,
    );
  }
  if (!version) {
    return c.json({ code: "PUB422", message: "manifest missing version" }, 422);
  }

  const existing = await c.env.DB.prepare(
    `SELECT version FROM versions WHERE qube_name = ? AND version = ?`,
  ).bind(urlName, version).first();
  if (existing) {
    return c.json({ code: "PUB409", message: `${urlName}@${version} already published` }, 409);
  }

  const archiveBytes = new Uint8Array(await archiveBlob.arrayBuffer());
  if (archiveBytes.byteLength > 50 * 1024 * 1024) {
    return c.json({ code: "PUB413", message: "archive exceeds 50 MB v0 limit" }, 413);
  }
  const hashBuf = await crypto.subtle.digest("SHA-256", archiveBytes);
  const sha = Array.from(new Uint8Array(hashBuf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  await c.env.ARCHIVES.put(`archives/${sha}`, archiveBytes, {
    httpMetadata: { contentType: "application/zip" },
  });

  const description = typeof manifest.description === "string" ? manifest.description : null;
  const license = typeof manifest.license === "string" ? manifest.license : null;
  const repository =
    typeof manifest.repository === "string"
      ? manifest.repository
      : manifest.repository && typeof manifest.repository === "object" && "url" in (manifest.repository as Record<string, unknown>)
        ? String((manifest.repository as Record<string, unknown>).url)
        : null;
  const keywords = Array.isArray(manifest.keywords)
    ? (manifest.keywords as unknown[]).filter((k): k is string => typeof k === "string").join(" ")
    : "";
  const categories = Array.isArray(manifest.categories)
    ? (manifest.categories as unknown[]).filter((k): k is string => typeof k === "string").join(" ")
    : "";
  const effects =
    manifest.effects &&
    typeof manifest.effects === "object" &&
    Array.isArray((manifest.effects as Record<string, unknown>).declared)
      ? ((manifest.effects as Record<string, unknown>).declared as unknown[]).filter((e) => typeof e === "string")
      : [];
  const now = new Date().toISOString();

  const qubeRow = await c.env.DB.prepare(
    `SELECT name FROM qubes WHERE name = ?`,
  ).bind(urlName).first();

  if (!qubeRow) {
    await c.env.DB.prepare(
      `INSERT INTO qubes (name, owner_id, description, repository, license, latest, created_at, keywords, categories)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(urlName, token.user_id, description, repository, license, version, now, keywords, categories).run();
  } else {
    await c.env.DB.prepare(
      `UPDATE qubes SET description = ?, repository = ?, license = ?, latest = ?, keywords = ?, categories = ?
       WHERE name = ?`,
    ).bind(description, repository, license, version, keywords, categories, urlName).run();
  }

  await c.env.DB.prepare(
    `INSERT INTO versions (qube_name, version, manifest, archive_sha, archive_size, effects, published_at, yanked, scan_status, published_via)
     VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'pending', 'manual')`,
  ).bind(urlName, version, manifestText, sha, archiveBytes.byteLength, JSON.stringify(effects), now).run();

  return c.json(
    {
      name: urlName,
      version,
      archive_sha: sha,
      archive_size: archiveBytes.byteLength,
      published_at: now,
    },
    201,
  );
});

type QubeRow = {
  name: string;
  description: string | null;
  repository: string | null;
  license: string | null;
  latest: string | null;
  downloads: number;
  recent_downloads: number;
  created_at: string;
};

type VersionRow = {
  version: string;
  manifest: string;
  archive_sha: string;
  archive_size: number;
  effects: string;
  published_at: string;
  yanked: number;
  published_via: string | null;
  provenance: string | null;
};

const QUBE_COLS = `q.name, q.description, q.repository, q.license, q.latest,
                   q.downloads, q.recent_downloads, q.created_at`;

// Publishable qube name: reverse-DNS dotted, ≥2 lowercase identifier segments
// (snake_case, no dashes). Matches spec/qube.json5.schema.json.
const PUBLISHABLE_NAME = /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/;

function parseManifestOrNull(text: string): Record<string, unknown> | null {
  try {
    return JSON5.parse(text);
  } catch {
    return null;
  }
}

function orderClause(sort: string | undefined, hasQuery: boolean): string {
  switch (sort) {
    case "alpha":             return "q.name ASC";
    case "downloads":         return "q.downloads DESC";
    case "recent_downloads":  return "q.recent_downloads DESC";
    case "recent_updates":    return "(SELECT MAX(published_at) FROM versions WHERE qube_name = q.name) DESC";
    case "new":               return "q.created_at DESC";
    case "relevance":
    default:                  return hasQuery ? "bm25(qubes_fts) ASC, q.downloads DESC" : "q.downloads DESC";
  }
}

// GET /v1/qubes — list + search
qubes.get("/", async (c) => {
  const q = c.req.query("q")?.trim();
  const sort = c.req.query("sort");
  const page = Math.max(1, parseInt(c.req.query("page") ?? "1", 10) || 1);
  const limit = Math.min(200, Math.max(1, parseInt(c.req.query("limit") ?? "50", 10) || 50));
  const offset = (page - 1) * limit;

  const order = orderClause(sort, !!q);
  const sql = q
    ? `SELECT ${QUBE_COLS} FROM qubes_fts f JOIN qubes q ON q.rowid = f.rowid
       WHERE qubes_fts MATCH ? ORDER BY ${order} LIMIT ? OFFSET ?`
    : `SELECT ${QUBE_COLS} FROM qubes q ORDER BY ${order} LIMIT ? OFFSET ?`;

  const stmt = q
    ? c.env.DB.prepare(sql).bind(q, limit, offset)
    : c.env.DB.prepare(sql).bind(limit, offset);

  const { results } = await stmt.all<QubeRow>();
  return c.json({ qubes: results, page, limit });
});

// GET /v1/qubes/:name — metadata + version list
qubes.get("/:name", async (c) => {
  const name = decodeURIComponent(c.req.param("name"));
  const qube = await c.env.DB.prepare(
    `SELECT ${QUBE_COLS.replaceAll("q.", "")} FROM qubes WHERE name = ?`,
  ).bind(name).first<QubeRow>();
  if (!qube) return c.json({ code: "QUB404", message: "qube not found" }, 404);

  const { results } = await c.env.DB.prepare(
    `SELECT version, archive_sha, archive_size, effects, published_at, yanked, published_via
     FROM versions WHERE qube_name = ? ORDER BY published_at DESC`,
  ).bind(name).all<Pick<VersionRow, "version" | "archive_sha" | "archive_size" | "effects" | "published_at" | "yanked" | "published_via">>();

  return c.json({
    ...qube,
    versions: results.map((v) => ({
      version: v.version,
      published_at: v.published_at,
      yanked: !!v.yanked,
      effects: JSON.parse(v.effects),
      archive_sha: v.archive_sha,
      archive_size: v.archive_size,
      published_via: v.published_via,
    })),
  });
});

// GET /v1/qubes/:name/:version — single version metadata
qubes.get("/:name/:version", async (c) => {
  const name = decodeURIComponent(c.req.param("name"));
  const version = c.req.param("version");
  const row = await c.env.DB.prepare(
    `SELECT version, manifest, archive_sha, archive_size, effects, published_at,
            yanked, published_via, provenance
     FROM versions WHERE qube_name = ? AND version = ?`,
  ).bind(name, version).first<VersionRow>();
  if (!row) return c.json({ code: "QUB404", message: "version not found" }, 404);

  return c.json({
    qube: name,
    version: row.version,
    archive_sha: row.archive_sha,
    archive_size: row.archive_size,
    effects: JSON.parse(row.effects),
    published_at: row.published_at,
    yanked: !!row.yanked,
    // Manifests are accepted and stored as raw JSON5 (see publish above),
    // so they must be read back with JSON5 — strict JSON.parse throws on the
    // comments/trailing commas a `qube.json5` legitimately carries. Guarded so
    // a malformed row degrades to null rather than 500-ing the endpoint.
    manifest: parseManifestOrNull(row.manifest),
    published_via: row.published_via,
    provenance: row.provenance ? JSON.parse(row.provenance) : null,
  });
});

// GET /v1/qubes/:name/:version/archive — stream the .zip from R2
qubes.get("/:name/:version/archive", async (c) => {
  const name = decodeURIComponent(c.req.param("name"));
  const version = c.req.param("version");
  const row = await c.env.DB.prepare(
    `SELECT archive_sha FROM versions WHERE qube_name = ? AND version = ?`,
  ).bind(name, version).first<{ archive_sha: string }>();
  if (!row) return c.json({ code: "QUB404", message: "version not found" }, 404);

  const obj = await c.env.ARCHIVES.get(`archives/${row.archive_sha}`);
  if (!obj) return c.json({ code: "QUB500", message: "archive missing" }, 500);

  // Best-effort download counter — fire-and-forget with waitUntil if available.
  c.executionCtx.waitUntil(
    c.env.DB.prepare(
      `UPDATE qubes SET downloads = downloads + 1 WHERE name = ?`,
    ).bind(name).run(),
  );

  return new Response(obj.body, {
    headers: {
      "content-type": "application/zip",
      "cache-control": "immutable, max-age=31536000",
      "etag": `"${row.archive_sha}"`,
      "x-checksum-sha256": row.archive_sha,
    },
  });
});
