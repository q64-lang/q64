import { Hono } from "hono";
import { cors } from "hono/cors";
import { honoTracing, tracingConfigFromEnv } from "./lib/tracing/hono.ts";
import type { Env } from "./env.ts";
import { qubes } from "./routes/qubes.ts";
import { categories } from "./routes/categories.ts";
import { auth } from "./routes/auth.ts";
import { oci } from "./routes/oci.ts";

// `strict: false` so a trailing slash is accepted — the OCI spec mandates
// `GET /v2/` (with slash), and it's harmless leniency for the v1 JSON API.
const app = new Hono<{ Bindings: Env }>({ strict: false });

// Public registry: allow cross-origin reads so browser clients (the qubepods
// shell resolving an engine dependency, the Continuum UI on another host, OCI
// tooling) can fetch metadata + archives + manifests. Reads are public, so a
// wildcard origin is correct; the publish path stays Bearer-gated regardless.
app.use("*", cors({ origin: "*", allowMethods: ["GET", "HEAD", "POST", "OPTIONS"] }));

// Taluvi tracing: one OTLP SERVER span per request under app `q64-continuum`,
// flushed via waitUntil. Inert until TRACING_OTLP_ENDPOINT + TRACING_INGEST_TOKEN
// are set, so it never affects a request and stays off where unprovisioned. This
// is how the registry's resolution traffic (e.g. the qubepods shell resolving an
// engine dependency: GET /v1/qubes/<name>) becomes visible in observe.taluvi.
app.use("*", honoTracing<Env>((env) => tracingConfigFromEnv(env, "q64-continuum")));

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

// OCI Distribution surface (`oras pull` / `wkg`) over the same content-addressed
// store — see routes/oci.ts + spec/continuum-api.md §"OCI distribution".
app.route("/v2", oci);

export default app;
