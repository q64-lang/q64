/**
 * `qube login` (auth against the registry, credentials in
 * ~/.qube/credentials.toml). Interactive + network, so encoded as `.todo`.
 */
import { describe, test } from "bun:test";

describe("qube login", () => {
  test.todo("stores a credential token per registry in ~/.qube/credentials.toml");
  test.todo("QUBE_HOME overrides the credentials location");
  test.todo("a failed authentication exits 67 (registry error)");
});
