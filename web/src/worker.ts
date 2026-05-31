// q64.dev Worker.
//
// Scope is intentionally narrow: serve the Astro static build and
// handle hostname-level concerns (www -> apex). Anything API-shaped
// goes to ../continuum (separate Worker, service binding) so blast
// radius stays per-deploy.

export interface Env {
  ASSETS: Fetcher;
  // CONTINUUM?: Fetcher;  // service binding — uncomment when wired
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Force the apex domain. www.q64.dev -> q64.dev (301).
    if (url.hostname === 'www.q64.dev') {
      url.hostname = 'q64.dev';
      return Response.redirect(url.toString(), 301);
    }

    // Future site-local routes (playground glue, etc.) branch here.
    // Anything calling out to continuum goes via service binding.

    return env.ASSETS.fetch(request);
  },
} satisfies ExportedHandler<Env>;
