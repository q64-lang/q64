// Route-level coverage for the OCI surface against the real Hono app, with D1
// and R2 mocked in memory — proves the pull flow `oras` performs: GET /v2/ →
// manifest by tag → manifest by digest → config/archive blobs → tags, plus the
// error + read-only-push paths. (Live interop is on a deployed worker.)

import { test, expect } from "bun:test";
import app from "../src/index.ts";

const ARCHIVE = new TextEncoder().encode("PK fake zip bytes");
async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function mockDB() {
  return {
    prepare(sql: string) {
      let args: unknown[] = [];
      const api = {
        bind(...a: unknown[]) { args = a; return api; },
        async first() {
          if (sql.includes("FROM qubes WHERE name")) {
            return args[0] === "dev.q64.math" ? { name: "dev.q64.math" } : null;
          }
          if (sql.includes("FROM versions WHERE qube_name = ? AND version")) {
            if (args[0] === "dev.q64.math" && args[1] === "0.1.0") {
              return {
                version: "0.1.0",
                manifest: "{ name: 'dev.q64.math', version: '0.1.0' }",
                archive_sha: SHA,
                archive_size: ARCHIVE.byteLength,
                wit: null,
                yanked: 0,
              };
            }
            return null;
          }
          return null;
        },
        async all() {
          if (sql.includes("SELECT version FROM versions")) {
            return { results: [{ version: "0.1.0" }, { version: "0.2.0" }] };
          }
          return { results: [] };
        },
        async run() { return { success: true }; },
      };
      return api;
    },
  };
}

function mockR2(initial: Map<string, Uint8Array>) {
  const meta = new Map<string, { contentType?: string }>();
  return {
    async get(key: string) {
      const bytes = initial.get(key);
      if (!bytes) return null;
      return {
        size: bytes.byteLength,
        body: bytes as unknown as ReadableStream,
        httpMetadata: meta.get(key),
        async arrayBuffer() { return bytes.buffer; },
      };
    },
    async put(key: string, bytes: ArrayBuffer | Uint8Array, opts?: { httpMetadata?: { contentType?: string } }) {
      initial.set(key, bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
      if (opts?.httpMetadata) meta.set(key, opts.httpMetadata);
    },
    _store: initial,
  };
}

let SHA = "";
const ctx = { waitUntil() {}, passThroughOnException() {} };
async function makeEnv() {
  SHA = await sha256Hex(ARCHIVE);
  const r2 = mockR2(new Map([[`archives/${SHA}`, ARCHIVE]]));
  return { env: { DB: mockDB(), ARCHIVES: r2 } as never, r2 };
}
const req = (env: never, path: string, init?: RequestInit) =>
  app.request(path, init, env, ctx as never);

test("GET /v2/ → 200 with the distribution-api-version header", async () => {
  const { env } = await makeEnv();
  const res = await req(env, "/v2/");
  expect(res.status).toBe(200);
  expect(res.headers.get("Docker-Distribution-API-Version")).toBe("registry/2.0");
});

test("tags/list returns the published versions", async () => {
  const { env } = await makeEnv();
  const res = await req(env, "/v2/dev.q64.math/tags/list");
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ name: "dev.q64.math", tags: ["0.1.0", "0.2.0"] });
});

test("manifest by tag, then by its digest, round-trips byte-identical", async () => {
  const { env } = await makeEnv();
  const res = await req(env, "/v2/dev.q64.math/manifests/0.1.0");
  expect(res.status).toBe(200);
  expect(res.headers.get("Content-Type")).toBe("application/vnd.oci.image.manifest.v1+json");
  const digest = res.headers.get("Docker-Content-Digest")!;
  expect(digest).toMatch(/^sha256:[0-9a-f]{64}$/);
  const manifest = await res.json();
  expect(manifest.layers[0].digest).toBe(`sha256:${SHA}`);

  // The same env (R2 now has the materialized manifest) resolves it by digest.
  const byDigest = await req(env, `/v2/dev.q64.math/manifests/${digest}`);
  expect(byDigest.status).toBe(200);
  expect(byDigest.headers.get("Docker-Content-Digest")).toBe(digest);
  expect(await byDigest.json()).toEqual(manifest);
});

test("HEAD manifest sets the digest header with no body", async () => {
  const { env } = await makeEnv();
  const res = await req(env, "/v2/dev.q64.math/manifests/0.1.0", { method: "HEAD" });
  expect(res.status).toBe(200);
  expect(res.headers.get("Docker-Content-Digest")).toMatch(/^sha256:/);
  expect(await res.text()).toBe("");
});

test("config + archive blobs are served by digest (archive falls back to archives/<h>)", async () => {
  const { env } = await makeEnv();
  const m = await (await req(env, "/v2/dev.q64.math/manifests/0.1.0")).json();

  const config = await req(env, `/v2/dev.q64.math/blobs/${m.config.digest}`);
  expect(config.status).toBe(200);
  expect(config.headers.get("Docker-Content-Digest")).toBe(m.config.digest);

  const archive = await req(env, `/v2/dev.q64.math/blobs/sha256:${SHA}`);
  expect(archive.status).toBe(200);
  expect(new Uint8Array(await archive.arrayBuffer())).toEqual(ARCHIVE);
});

test("unknown manifest + unknown repo give spec-shaped errors", async () => {
  const { env } = await makeEnv();
  const noVer = await req(env, "/v2/dev.q64.math/manifests/9.9.9");
  expect(noVer.status).toBe(404);
  expect((await noVer.json()).errors[0].code).toBe("MANIFEST_UNKNOWN");

  const noRepo = await req(env, "/v2/dev.q64.nope/tags/list");
  expect(noRepo.status).toBe(404);
  expect((await noRepo.json()).errors[0].code).toBe("NAME_UNKNOWN");
});

test("a bad digest and an unsupported push fail legibly", async () => {
  const { env } = await makeEnv();
  const bad = await req(env, "/v2/dev.q64.math/blobs/sha512:abc");
  expect(bad.status).toBe(400);
  expect((await bad.json()).errors[0].code).toBe("DIGEST_INVALID");

  const push = await req(env, "/v2/dev.q64.math/blobs/uploads/", { method: "POST" });
  expect(push.status).toBe(405);
  expect((await push.json()).errors[0].code).toBe("UNSUPPORTED");
});
