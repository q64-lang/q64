//! http-handler — the minimal `@http_handler` example, emitted as a WebAssembly
//! component that serves HTTP.
//!
//! A qube serves HTTP by exporting a handler instead of a `main`: a `pub fn`
//! carrying the `@http_handler` annotation (spec/annotations.md, spec/env.md).
//! The v0 q64-owned shape is string-in / string-out — the host hands the request
//! `method` / `path` / `body` and uses the returned string as the response body:
//!
//!   serve(method: str, path: str, body: str) -> str
//!
//! Build (the component path):
//!
//!   qube build --component --addr wasm32
//!   wasm-tools component wit …/http-handler.component.wasm
//!   # → world exports serve: func(method, path, body: string) -> string
//!
//! Proves: a qube's own function becomes a component EXPORT (the mirror of the
//! capability imports). The `-> str` return goes through the canonical-ABI
//! return-area wrapper (q64 returns a str as a `(ptr,len)` multivalue; a
//! component export must return a pointer to `{ptr,len}`).
//!
//! v0 SCOPE: the handler builds its response from the request via string
//! interpolation. It is a q64-owned string handler, NOT yet raw
//! `wasi:http/handler` — that needs `wasi:io` stream bodies + the
//! request/response resource types q64 does not yet emit. And a str-returning
//! body is currently a single tail expression: reading storage in the response
//! path (a `let n = match env.kv…` before the returned string) needs
//! str-returning bodies-with-statements, still to come. See
//! test/http-handler-reference/.

// The HTTP entry point: turn the request into a response string.
@http_handler
pub fn serve(method: str, path: str, body: str) -> str {
    "{method} {path} handled ({body})"
}
