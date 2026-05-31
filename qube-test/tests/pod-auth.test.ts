/**
 * `qube pod login` / `info` / `logout` (spec/qube-cli.md §"qube pod login").
 * qubepods auth is kept in `<qube home>/pods.toml`, separate from the Continuum
 * registry credentials. We isolate it per-test with QUBE_HOME pointing at a
 * temp dir. The API has no CLI token exchange, so `login` saves a token rather
 * than doing an email/password flow.
 */
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { binaryAvailable, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube pod auth (login / info / logout)", () => {
  let home: string;
  beforeEach(() => {
    home = mkdtempSync(join(tmpdir(), "qube-pod-auth-"));
  });
  afterEach(() => {
    rmSync(home, { recursive: true, force: true });
  });
  const env = () => ({ QUBE_HOME: home });

  test("info reports the provider and 'not authenticated' before login", () => {
    const r = runCli(["pod", "info"], { env: env() });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("Provider:");
    expect(r.stdout).toContain("qubepods");
    expect(r.stdout).toMatch(/Authenticated:\s+no/);
  });

  test("login --token saves pods.toml; info then reports authenticated", () => {
    const login = runCli(["pod", "login", "--token", "qube_test_tok"], { env: env() });
    expect(login.exitCode).toBe(0);

    const podsToml = readFileSync(join(home, "pods.toml"), "utf8");
    expect(podsToml).toContain('token = "qube_test_tok"');
    expect(podsToml).toContain('[pods."api-stage.qubepods.com"]');

    const info = runCli(["pod", "info"], { env: env() });
    expect(info.stdout).toMatch(/Authenticated:\s+yes/);
  });

  test("login --url keys the token under the given host", () => {
    runCli(["pod", "login", "--token", "t", "--url", "https://api.qubepods.com"], { env: env() });
    const podsToml = readFileSync(join(home, "pods.toml"), "utf8");
    expect(podsToml).toContain('[pods."api.qubepods.com"]');
  });

  test("logout removes the saved token", () => {
    runCli(["pod", "login", "--token", "t"], { env: env() });
    const out = runCli(["pod", "logout"], { env: env() });
    expect(out.exitCode).toBe(0);
    expect(existsSync(join(home, "pods.toml"))).toBe(false);

    const info = runCli(["pod", "info"], { env: env() });
    expect(info.stdout).toMatch(/Authenticated:\s+no/);
  });

  test("deploy with no token anywhere points at `qube pod login`", () => {
    const proj = mkdtempSync(join(tmpdir(), "qube-pod-deploy-"));
    try {
      // A minimal manifest so the token check (which runs after manifest
      // discovery) is reached.
      Bun.write(
        join(proj, "qubepod.jsonc"),
        '{"name":"x","component":{"wasm":"./x.wasm"}}',
      );
      const r = runCli(["pod", "deploy"], { env: env(), cwd: proj });
      expect(r.exitCode).not.toBe(0);
      expect(r.stderr).toContain("qube pod login");
    } finally {
      rmSync(proj, { recursive: true, force: true });
    }
  });
});
