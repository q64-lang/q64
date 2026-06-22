// Phase 4 of the engine-as-component plan: the Continuum OCI distribution
// surface. These cover the PURE synthesis the read path depends on — canonical
// (stable-digest) JSON and the OCI artifact manifest built from a version row.
// The HTTP routing + R2/D1 wiring is exercised against a deployed worker
// (spec/continuum-api.md §"OCI distribution"); here we pin the content-addressing
// invariants that make `oras pull` work.

import { test, expect } from "bun:test";
import { canonicalJson, buildManifest } from "../src/routes/oci.ts";

const row = {
  version: "0.1.0",
  manifest: "{ name: 'dev.q64.math', version: '0.1.0' }", // JSON5 (as stored)
  archive_sha: "a".repeat(64),
  archive_size: 1234,
  wit: null as string | null,
  yanked: 0,
};

test("canonicalJson sorts keys recursively → stable bytes regardless of input order", () => {
  const a = canonicalJson({ b: 1, a: { d: 2, c: 3 } });
  const b = canonicalJson({ a: { c: 3, d: 2 }, b: 1 });
  expect(a).toBe(b);
  expect(a).toBe('{"a":{"c":3,"d":2},"b":1}');
});

test("the archive layer digest is the archive SHA-256 (1:1 mapping, no re-hash)", async () => {
  const m = await buildManifest("dev.q64.math", row);
  const parsed = JSON.parse(new TextDecoder().decode(m.bytes));
  expect(parsed.layers[0].digest).toBe(`sha256:${row.archive_sha}`);
  expect(parsed.layers[0].size).toBe(1234);
  expect(parsed.mediaType).toBe("application/vnd.oci.image.manifest.v1+json");
  expect(parsed.artifactType).toBe("application/vnd.q64.qube.v1+json");
  expect(parsed.config.digest).toBe(`sha256:${m.config.digest}`);
});

test("the manifest digest is deterministic (content-addressing holds across calls)", async () => {
  const a = await buildManifest("dev.q64.math", row);
  const b = await buildManifest("dev.q64.math", row);
  expect(a.digest).toBe(b.digest);
  expect(a.digest).toMatch(/^[0-9a-f]{64}$/);
});

test("a WIT world is added as a second layer; absent when the row has none", async () => {
  const withWit = await buildManifest("dev.q64.math", {
    ...row,
    wit: "package qubeworlds:engine@0.1.0;\nworld engine { export scene; }",
  });
  const parsed = JSON.parse(new TextDecoder().decode(withWit.bytes));
  expect(parsed.layers.length).toBe(2);
  expect(parsed.layers[1].mediaType).toBe("application/vnd.q64.qube.wit.v1+text");
  expect(withWit.wit).not.toBeNull();
  expect(parsed.layers[1].digest).toBe(`sha256:${withWit.wit!.digest}`);

  const noWit = await buildManifest("dev.q64.math", row);
  expect(JSON.parse(new TextDecoder().decode(noWit.bytes)).layers.length).toBe(1);
  expect(noWit.wit).toBeNull();
});

test("config blob is the manifest as canonical JSON (JSON5 → stable JSON)", async () => {
  const m = await buildManifest("dev.q64.math", row);
  expect(new TextDecoder().decode(m.config.bytes)).toBe(
    '{"name":"dev.q64.math","version":"0.1.0"}',
  );
});
