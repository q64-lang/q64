// Hono glue for @taluvi/tracing: one middleware that turns each request into a
// root span, plus a `span()` helper for child spans around any operation
// (D1 query, service fetch, AI call …). Spans are buffered per request and
// flushed in a single OTLP POST via `executionCtx.waitUntil`, so tracing adds no
// latency and can never fail a request.
import type { Context, MiddlewareHandler } from 'hono';
import {
	newSpanId,
	newTraceId,
	sendSpans,
	SpanKind,
	SpanStatus,
	type Attributes,
	type Span,
	type TracingConfig
} from './otlp';

// Per-request trace state. Keyed by the Hono Context object (one per request) via
// a WeakMap, so consumers don't have to declare a `Variables` type to use spans.
interface TraceState {
	cfg: TracingConfig;
	traceId: string;
	rootSpanId: string;
	activeSpanId: string; // parent for the next child span; enables real nesting
	spans: Span[];
}
const states = new WeakMap<Context, TraceState>();

function nowNano(): number {
	return Date.now() * 1e6;
}

/**
 * Request-tracing middleware. Accepts either a static config or a resolver
 * `(env) => config`, because in Workers bindings live on `c.env` (per request),
 * not at module scope where `app.use(...)` runs. A `null` config (or resolver
 * returning `null`) makes it a no-op — wire it unconditionally and let config
 * presence decide:
 *
 *   app.use('*', honoTracing<Env>((env) => tracingConfigFromEnv(env, 'qubepods')));
 */
export function honoTracing<E = unknown>(
	config: TracingConfig | null | undefined | ((env: E) => TracingConfig | null | undefined)
): MiddlewareHandler {
	return async (c, next) => {
		const cfg = typeof config === 'function' ? config(c.env as E) : config;
		if (!cfg) return next();

		const traceId = newTraceId();
		const rootSpanId = newSpanId();
		const state: TraceState = { cfg, traceId, rootSpanId, activeSpanId: rootSpanId, spans: [] };
		states.set(c, state);

		const startNano = nowNano();
		const t0 = performance.now();
		await next();
		const endNano = startNano + Math.round((performance.now() - t0) * 1e6);

		const url = new URL(c.req.url);
		const status = c.res.status;
		// Routed path (low cardinality) when Hono matched one, else the raw path.
		const route = c.req.routePath ?? url.pathname;
		state.spans.push({
			traceId,
			spanId: rootSpanId,
			name: `${c.req.method} ${route}`,
			kind: SpanKind.SERVER,
			startNano,
			endNano,
			statusCode: status >= 500 ? SpanStatus.ERROR : SpanStatus.OK,
			attributes: {
				'http.request.method': c.req.method,
				'url.path': url.pathname,
				'http.route': route,
				'server.address': url.host,
				'http.response.status_code': status
			}
		});

		c.executionCtx.waitUntil(sendSpans(cfg, state.spans));
	};
}

/**
 * Trace one operation as a child span of the current request span. Transparent
 * when tracing is disabled (just runs `fn`). Nests correctly: spans created
 * inside `fn` become children of this one. Records ERROR + rethrows on throw.
 *
 *   const rows = await span(c, 'd1.projects.list', () => db.select()…, { 'db.system': 'd1' });
 */
export async function span<T>(
	c: Context,
	name: string,
	fn: () => Promise<T> | T,
	attributes?: Attributes
): Promise<T> {
	const state = states.get(c);
	if (!state) return fn();

	const spanId = newSpanId();
	const parentSpanId = state.activeSpanId;
	const startNano = nowNano();
	const t0 = performance.now();
	const prevActive = state.activeSpanId;
	state.activeSpanId = spanId;

	let statusCode: number = SpanStatus.OK;
	let statusMessage: string | undefined;
	try {
		return await fn();
	} catch (e) {
		statusCode = SpanStatus.ERROR;
		statusMessage = e instanceof Error ? e.message : String(e);
		throw e;
	} finally {
		state.activeSpanId = prevActive;
		state.spans.push({
			traceId: state.traceId,
			spanId,
			parentSpanId,
			name,
			kind: SpanKind.INTERNAL,
			startNano,
			endNano: startNano + Math.round((performance.now() - t0) * 1e6),
			statusCode,
			statusMessage,
			attributes
		});
	}
}

// The standard env-var contract every Taluvi worker uses to configure tracing.
// Reading these in one place keeps the names consistent across services.
export interface TracingEnv {
	TRACING_OTLP_ENDPOINT?: string;
	TRACING_INGEST_TOKEN?: string;
	TRACING_TENANT_ID?: string;
	SERVICE_NAME?: string;
}

/**
 * Build a TracingConfig from the standard env vars, or `null` when tracing isn't
 * configured (endpoint or token missing) so the middleware no-ops. `app` is the
 * product key (e.g. "qubepods"); it's stamped authoritatively by the ingest
 * token anyway but kept self-describing in the payload.
 */
export function tracingConfigFromEnv(env: TracingEnv, app: string): TracingConfig | null {
	if (!env.TRACING_OTLP_ENDPOINT || !env.TRACING_INGEST_TOKEN) return null;
	return {
		endpoint: env.TRACING_OTLP_ENDPOINT,
		token: env.TRACING_INGEST_TOKEN,
		app,
		tenantId: env.TRACING_TENANT_ID || 'taluvi',
		serviceName: env.SERVICE_NAME
	};
}
