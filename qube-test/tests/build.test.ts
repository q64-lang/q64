/**
 * `qube build [--target <name>]` (spec/qube-cli.md §Subcommands, §"target/
 * layout"). Compiles the qube to wasm, invoking q64 per source file. Not
 * implemented in v0 (stub exits 2 — pinned in usage.test.ts); spec surface
 * encoded as `.todo`.
 */
import { describe, test } from "bun:test";

describe("qube build", () => {
  test.todo("writes target/debug/<name>.wasm by default");
  test.todo("--release writes target/release/<name>.wasm");
  test.todo("--component also writes target/<host>/<name>.component.wasm");
  test.todo("--target <name> selects a named target from the manifest");
  test.todo("emits <name>.effects.json alongside the wasm");
  test.todo("a compile error from q64 propagates as exit 64");
  test.todo("from a workspace root, builds every member in dependency order");
});
