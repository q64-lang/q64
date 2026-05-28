import { Hono } from "hono";
import type { Env } from "./env.ts";
import { Layout } from "./layout.tsx";
import { pickDilbertLine } from "./dilbert.ts";
import { CATEGORIES } from "./categories.ts";

const app = new Hono<{ Bindings: Env }>();

app.get("/", (c) =>
  c.html(
    <Layout description="The Q64 community's qube registry. Browse, install, and publish qubes — libraries and applications written in Q64 and shipped as WebAssembly components.">
      <h1>Continuum</h1>
      <p class="dilbert">{pickDilbertLine()}</p>
      <p>
        The <a href="https://q64.dev">Q64</a> community's qube registry. Browse,
        install, and publish <strong>qubes</strong> — libraries and
        deployable applications written in Q64 and shipped as WebAssembly
        components.
      </p>
      <p>
        <a href="/qubes">Browse qubes →</a>
      </p>
    </Layout>,
  ),
);

type QubeListItem = {
  name: string;
  description: string | null;
  latest: string | null;
  downloads: number;
  recent_downloads: number;
};

app.get("/qubes", async (c) => {
  const url = new URL(c.req.url);
  const sort = url.searchParams.get("sort") ?? "downloads";
  const q = url.searchParams.get("q") ?? "";

  const apiUrl = new URL("/v1/qubes", "https://api");
  if (q) apiUrl.searchParams.set("q", q);
  apiUrl.searchParams.set("sort", sort);

  let qubes: QubeListItem[] = [];
  try {
    const res = await c.env.API.fetch(apiUrl.toString());
    if (res.ok) {
      const body = (await res.json()) as { qubes: QubeListItem[] };
      qubes = body.qubes;
    }
  } catch {
    // Empty list on failure; the UI just shows nothing.
  }

  return c.html(
    <Layout title="Qubes" description="Browse all qubes in the Continuum.">
      <h1>Qubes</h1>
      <form method="get" action="/qubes" style="margin: 0 0 2rem;">
        <input
          type="search"
          name="q"
          value={q}
          placeholder="Search qubes"
          style="padding: 0.5rem 0.75rem; font-size: 1rem; width: 20rem; max-width: 100%; border: 1px solid var(--border); border-radius: 4px; background: var(--bg); color: var(--fg);"
        />
      </form>
      {qubes.length === 0 ? (
        <p class="meta">No qubes yet. Be the first to publish.</p>
      ) : (
        <ul class="qube-list">
          {qubes.map((q) => (
            <li>
              <div class="row">
                <a href={`/qubes/${encodeURIComponent(q.name)}`} class="name">
                  {q.name}
                </a>
                <span class="ver">{q.latest ?? "—"}</span>
              </div>
              <p class="desc">{q.description ?? ""}</p>
              <div class="meta">
                <span>{q.downloads.toLocaleString()} downloads</span>
                <span>{q.recent_downloads.toLocaleString()} recent (90d)</span>
              </div>
            </li>
          ))}
        </ul>
      )}
    </Layout>,
  );
});

app.get("/categories", async (c) => {
  let counts: Record<string, number> = {};
  try {
    const res = await c.env.API.fetch("https://api/v1/categories/counts");
    if (res.ok) {
      const body = (await res.json()) as { counts: Record<string, number> };
      counts = body.counts;
    }
  } catch {
    // Empty counts → empty state below.
  }

  // Only categories with at least one qube; sorted by count desc, then alpha.
  const nonEmpty = (Object.entries(counts) as [string, number][])
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));

  return c.html(
    <Layout title="Categories" description="Browse qubes by category.">
      <h1>Categories</h1>
      {nonEmpty.length === 0 ? (
        <>
          <p class="meta">No qubes have categories assigned yet.</p>
          <p>
            <a href="/qubes">Browse all qubes →</a>
          </p>
        </>
      ) : (
        <>
          <p class="meta">
            {nonEmpty.length} of {CATEGORIES.length} categories have qubes.
            The full taxonomy is closed-vocabulary; empty categories are
            hidden here but available in the filter dropdowns.
          </p>
          <ul class="qube-list">
            {nonEmpty.map(([slug, n]) => (
              <li>
                <div class="row">
                  <a href={`/qubes?category=${slug}`} class="name">
                    {slug}
                  </a>
                  <span class="ver">{n}</span>
                </div>
              </li>
            ))}
          </ul>
        </>
      )}
    </Layout>,
  );
});

type QubeDetail = {
  name: string;
  description: string | null;
  repository: string | null;
  license: string | null;
  latest: string | null;
  downloads: number;
  recent_downloads: number;
  created_at: string;
  versions: Array<{
    version: string;
    published_at: string;
    yanked: boolean;
    effects: string[];
    archive_sha: string;
    archive_size: number;
    published_via: string | null;
  }>;
};

type VersionDetail = {
  qube: string;
  version: string;
  archive_sha: string;
  archive_size: number;
  effects: string[];
  published_at: string;
  yanked: boolean;
  manifest: Record<string, unknown>;
  published_via: string | null;
  provenance: unknown;
};

