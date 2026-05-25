/**
 * stdin / stdout / stderr routing for a running program (spec/q64-cli.md
 * §"Stdin / stdout / stderr conventions"). Needs `q64 run`, which is not
 * implemented in v0, so these encode the routing contract as `.todo`.
 */
import { describe, test } from "bun:test";

describe("IO routing (running a program)", () => {
  test.todo("stdin is forwarded to the program's env.in");
  test.todo("the program's env.out is written to stdout");
  test.todo("the program's env.err and diagnostics are written to stderr");
  test.todo("`q64 script.q | grep` stays clean: diagnostics never pollute stdout");
});
