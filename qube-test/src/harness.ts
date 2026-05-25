/**
 * Test harness for the qube CLI black-box suite.
 *
 * Spawns the built `qube` binary, feeds optional stdin, and captures exit
 * code, stdout, and stderr. qube emits the same newline-delimited JSON
 * envelope as q64 (with PKG / REG2 prefixes for its own diagnostics, and
 * q64's envelopes forwarded verbatim — spec/qube-cli.md §"How qube invokes
 * q64", spec/diagnostics.md).
 *
 * The binary is located via the QUBE_BIN env var, defaulting to the build
 * output at qube/zig-out/bin/qube. When the binary is absent,
 * binaryAvailable() returns false so spawn-based suites skip rather than fail.
 */
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/**
 * Absolute path to the qube binary under test. A QUBE_BIN override is resolved
 * against the initial process cwd, so it stays correct even when individual
 * tests spawn with a different `cwd` (e.g. a temp project from makeProject).
 */
export const QUBE_BIN = process.env.QUBE_BIN
  ? resolve(process.env.QUBE_BIN)
  : resolve(here, "../../qube/zig-out/bin/qube");

/** Directory holding static fixture qube projects. */
export const FIXTURES = resolve(here, "../fixtures");

/** Resolve a fixture project (or file) path by name. */
export function fixture(name: string): string {
  return resolve(FIXTURES, name);
}

/** True when the qube binary exists and can be spawned. */
export function binaryAvailable(): boolean {
  return existsSync(QUBE_BIN);
}

export type Severity = "error" | "warning" | "note" | "help" | "internal";

export interface Diagnostic {
  code: string;
  severity: Severity;
  message?: string;
}

export interface Envelope {
  ok: boolean;
  diagnostics: Diagnostic[];
}

export interface CliResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  envelope?: Envelope;
}

export interface RunOptions {
  stdin?: string;
  cwd?: string;
  env?: Record<string, string>;
  /** Hard cap so a command that blocks (e.g. `qube web` serving) can't hang the suite. */
  timeout?: number;
}

/** Run `qube <args>` synchronously and capture its output. */
export function runCli(args: string[], opts: RunOptions = {}): CliResult {
  const proc = Bun.spawnSync({
    cmd: [QUBE_BIN, ...args],
    stdin: opts.stdin != null ? Buffer.from(opts.stdin) : undefined,
    cwd: opts.cwd,
    env: opts.env ? { ...process.env, ...opts.env } : undefined,
    timeout: opts.timeout ?? 30_000,
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: proc.exitCode ?? -1,
    stdout: proc.stdout ? proc.stdout.toString() : "",
    stderr: proc.stderr ? proc.stderr.toString() : "",
    envelope: parseEnvelope(proc.stderr ? proc.stderr.toString() : ""),
  };
}

/** Parse the trailing newline-delimited JSON envelope from a stderr stream. */
export function parseEnvelope(stderr: string): Envelope | undefined {
  const lines = stderr.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line.startsWith("{")) continue;
    try {
      const obj = JSON.parse(line);
      if (obj && typeof obj === "object" && "ok" in obj) return obj as Envelope;
    } catch {
      // Not a JSON line; keep scanning upward.
    }
  }
  return undefined;
}

/**
 * Materialise a throwaway qube project from a map of relative path → contents,
 * returning its root directory. Nested directories are created as needed.
 * Useful for manifest-discovery and workspace tests without static fixtures.
 */
export function makeProject(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), "qube-proj-"));
  for (const [rel, contents] of Object.entries(files)) {
    const abs = join(root, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, contents);
  }
  return root;
}

/**
 * A minimal valid application manifest. Uses quoted keys + double-quoted
 * strings — the form the v0 reader accepts (it strips // comments and
 * trailing commas but does not yet handle JSON5 unquoted keys / single
 * quotes; see todo.md). Mirrors examples/hello/qube.json5.
 */
export function appManifest(name = "dev.q64.test_app"): string {
  return [
    "{",
    '  "$schema": "https://q64.dev/schema/qube.json5",',
    `  "name": "${name}",`,
    '  "version": "0.1.0",',
    '  "license": "MIT OR Apache-2.0",',
    '  "type": "application",',
    '  "entry": "src/main.q",',
    "}",
    "",
  ].join("\n");
}
