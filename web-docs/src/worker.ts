// docs.q64.dev Worker.
//
// Narrow scope: serve the Astro static build. The diagnostic pages at
// /diagnostics/<CODE> are static assets generated from `q64 doc --json`, so a
// compiler error URL resolves to a real page with no dynamic routing.

export interface Env {
  ASSETS: Fetcher;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Force the apex docs host. www.docs.q64.dev -> docs.q64.dev (301).
    if (url.hostname === 'www.docs.q64.dev') {
      url.hostname = 'docs.q64.dev';
      return Response.redirect(url.toString(), 301);
    }

    return env.ASSETS.fetch(request);
  },
} satisfies ExportedHandler<Env>;
