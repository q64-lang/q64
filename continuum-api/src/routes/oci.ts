import { Hono, type Context } from "hono";
import JSON5 from "json5";
import type { Env } from "../env.ts";

type Ctx = Context<{ Bindings: Env }>;

// OCI Distribution surface for the Continuum — a SECOND protocol facade over the
// same content-addressed store the JSON API (routes/qubes.ts) already owns, so a
// published qube is pullable with the standard ecosystem (`oras pull`, `wkg`,
// `crane`, any cloud registry mirror). Additive: the JSON API + `qube publish`
// stay the opinionated front door; this is an interop escape hatch, not a
// migration. See spec/continuum-api.md §"OCI distribution" and q64 todo.md
// §"Continuum — OCI compliance".
//
// THE MAPPING (the pieces already exist):
//   qube name `dev.q64.math`            → OCI repository name (`<name>`)
//   version `0.1.0`                     → OCI tag (`<reference>`)
//   archive SHA-256 (R2 `archives/<h>`) → OCI blob digest `sha256:<h>` (1:1)
//   `qube.json5` (D1 `versions.manifest`)→ OCI config blob (canonical JSON)
//   synthesized `.wit` world (rung 3)    → an OCI layer blob
//   the `.zip` archive                   → an OCI layer blob (`application/zip`)
//
// SCOPE: this is the READ (pull) path — `GET /v2/`, manifests, blobs, tags. It
// synthesizes the OCI manifest from the existing version row on read and lazily
// materializes the small derived blobs (config, wit, manifest) into R2 under a
// `blobs/`/`manifests/` digest prefix; the large `.zip` is served in place from
// `archives/<h>` (never duplicated). The WRITE (push) path — `POST .../blobs/
// uploads/` + `PUT .../manifests/<ref>` — is the next rung; it returns a clean
// OCI `UNSUPPORTED` error until then, so a `push` fails legibly instead of
// half-writing. Publishing still happens through `qube publish` (the JSON API).

export const oci = new Hono<{ Bindings: Env }>();

// ---- media types ----------------------------------------------------------
const MT_MANIFEST = "application/vnd.oci.image.manifest.v1+json";
const ARTIFACT_TYPE = "application/vnd.q64.qube.v1+json";
const MT_CONFIG = "application/vnd.q64.qube.config.v1+json";
const MT_ARCHIVE = "application/zip";
const MT_WIT = "application/vnd.q64.qube.wit.v1+text";

// ---- helpers --------------------------------------------------------------

function hex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function sha256(bytes: Uint8Array): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", bytes));
}

// Canonical JSON: object keys sorted recursively, no insignificant whitespace —
// so a value always serializes to the SAME bytes, hence the same digest, across
// requests and deploys. Both the synthesized manifest and the config blob go
// through this; the digest in `Docker-Content-Digest` is computed over exactly
// the bytes we return.
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(value as Record<string, unknown>).sort()) {
      out[k] = sortKeys((value as Record<string, unknown>)[k]);
    }
    return out;
  }
  return value;
}

// OCI error envelope (distribution-spec §error-codes).
function ociError(
  c: Ctx,
  status: 400 | 401 | 404 | 405 | 416,
  code: string,
  message: string,
  detail?: unknown,
) {
  return c.json({ errors: [{ code, message, detail: detail ?? null }] }, status);
}

// A binary/streamed OCI response with the digest + caching headers OCI clients
// expect. `body: null` for a HEAD (headers only, but Content-Length still set).
function ociBlob(
  body: BodyInit | null,
  opts: { contentType: string; length: number; digest: string; immutable?: boolean },
): Response {
  const headers: Record<string, string> = {
    "Content-Type": opts.contentType,
    "Content-Length": String(opts.length),
    "Docker-Content-Digest": opts.digest,
    "ETag": `"${opts.digest}"`,
  };
  if (opts.immutable) headers["Cache-Control"] = "immutable, max-age=31536000";
  return new Response(body, { status: 200, headers });
}

// Parse a `sha256:<hex>` digest reference into its hex (or null if malformed /
// an unsupported algorithm — we only mint and verify sha256).
function parseDigest(ref: string): string | null {
  const m = /^sha256:([0-9a-f]{64})$/.exec(ref);
  return m ? m[1] : null;
}

const enc = new TextEncoder();

type VersionRow = {
  version: string;
  manifest: string;
  archive_sha: string;
  archive_size: number;
  wit: string | null;
  yanked: number;
};

