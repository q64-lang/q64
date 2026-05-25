/**
 * `q64 show capabilities <qube>`, `q64 show denials <fn>`, `q64 show world
 * <qube>` — the component-model / capability surface (spec/q64-cli.md
 * §"q64 show kinds"). Not implemented in v0.
 */
import { describe, test } from "bun:test";

describe("q64 show capabilities", () => {
  test.todo("prints the compiler-derived capability set for a qube's pub surface");
});

describe("q64 show denials", () => {
  test.todo("prints call-graph reachability into with_capabilities(deny: …) blocks");
});

describe("q64 show world", () => {
  test.todo("prints the synthesized WIT world: exports (public surface) and imports (capability set)");
});
