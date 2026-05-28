/**
 * Test harness for the q64 standard library suite.
 *
 * The stdlib (../stdlib) is a qube workspace, one qube per namespace (q64.net,
 * q64.fs, …). This suite drives the real stdlib qubes through the toolchain —
 * `qube build` / `qube test` per namespace and from the workspace root — plus a
 * couple of coarse "a consumer program importing q64.<ns> compiles" smokes via
 * `q64 emit`. Assertions are exit-code level only; no stdlib API shape is
 * assumed (the namespaces are README stubs today).
 *
 * Binaries are located via QUBE_BIN / Q64_BIN, defaulting to their zig-out
 * builds. When a binary is absent, *Available() is false so spawn suites skip.
 */
import { copyFileSync, existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

export const QUBE_BIN = process.env.QUBE_BIN
  ? resolve(process.env.QUBE_BIN)
  : resolve(here, "../../qube/zig-out/bin/qube");

export const Q64_BIN = process.env.Q64_BIN
  ? resolve(process.env.Q64_BIN)
  : resolve(here, "../../q64/zig-out/bin/q64");

/** The stdlib workspace root (q64/stdlib). */
export const STDLIB_DIR = resolve(here, "../../stdlib");

/** Directory holding consumer .q fixtures. */
export const FIXTURES = resolve(here, "../fixtures");

/** The stdlib namespaces, each a workspace member → q64.<ns>. */
export const NAMESPACES = [
  "math",
  "anim",
  "ai",
  "net",
  "audio",
  "gfx",
  "video",
  "fs",
  "layout",
  "view",
  "event",
  "reactive",
] as const;

export function qubeAvailable(): boolean {
  return existsSync(QUBE_BIN);
}

export function q64Available(): boolean {
  return existsSync(Q64_BIN);
}

/** Directory of a stdlib member, e.g. namespaceDir("net") → …/stdlib/net. */
export function namespaceDir(ns: string): string {
  return resolve(STDLIB_DIR, ns);
}

export function fixture(name: string): string {
  return resolve(FIXTURES, name);
}

export interface CliResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

interface RunOptions {
  cwd?: string;
  timeout?: number;
}

function run(bin: string, args: string[], opts: RunOptions): CliResult {
  const proc = Bun.spawnSync({
    cmd: [bin, ...args],
    cwd: opts.cwd,
    timeout: opts.timeout ?? 30_000,
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: proc.exitCode ?? -1,
    stdout: proc.stdout ? proc.stdout.toString() : "",
    stderr: proc.stderr ? proc.stderr.toString() : "",
  };
}

/** Run `qube <args>`. */
export function qube(args: string[], opts: RunOptions = {}): CliResult {
  return run(QUBE_BIN, args, opts);
}

/** Run `q64 <args>`. */
export function q64(args: string[], opts: RunOptions = {}): CliResult {
  return run(Q64_BIN, args, opts);
}

/**
 * Compile a consumer fixture with `q64 emit`, returning the result. Copies the
 * fixture into a temp dir and emits alongside it, so a successful build's
 * artifact never lands in the repo.
 */
export function emitConsumer(fixtureName: string): CliResult {
  const dir = mkdtempSync(join(tmpdir(), "stdlib-consumer-"));
  const src = join(dir, fixtureName);
  copyFileSync(fixture(fixtureName), src);
  return q64(["emit", src, join(dir, "out.wasm")]);
}