// Build (and digest) the OCI artifact manifest for one published version, plus
// the derived blobs it references. Pure given the row — the digests are stable.
export async function buildManifest(name: string, row: VersionRow): Promise<{
  bytes: Uint8Array;
  digest: string;
  config: { bytes: Uint8Array; digest: string };
  wit: { bytes: Uint8Array; digest: string } | null;
}> {
  // Config blob = the qube.json5 manifest as canonical JSON (it is stored as
  // JSON5, which is not valid JSON, so parse → canonicalize). Degrades to an
  // empty object if a legacy row holds an unparseable manifest.
  let manifestObj: unknown = {};
  try {
    manifestObj = JSON5.parse(row.manifest);
  } catch {
    manifestObj = {};
  }
  const configBytes = enc.encode(canonicalJson(manifestObj));
  const configDigest = await sha256(configBytes);

  const layers: Array<{ mediaType: string; digest: string; size: number }> = [
    { mediaType: MT_ARCHIVE, digest: `sha256:${row.archive_sha}`, size: row.archive_size },
  ];

  let wit: { bytes: Uint8Array; digest: string } | null = null;
  if (row.wit !== null) {
    const witBytes = enc.encode(row.wit);
    const witDigest = await sha256(witBytes);
    wit = { bytes: witBytes, digest: witDigest };
    layers.push({ mediaType: MT_WIT, digest: `sha256:${witDigest}`, size: witBytes.byteLength });
  }

  const manifest = {
    schemaVersion: 2,
    mediaType: MT_MANIFEST,
    artifactType: ARTIFACT_TYPE,
    config: { mediaType: MT_CONFIG, digest: `sha256:${configDigest}`, size: configBytes.byteLength },
    layers,
    annotations: {
      "org.opencontainers.image.title": name,
      "org.opencontainers.image.version": row.version,
      "dev.q64.qube.name": name,
      "dev.q64.qube.version": row.version,
    },
  };
  const bytes = enc.encode(canonicalJson(manifest));
  const digest = await sha256(bytes);
  return { bytes, digest, config: { bytes: configBytes, digest: configDigest }, wit };
}

// Lazily materialize the small derived blobs (config, wit) + the manifest into
// R2 under digest-addressed keys, so a follow-up `GET /blobs/<digest>` (and a
// `GET /manifests/<digest>`) resolves. The `.zip` is NOT copied — blob GET falls
// back to `archives/<hex>`. Idempotent (content-addressed; re-put is harmless).
async function materialize(
  env: Env,
  m: Awaited<ReturnType<typeof buildManifest>>,
): Promise<void> {
  await env.ARCHIVES.put(`blobs/sha256/${m.config.digest}`, m.config.bytes, {
    httpMetadata: { contentType: MT_CONFIG },
  });
  if (m.wit) {
    await env.ARCHIVES.put(`blobs/sha256/${m.wit.digest}`, m.wit.bytes, {
      httpMetadata: { contentType: MT_WIT },
    });
  }
  await env.ARCHIVES.put(`manifests/sha256/${m.digest}`, m.bytes, {
    httpMetadata: { contentType: MT_MANIFEST },
  });
}

// ---- routes ---------------------------------------------------------------

// GET /v2/ — the API version check + the anchor every OCI client probes first.
// Public read needs no auth, so we answer 200 anonymously; the WWW-Authenticate
// challenge is reserved for the write path (the token flow lands with push).
oci.on(["GET", "HEAD"], "/", (c) =>
  new Response(c.req.method === "HEAD" ? null : "{}", {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Docker-Distribution-API-Version": "registry/2.0",
    },
  }),
);

// GET /v2/<name>/tags/list — the published versions, OCI shape. `n`/`last`
// pagination per the distribution spec.
oci.get("/:name/tags/list", async (c) => {
  const name = decodeURIComponent(c.req.param("name"));
  const exists = await c.env.DB.prepare(`SELECT name FROM qubes WHERE name = ?`).bind(name).first();
  if (!exists) return ociError(c, 404, "NAME_UNKNOWN", `repository ${name} not found`);

  const { results } = await c.env.DB.prepare(
    `SELECT version FROM versions WHERE qube_name = ? AND yanked = 0 ORDER BY published_at ASC`,
  ).bind(name).all<{ version: string }>();
  let tags = results.map((r) => r.version);

  const last = c.req.query("last");
  if (last) {
    const i = tags.indexOf(last);
    if (i >= 0) tags = tags.slice(i + 1);
  }
  const n = parseInt(c.req.query("n") ?? "", 10);
  if (Number.isFinite(n) && n >= 0) tags = tags.slice(0, n);

  return c.json({ name, tags });
});

