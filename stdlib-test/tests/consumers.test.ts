/**
 * Coarse consumer smokes: a program importing a stdlib namespace should
 * compile once the namespace exists (spec/q64-cli.md §"--module": core stdlib
 * `q64.*` is built in and needs no --module).
 *
 * Test-first: stdlib imports are not resolved yet (q64 emit rejects them), so
 * these fail today. Limited to namespaces with named exports in their README
 * (net → Url, math → Vec, layout → Rect, view → View, event → Tap,
 * reactive → Signal); no method signatures are assumed.
 */
import { describe, expect, test } from "bun:test";
import { emitConsumer, q64Available } from "../src/harness";

describe.skipIf(!q64Available())("stdlib consumers compile", () => {
  test.failing("a program importing q64.net.{Url} compiles (q64 emit, exit 0)", () => {
    expect(emitConsumer("net-consumer.q").exitCode).toBe(0);
  });

  test.failing("a program importing q64.math.{Vec} compiles (q64 emit, exit 0)", () => {
    expect(emitConsumer("math-consumer.q").exitCode).toBe(0);
  });

  test.failing("a program importing q64.layout.{Rect} compiles (q64 emit, exit 0)", () => {
    expect(emitConsumer("layout-consumer.q").exitCode).toBe(0);
  });

  test.failing("a program importing q64.view.{View} compiles (q64 emit, exit 0)", () => {
    expect(emitConsumer("view-consumer.q").exitCode).toBe(0);
  });

  test.failing("a program importing q64.event.{Tap} compiles (q64 emit, exit 0)", () => {
    expect(emitConsumer("event-consumer.q").exitCode).toBe(0);
  });

  test.failing("a program importing q64.reactive.{Signal} compiles (q64 emit, exit 0)", () => {
    expect(emitConsumer("reactive-consumer.q").exitCode).toBe(0);
  });
});
