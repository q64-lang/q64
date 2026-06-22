// Framework-agnostic OTLP/HTTP+JSON span emitter for the shared Taluvi
// observability platform (taluvi-mono tracing/). Knows nothing about Hono — it
// just builds the OTLP ResourceSpans envelope the otel ingest worker decodes and
// POSTs it. The attribute layout mirrors @tracing/core's contract: `taluvi.app`
// and `taluvi.environment` are stamped authoritatively by the otel worker from
// the ingest token + its own ENVIRONMENT, so we send them only for completeness.
//
// Vendored per-repo on purpose (no cross-repo registry yet); the contract is
// identical across products, so this can graduate to a published package later
// with no API change.

// OTLP span kinds (subset we use): 1 = INTERNAL, 2 = SERVER, 3 = CLIENT.
export const SpanKind = { INTERNAL: 1, SERVER: 2, CLIENT: 3 } as const;
// OTLP status codes: 0 = UNSET, 1 = OK, 2 = ERROR.
export const SpanStatus = { UNSET: 0, OK: 1, ERROR: 2 } as const;

export type AttrValue = string | number | boolean;
export type Attributes = Record<string, AttrValue>;

export interface TracingConfig {
	/** otel ingest origin, e.g. https://otel.taluvi.dev (stage) / .com (prod). */
	endpoint: string;
	/** Per-project ingest bearer (trc_ingest_…). */
	token: string;
	/** taluvi.app — overridden by the token at ingest; sent for completeness. */
	app: string;
	/** AE grouping key (taluvi.tenant_id). Defaults to "taluvi". */
	tenantId?: string;
	/** OTel service.name for this worker (e.g. qubepods-api-stage). */
	serviceName?: string;
}

/** One finished span, ready to encode. Times are unix-epoch nanoseconds. */
export interface Span {
	traceId: string;
	spanId: string;
	parentSpanId?: string;
	name: string;
	kind?: number;
	startNano: number;
	endNano: number;
	statusCode?: number;
	statusMessage?: string;
	attributes?: Attributes;
}

/** Two random hex ids per the OTLP wire format: trace = 16 bytes, span = 8. */
export function newTraceId(): string {
	return hex(16);
}
export function newSpanId(): string {
	return hex(8);
}
function hex(bytes: number): string {
	const b = crypto.getRandomValues(new Uint8Array(bytes));
	return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
}

interface OtlpKeyValue {
	key: string;
	value: { stringValue: string } | { intValue: string } | { doubleValue: number } | { boolValue: boolean };
}

function toKeyValue(key: string, v: AttrValue): OtlpKeyValue {
	if (typeof v === 'boolean') return { key, value: { boolValue: v } };
	if (typeof v === 'number') {
		return Number.isInteger(v)
			? { key, value: { intValue: String(v) } }
			: { key, value: { doubleValue: v } };
	}
	return { key, value: { stringValue: v } };
}

function attrsToList(attrs: Attributes | undefined): OtlpKeyValue[] {
	if (!attrs) return [];
	return Object.entries(attrs).map(([k, v]) => toKeyValue(k, v));
}

/** Build the OTLP ResourceSpans envelope for a batch of spans sharing one resource. */
export function buildResourceSpans(cfg: TracingConfig, spans: Span[]): unknown {
	const resourceAttrs: OtlpKeyValue[] = [
		toKeyValue('taluvi.tenant_id', cfg.tenantId ?? 'taluvi'),
		toKeyValue('taluvi.app', cfg.app)
	];
	if (cfg.serviceName) resourceAttrs.push(toKeyValue('service.name', cfg.serviceName));
	return {
		resourceSpans: [
			{
				resource: { attributes: resourceAttrs },
				scopeSpans: [
					{
						scope: { name: cfg.serviceName ?? cfg.app },
						spans: spans.map((s) => ({
							traceId: s.traceId,
							spanId: s.spanId,
							...(s.parentSpanId ? { parentSpanId: s.parentSpanId } : {}),
							name: s.name,
							kind: s.kind ?? SpanKind.INTERNAL,
							startTimeUnixNano: String(s.startNano),
							endTimeUnixNano: String(s.endNano),
							attributes: attrsToList(s.attributes),
							status: {
								code: s.statusCode ?? SpanStatus.UNSET,
								...(s.statusMessage ? { message: s.statusMessage } : {})
							}
						}))
					}
				]
			}
		]
	};
}

/**
 * POST a batch of spans to the otel ingest worker. Returns a promise the caller
 * hands to `ctx.waitUntil` — fire-and-forget, never throws into the request path.
 */
export async function sendSpans(cfg: TracingConfig, spans: Span[]): Promise<void> {
	if (spans.length === 0) return;
	try {
		const res = await fetch(`${cfg.endpoint.replace(/\/$/, '')}/v1/traces`, {
			method: 'POST',
			headers: { 'content-type': 'application/json', authorization: `Bearer ${cfg.token}` },
			body: JSON.stringify(buildResourceSpans(cfg, spans))
		});
		if (!res.ok) console.warn(`@taluvi/tracing: otel ingest ${res.status}`);
	} catch (e) {
		console.warn('@taluvi/tracing: otel ingest failed', e);
	}
}
