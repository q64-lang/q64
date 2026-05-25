/**
 * Test harness for the q64 CLI black-box suite.
 *
 * Spawns the built `q64` binary, feeds optional stdin, and captures exit
 * code, stdout, and stderr. The diagnostic envelope (newline-delimited
 * JSON on stderr, per spec/q64-cli.md §"Subprocess invocation contract"
 * and spec/diagnostics.md) is parsed out when present.
 *
 * The binary is located via the Q64_BIN env var, defaulting to the build
 * output at q64/zig-out/bin/q64 (mirrors q64/scripts/run-conformance.sh).
 * When the binary is absent, binaryAvailable() returns false so spawn-based
 * suites skip rather than fail.
 */
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/**
 * Absolute path to the q64 binary under test. A Q64_BIN override is resolved
 * against the initial process cwd, so it stays correct even when individual
 * tests spawn with a different `cwd`.
 */
export const Q64_BIN = process.env.Q64_BIN
  ? resolve(process.env.Q64_BIN)
  : resolve(here, "../../q64/zig-out/bin/q64");

/** Directory holding shared .q fixtures. */
export const FIXTURES = resolve(here, "../fixtures");

/** Resolve a fixture file path by name. */
export function fixture(name: string): string {
  return resolve(FIXTURES, name);
}

/** True when the q64 binary exists and can be spawned. */
export function binaryAvailable(): boolean {
  return existsSync(Q64_BIN);
}

export type Severity = "error" | "warning" | "note" | "help" | "internal";

export interface Diagnostic {
  code: string;
  severity: Severity;
  message?: string;
  location?: { file?: string; line?: number; col?: number };
}

export interface Envelope {
  ok: boolean;
  diagnostics: Diagnostic[];
}

export interface CliResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  /** Parsed diagnostic envelope, if stderr carried one. */
  envelope?: Envelope;
}

export interface RunOptions {
  stdin?: string;
  cwd?: string;
  env?: Record<string, string>;
}

/** Run `q64 <args>` synchronously and capture its output. */
export function runCli(args: string[], opts: RunOptions = {}): CliResult {
  const proc = Bun.spawnSync({
    cmd: [Q64_BIN, ...args],
    stdin: opts.stdin != null ? Buffer.from(opts.stdin) : undefined,
    cwd: opts.cwd,
    env: opts.env ? { ...process.env, ...opts.env } : undefined,
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

/**
 * Parse the trailing newline-delimited JSON envelope from a stderr stream.
 * q64 may print several envelopes; the last well-formed JSON object line is
 * the aggregate. Returns undefined when none is present (text-mode rendering
 * or empty success).
 */
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

/** Set of diagnostic codes present in an envelope. */
export function codes(env: Envelope | undefined): Set<string> {
  return new Set((env?.diagnostics ?? []).map((d) => d.code));
}

/** True when the envelope carries a diagnostic with the given code (and optional severity). */
export function hasDiagnostic(
  env: Envelope | undefined,
  code: string,
  severity?: Severity,
): boolean {
  return (env?.diagnostics ?? []).some(
    (d) => d.code === code && (severity === undefined || d.severity === severity),
  );
}

/** First 4 bytes of a WebAssembly module: the `\0asm` magic. */
export const WASM_MAGIC = Buffer.from([0x00, 0x61, 0x73, 0x6d]);
