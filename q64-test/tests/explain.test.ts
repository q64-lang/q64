/**
 * `q64 explain <code>` — structured documentation for a diagnostic code
 * (spec/q64-cli.md §"q64 explain <code>"). Not implemented in v0.
 */
import { describe, test } from "bun:test";

describe("q64 explain", () => {
  test.todo("`explain TYP041` prints readable text on stdout, exit 0");
  test.todo("`explain TYP041 --diagnostics json` returns the documented JSON shape (code, subsystem, title, summary, examples, see_also, url)");
  test.todo("an unknown code reports an error rather than crashing");
});