// GET|HEAD /v2/<name>/manifests/<reference> — the synthesized OCI artifact
// manifest for a tag (version) or a manifest digest. On a tag, synthesize from
// the version row + materialize the derived blobs; on a digest, serve the
// materialized bytes (populated when the tag was first read).
oci.on(["GET", "HEAD"], "/:name/manifests/:reference", async (c) => {
  const name = decodeURIComponent(c.req.param("name"));
  const reference = c.req.param("reference");
  const head = c.req.method === "HEAD";

  const byDigest = parseDigest(reference);
  if (byDigest) {
    const obj = await c.env.ARCHIVES.get(`manifests/sha256/${byDigest}`);
    if (!obj) return ociError(c, 404, "MANIFEST_UNKNOWN", `manifest sha256:${byDigest} not found`);
    return ociBlob(head ? null : obj.body, {
      contentType: MT_MANIFEST,
      length: obj.size,
      digest: `sha256:${byDigest}`,
      immutable: true,
    });
  }

  const row = await c.env.DB.prepare(
    `SELECT version, manifest, archive_sha, archive_size, wit, yanked
     FROM versions WHERE qube_name = ? AND version = ?`,
  ).bind(name, reference).first<VersionRow>();
  if (!row) {
    const repo = await c.env.DB.prepare(`SELECT name FROM qubes WHERE name = ?`).bind(name).first();
    if (!repo) return ociError(c, 404, "NAME_UNKNOWN", `repository ${name} not found`);
    return ociError(c, 404, "MANIFEST_UNKNOWN", `${name}:${reference} not found`);
  }

  const m = await buildManifest(name, row);
  await materialize(c.env, m);
  return ociBlob(head ? null : m.bytes, {
    contentType: MT_MANIFEST,
    length: m.bytes.byteLength,
    digest: `sha256:${m.digest}`,
  });
});

// GET|HEAD /v2/<name>/blobs/<digest> — serve a blob by digest: the config / wit
// from `blobs/sha256/<hex>`, the `.zip` archive in place from `archives/<hex>`.
// Content-addressed ⇒ name is only used to scope download counting + 404 text.
oci.on(["GET", "HEAD"], "/:name/blobs/:digest", async (c) => {
  const name = decodeURIComponent(c.req.param("name"));
  const digestRef = c.req.param("digest");
  const head = c.req.method === "HEAD";

  const h = parseDigest(digestRef);
  if (!h) return ociError(c, 400, "DIGEST_INVALID", `unsupported digest ${digestRef} (sha256 only)`);

  // Derived blobs first, then the archive content-addressed in place.
  let obj = await c.env.ARCHIVES.get(`blobs/sha256/${h}`);
  let isArchive = false;
  if (!obj) {
    obj = await c.env.ARCHIVES.get(`archives/${h}`);
    isArchive = obj !== null;
  }
  if (!obj) return ociError(c, 404, "BLOB_UNKNOWN", `blob sha256:${h} not found`);

  if (isArchive) {
    // Mirror the JSON archive endpoint's best-effort download counter.
    c.executionCtx.waitUntil(
      c.env.DB.prepare(`UPDATE qubes SET downloads = downloads + 1 WHERE name = ?`).bind(name).run(),
    );
  }

  const contentType = obj.httpMetadata?.contentType ?? "application/octet-stream";
  return ociBlob(head ? null : obj.body, {
    contentType,
    length: obj.size,
    digest: `sha256:${h}`,
    immutable: true,
  });
});

// Anything we don't model. A WRITE method (the push path — `POST .../blobs/
// uploads/`, `PUT .../manifests/<ref>`, …) is not implemented yet, so answer the
// distribution-spec `UNSUPPORTED` error (405) — `oras push` / `wkg publish` fails
// legibly instead of hanging on a phantom upload session; publish through `qube
// publish` (the JSON API) for now. An unmatched READ is a spec-shaped 404. Both
// keep OCI clients on a parseable body rather than Hono's default. (Handled here,
// not as dedicated `:name/blobs/uploads/` routes, to avoid colliding with the
// `:name/blobs/:digest` param sibling in the router.)
const WRITE = new Set(["POST", "PUT", "PATCH", "DELETE"]);
oci.all("/*", (c) =>
  WRITE.has(c.req.method)
    ? ociError(c, 405, "UNSUPPORTED", "the Continuum OCI surface is read-only for now — publish with `qube publish` (JSON API)")
    : ociError(c, 404, "UNSUPPORTED", `${c.req.method} ${c.req.path} is not implemented`),
);
