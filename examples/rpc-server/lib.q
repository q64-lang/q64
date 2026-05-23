//! rpc-server — a qube that serves its world over wRPC.
//!
//! The public surface (here, `greet`) becomes the synthesized WIT world,
//! which is both the component's export set and the RPC contract. Params
//! and returns are value types (str → str), so they lower to the canonical
//! ABI and travel on the wire unchanged.
//!
//! Build + serve (Slice C of the spec/ verification ladder):
//!
//!   qube build --component                 # rpc.export serves the world over wRPC
//!
//! See spec/rpc.md §Model and spec/modules.md §"The qube as a component".

pub fn greet(name: str) -> str {
    "Hello, {name}."
}
