/**
 * `q64 run <file>` and implicit run (`q64 <file.q>`) — compile to wasm in
 * memory and run (spec/q64-cli.md §Synopsis, §Subcommands). Not implemented
 * in v0 (the binary exposes `emit`, not `run`), so these encode the spec
 * contract as `.todo`.
 */
import { describe, test } from "bun:test";

describe("q64 run", () => {
  test.todo("`q64 run hello.q` runs the program and writes its output to stdout");
  test.todo("`q64 hello.q` (implicit run) dispatches to `run` when arg ends in .q");
  test.todo("trailing positional args are forwarded to the program's env");
  test.todo("a clean program exits 0");
  test.todo("an uncaught `panic` exits 1 (per §Exit codes)");
  test.todo("`env.exit(N)` propagates exit code N");
});
