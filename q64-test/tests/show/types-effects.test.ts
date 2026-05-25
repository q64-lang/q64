/**
 * `q64 show types <expr>` and `q64 show effects <fn>` — introspection
 * (spec/q64-cli.md §"q64 show kinds"). Not implemented in v0.
 */
import { describe, test } from "bun:test";

describe("q64 show types", () => {
  test.todo("prints the inferred type of an expression");
  test.todo("accepts `--qube <path>` / `--module name=path` context flags");
});

describe("q64 show effects", () => {
  test.todo("prints the effect set of a function");
  test.todo("reflects inferred effects (e.g. @network) from the body");
});
