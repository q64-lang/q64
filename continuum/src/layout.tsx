import type { FC, PropsWithChildren } from "hono/jsx";

const css = `
  /* Palette aligned with q64.dev: hue=224 neutrals + #CBA6FF lavender accent. */
  :root {
    --bg: hsl(0, 0%, 100%);
    --bg-alt: hsl(224, 20%, 97%);
    --fg: hsl(224, 14%, 16%);
    --muted: hsl(224, 7%, 36%);
    --border: hsl(224, 20%, 90%);
    --accent: #7c3aed;            /* deeper purple for contrast on white */
    --accent-soft: #f3ebff;
    --font-display: "Fraunces", Georgia, serif;
    --font-body: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    --font-code: "JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: hsl(224, 10%, 10%);
      --bg-alt: hsl(224, 14%, 16%);
      --fg: hsl(224, 6%, 77%);
      --muted: hsl(224, 6%, 56%);
      --border: hsl(224, 10%, 23%);
      --accent: #CBA6FF;          /* q64.dev brand lavender */
      --accent-soft: hsl(266, 39%, 22%);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--fg);
    font-family: var(--font-body);
    font-size: 16px;
    line-height: 1.55;
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
  }
  main { max-width: 64rem; margin: 0 auto; padding: 2.5rem 1.5rem; }
  h1, h2, h3 {
    font-family: var(--font-display);
    font-weight: 600;
    letter-spacing: -0.015em;
    line-height: 1.15;
  }
  h1 { font-size: clamp(2.5rem, 6vw, 4rem); margin: 0 0 0.5rem; }
  h2 { font-size: 1.5rem; margin: 2.5rem 0 1rem; }
  h3 { font-size: 1.15rem; margin: 1.5rem 0 0.5rem; }
  code, pre { font-family: var(--font-code); font-size: 0.92em; }
  pre { background: var(--border); padding: 1rem; border-radius: 6px; overflow-x: auto; }
  a { color: var(--accent); text-decoration: underline; text-decoration-color: color-mix(in srgb, var(--accent) 30%, transparent); text-underline-offset: 3px; }
  a:hover { text-decoration-color: var(--accent); }
  a.brand, .qube-list .name { color: var(--fg); text-decoration: none; }
  a.brand:hover, .qube-list .name:hover { color: var(--accent); }
  header.site {
    border-bottom: 1px solid var(--border);
    padding: 1rem 1.5rem;
    display: flex;
    align-items: baseline;
    gap: 1.5rem;
    max-width: 64rem;
    margin: 0 auto;
  }
  header.site .spacer { flex: 1; }
  .brand {
    font-family: var(--font-display);
    font-weight: 700;
    font-size: 1.4rem;
    letter-spacing: -0.02em;
    text-decoration: none;
  }
  nav a, nav button {
    margin-right: 1rem;
    color: var(--muted);
    text-decoration: none;
    background: none;
    border: none;
    padding: 0;
    font: inherit;
    cursor: pointer;
  }
  nav a:hover, nav button:hover { color: var(--fg); }
  .session-user { color: var(--muted); margin-right: 0.5rem; }
  .dilbert {
    font-family: var(--font-display);
    font-style: italic;
    font-size: 1.3rem;
    color: var(--muted);
    margin: 0 0 2rem;
    max-width: 40rem;
  }
  .qube-list { list-style: none; padding: 0; margin: 0; }
  .qube-list li { padding: 1.25rem 0; border-bottom: 1px solid var(--border); }
  .qube-list .row { display: flex; justify-content: space-between; align-items: baseline; gap: 1rem; }
  .qube-list .name { font-weight: 600; font-size: 1.1rem; text-decoration: none; }
  .qube-list .ver { font-family: var(--font-code); font-size: 0.85rem; color: var(--muted); }
  .qube-list .desc { color: var(--muted); margin: 0.25rem 0 0.5rem; }
  .meta { font-size: 0.85rem; color: var(--muted); display: flex; gap: 1rem; flex-wrap: wrap; }
  .meta span { font-variant-numeric: tabular-nums; }
`;

type LayoutProps = {
  title?: string;
  description?: string;
  user?: { username: string } | null;
};

export const Layout: FC<PropsWithChildren<LayoutProps>> = ({
  title,
  description,
  user,
  children,
}) => (
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>{title ? `${title} — Continuum` : "Continuum — the qube registry"}</title>
      {description && <meta name="description" content={description} />}
      <style dangerouslySetInnerHTML={{ __html: css }} />
    </head>
    <body>
      <header class="site">
        <a href="/" class="brand">Continuum</a>
        <nav>
          <a href="/qubes">Qubes</a>
          <a href="/categories">Categories</a>
          <a href="/help">Help</a>
        </nav>
      </header>
      <main>{children}</main>
    </body>
  </html>
);