const REGISTRY_HOST = "https://qubes.q64.dev";

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(2)} MB`;
}

function fmtDate(iso: string): string {
  return iso.slice(0, 10);
}

app.get("/qubes/:name", async (c) => {
  const name = decodeURIComponent(c.req.param("name"));
  const apiPath = `/v1/qubes/${encodeURIComponent(name)}`;

  let qube: QubeDetail | null = null;
  try {
    const res = await c.env.API.fetch(`https://api${apiPath}`);
    if (res.ok) qube = (await res.json()) as QubeDetail;
  } catch {
    // null below
  }
  if (!qube) {
    c.status(404);
    return c.html(
      <Layout title="Not found">
        <h1>404</h1>
        <p>
          No qube named <code>{name}</code> in the Continuum.
        </p>
        <p>
          <a href="/qubes">Browse all qubes →</a>
        </p>
      </Layout>,
    );
  }

  let detail: VersionDetail | null = null;
  if (qube.latest) {
    try {
      const r = await c.env.API.fetch(`https://api${apiPath}/${encodeURIComponent(qube.latest)}`);
      if (r.ok) detail = (await r.json()) as VersionDetail;
    } catch {
      // null below
    }
  }

  const manifest = detail?.manifest ?? {};
  const keywords = Array.isArray((manifest as { keywords?: unknown }).keywords)
    ? ((manifest as { keywords: unknown[] }).keywords.filter((k) => typeof k === "string") as string[])
    : [];
  const categories = Array.isArray((manifest as { categories?: unknown }).categories)
    ? ((manifest as { categories: unknown[] }).categories.filter((k) => typeof k === "string") as string[])
    : [];
  const capabilities = Array.isArray((manifest as { capabilities?: unknown }).capabilities)
    ? ((manifest as { capabilities: unknown[] }).capabilities.filter((k) => typeof k === "string") as string[])
    : [];
  const effects = detail?.effects ?? [];
  const type = typeof (manifest as { type?: unknown }).type === "string"
    ? (manifest as { type: string }).type
    : null;
  const entry = typeof (manifest as { entry?: unknown }).entry === "string"
    ? (manifest as { entry: string }).entry
    : null;

  const latestArchiveUrl = qube.latest
    ? `${REGISTRY_HOST}${apiPath}/${encodeURIComponent(qube.latest)}/archive`
    : null;

  return c.html(
    <Layout title={qube.name} description={qube.description ?? undefined}>
      <h1>{qube.name}</h1>
      {qube.description && <p>{qube.description}</p>}
      <div class="meta" style="margin-top: 0.5rem;">
        {qube.latest && <span><code>{qube.latest}</code></span>}
        {type && <span>{type}</span>}
        {entry && <span><code>{entry}</code></span>}
        {qube.license && <span>{qube.license}</span>}
        <span>{qube.downloads.toLocaleString()} downloads</span>
        <span>{qube.recent_downloads.toLocaleString()} recent (90d)</span>
      </div>

      <h2>Install</h2>
      <pre>qube add {qube.name}</pre>

      {latestArchiveUrl && (
        <p>
          <a href={latestArchiveUrl}>Download archive (.zip)</a>{" "}
          <span class="meta" style="display: inline">
            {detail && <span>· {fmtBytes(detail.archive_size)}</span>}
            {detail && <span style="font-family: var(--font-code); font-size: 0.75rem;"> · sha256:{detail.archive_sha.slice(0, 12)}…</span>}
          </span>
        </p>
      )}

      {keywords.length > 0 && (
        <>
          <h2>Keywords</h2>
          <div class="meta">{keywords.map((k) => <span>{k}</span>)}</div>
        </>
      )}

      {categories.length > 0 && (
        <>
          <h2>Categories</h2>
          <div class="meta">
            {categories.map((cat) => (
              <span><a href={`/qubes?category=${encodeURIComponent(cat)}`}>{cat}</a></span>
            ))}
          </div>
        </>
      )}

      {effects.length > 0 && (
        <>
          <h2>Effects</h2>
          <div class="meta">{effects.map((e) => <span><code>{e}</code></span>)}</div>
        </>
      )}

      {capabilities.length > 0 && (
        <>
          <h2>Capabilities</h2>
          <div class="meta">{capabilities.map((cap) => <span><code>{cap}</code></span>)}</div>
        </>
      )}

      <h2>Versions</h2>
      <ul class="qube-list">
        {qube.versions.map((v) => (
          <li>
            <div class="row">
              <span class="name"><code>{v.version}</code></span>
              <span class="ver">{fmtDate(v.published_at)}</span>
            </div>
            <div class="meta">
              <span>{fmtBytes(v.archive_size)}</span>
              <span style="font-family: var(--font-code); font-size: 0.75rem;">sha256:{v.archive_sha.slice(0, 12)}…</span>
              {v.yanked && <span style="color: #b91c1c;">yanked</span>}
              {v.published_via && <span>via {v.published_via}</span>}
              <span>
                <a href={`${REGISTRY_HOST}${apiPath}/${encodeURIComponent(v.version)}/archive`}>
                  download .zip
                </a>
              </span>
            </div>
          </li>
        ))}
      </ul>

      {qube.repository && (
        <>
          <h2>Source</h2>
          <p>
            <a href={qube.repository}>{qube.repository}</a>
          </p>
        </>
      )}
    </Layout>,
  );
});

app.get("/help", (c) =>
  c.html(
    <Layout title="Help" description="How publishing to the Continuum works.">
      <h1>Help</h1>

      <h2>Browsing</h2>
      <p>
        Everything in the Continuum is public. Browse without an account;
        downloads are anonymous.
      </p>

      <h2>Signing in</h2>
      <p>
        Authentication happens in the <code>qube</code> CLI, not the website.
      </p>
      <pre>qube login you@example.com</pre>

      <h2>Publishing a qube</h2>
      <p>
        From the directory containing your <code>qube.json5</code>:
      </p>
      <pre>qube publish</pre>

      <h2>Installing</h2>
      <p>
        Both the <code>qube</code> CLI and the <code>q64</code> compiler ship
        with the Q64 toolchain. See <a href="https://q64.dev">q64.dev</a> for
        install instructions.
      </p>
    </Layout>,
  ),
);

export default app;
