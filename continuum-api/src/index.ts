import { Hono } from "hono";
import type { Env } from "./env.ts";
import { qubes } from "./routes/qubes.ts";
import { categories } from "./routes/categories.ts";
import { auth } from "./routes/auth.ts";

const app = new Hono<{ Bindings: Env }>();

// Root: humans who accidentally hit qubes.q64.dev get a pointer.
app.get("/", (c) =>
  c.html(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Continuum API</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root { color-scheme: dark; }
    body { font-family: system-ui, sans-serif; max-width: 36rem; margin: 4rem auto; padding: 0 1rem; line-height: 1.5; background: hsl(224, 10%, 10%); color: hsl(224, 6%, 77%); }
    code { font-family: ui-monospace, monospace; background: hsl(224, 10%, 23%); padding: 0.1em 0.3em; border-radius: 3px; }
    a { color: #CBA6FF; }
  </style>
</head>
<body>
  <h1>Continuum API</h1>
  <p>This is <code>qubes.q64.dev</code> — the machine-readable surface for the Q64 package registry.</p>
  <p>Humans probably want <a href="https://continuum.q64.dev">continuum.q64.dev</a>; agents can start at <a href="https://docs.q64.dev">docs.q64.dev</a>.</p>
  <p>Wire contract: <a href="https://github.com/q64-lang/q64/blob/main/spec/continuum-api.md">spec/continuum-api.md</a></p>
</body>
</html>`),
);

app.get("/v1/health", (c) => c.json({ ok: true }));

app.route("/v1/qubes", qubes);
app.route("/v1/categories", categories);
app.route("/v1/auth", auth);

export default app;
