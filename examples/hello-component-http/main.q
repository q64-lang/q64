//! hello-component-http — an HTTP handler emitted as a wasi:http component.
//!
//! The @http_handler annotation marks an ordinary pub fn as the HTTP entry
//! point; when emitted as a component it exports wasi:http/handler (the
//! WASIp3 unified handler). The function name is free.
//!
//! Build + run (Slice B of the spec/ verification ladder):
//!
//!   qube build --component                 # component targets wasi:http/proxy
//!   wasmtime serve target/<host>/hello-component-http.component.wasm
//!   curl localhost:8080
//!   # → Hello, q64.
//!
//! This is the qubepods-shaped proof: the same component is a drop-in
//! per-qube HTTPS endpoint. See spec/env.md §"HTTP service entry point
//! (wasi:http)" and spec/qube.json5.md §Component.

@http_handler
pub fn handle(req: Request) -> Response @network {
    Response.ok("Hello, q64.")
}
