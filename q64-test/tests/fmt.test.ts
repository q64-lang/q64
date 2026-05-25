/**
 * `q64 fmt [path]` — format source in place, or via stdin/stdout
 * (spec/q64-cli.md §"q64 fmt options"). Not implemented in v0.
 */
import { describe, test } from "bun:test";

describe("q64 fmt", () => {
  test.todo("`fmt path` formats a file in place");
  test.todo("`fmt --stdout` reads stdin and writes the formatted result to stdout");
  test.todo("`fmt --stdout` leaves the input file untouched");
  test.todo("`fmt --check` exits 64 when a file would be reformatted");
  test.todo("`fmt --check` exits 0 when already formatted");
  test.todo("`fmt --lint` reports formatting issues as diagnostics on stderr");
});
