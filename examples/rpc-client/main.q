//! rpc-client — calls a remote qube's function over wRPC.
//!
//! The manifest's rpc.import binds the name `greeter` to the rpc-server
//! endpoint; its re-exported `greet` is then callable as an ordinary
//! function. The call crosses a wire, so `checkout`-style callers pick up
//! the @wire effect transitively — visible in the signature and in
//! `qube audit`.
//!
//! Run (Slice C of the spec/ verification ladder):
//!
//!   qube run                               # over the configured transport
//!   # → Hello, q64.
//!
//! Verify the effect surfaced:
//!
//!   q64 show effects main                  # lists @wire (and @stdout)
//!
//! See spec/rpc.md §"The @wire effect" and spec/qube.json5.md §RPC.

import greeter.{greet}

fn main @wire {
    env.out(greet("q64"))
}
