---
title: Getting started
description: Install the q64 toolchain, compile your first qube, and run it on WebAssembly.
---

q64 is a stream-first language that compiles to WebAssembly. This guide takes
you from an empty directory to a running program.

:::note
q64 is **pre-alpha**. Commands and output shown here track the current
toolchain; some surfaces are still landing. When the compiler and a command
disagree, the [spec](/spec) is authoritative.
:::

## Install the toolchain

Clone the repository and run the setup script, which vendors a pinned Zig
toolchain and the supporting tools, then builds the `q64` binary:

```sh
git clone https://github.com/q64-lang/q64
cd q64
./init.sh
export PATH="$PWD/vendor/zig:$PATH"
( cd q64 && zig build )   # produces q64/zig-out/bin/q64
```

## Your first qube

A q64 source file uses the `.q` extension. The module header is a `//!` doc
comment; `fn main` is the entry point.

```q
//! hello — minimal q64 example.

fn main {
    env.out("Hello, q64.")
}
```

Save it as `hello.q`, then compile it to WebAssembly:

```sh
q64 emit hello.q /tmp/hello.wasm
```

## Inspecting the language

The compiler can describe itself. `q64 doc --json` emits the full language
index — keywords, builtin types, and diagnostics — the same data this site's
[reference](/reference/keywords) is generated from:

```sh
q64 doc --json | jq '.language.keywords[0]'
```

When you hit an error, `q64 explain <code>` prints what it means (and links to
its page under [Diagnostics](/reference/diagnostics)):

```sh
q64 explain LEX010
```

## Next steps

- Browse the [Reference](/reference/keywords) for the language surface.
- Read the [Spec](/spec) for the authoritative semantics.
