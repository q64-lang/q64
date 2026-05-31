// Package entry — the transport-agnostic server, importable by any host
// (browser Worker, Cloudflare Worker). Desktop editors use the `q64-lsp`
// binary (dist/node.js) instead.

export { runServer } from "./handlers.js";
export { toLspDiagnostics } from "./diagnostics.js";
