/**
 * `qube new <name>` / `qube init` (spec/qube-cli.md §Subcommands). Scaffolds a
 * qube directory with a starter manifest and `src/`. Not implemented in v0
 * (both are stubs that exit 2 — pinned in usage.test.ts); the spec'd
 * scaffolding behavior is encoded here as `.todo`.
 */
import { describe, test } from "bun:test";

describe("qube new", () => {
  test.todo("creates a new directory with a starter qube.json5 and src/");
  test.todo("the generated manifest validates against the schema");
  test.todo("defaults to a library (entry src/lib.q) unless --bin/application is requested");
});

describe("qube init", () => {
  test.todo("initialises a qube in the current directory");
  test.todo("refuses to overwrite an existing qube.json5");
});
