//! Driver: instantiate `q64-emit.wasm` with the binaryen.js-backed shim and
//! expose `compile(source)` / `diagnostics(source)`. Isomorphic — the caller
//! supplies how to load binaryen and the q64-emit bytes, so the same code runs
//! under Node (tests) and in a WebView (Qubonaut's CompilerService).

import { loadBinaryen, makeImports, makeWasi } from "./binaryen-shim.mjs";

/// `opts.importBinaryen` → Promise of the binaryen module (`() => import("binaryen")`
/// in Node, `() => import("./binaryen.js")` in a browser). `opts.q64Wasm` is the
/// `q64-emit.wasm` bytes (ArrayBuffer / Uint8Array).
export async function createCompiler(opts) {
    const { binaryen, memory: binaryenMemory } = await loadBinaryen(opts.importBinaryen);

    // The holder is read by the import handlers, which only run *during* a
    // compile — long after we set it below. This breaks the chicken/egg between
    // "imports need the instance" and "instantiate needs the imports".
    const q64 = { instance: null, get() { return this.instance; } };
    const { env, special } = makeImports(binaryen, binaryenMemory, q64);

    // Provide exactly the imports q64-emit declares: the special handlers, and a
    // pure-integer passthrough to binaryen's `_` export for everything else. If a
    // name is neither, fail loudly rather than trap at compile time.
    const fullEnv = {};
    const declared = WebAssembly.Module.imports(new WebAssembly.Module(opts.q64Wasm));
    for (const imp of declared) {
        if (imp.module !== "env" || imp.kind !== "function") continue;
        if (special.has(imp.name)) {
            fullEnv[imp.name] = env[imp.name];
        } else {
            const fn = binaryen["_" + imp.name];
            if (typeof fn !== "function") {
                throw new Error("shim: binaryen.js has no _" + imp.name + " for env import");
            }
            fullEnv[imp.name] = (...a) => fn(...a);
        }
    }

    const { instance } = await WebAssembly.instantiate(opts.q64Wasm, {
        env: fullEnv,
        wasi_snapshot_preview1: makeWasi(q64),
    });
    q64.instance = instance;
    const x = instance.exports;

    function writeSource(source) {
        const bytes = new TextEncoder().encode(source);
        const ptr = x.q64_alloc(bytes.length) >>> 0;
        new Uint8Array(x.memory.buffer).set(bytes, ptr);
        return { ptr, len: bytes.length };
    }
    function readPacked(packed) {
        const p = Number(packed >> 32n) >>> 0;
        const n = Number(packed & 0xffffffffn) >>> 0;
        return { ptr: p, len: n };
    }
    function readJson(packed) {
        const { ptr, len } = readPacked(packed);
        if (ptr === 0 || len === 0) return { ok: true, diagnostics: [] };
        const json = new TextDecoder().decode(new Uint8Array(x.memory.buffer, ptr, len));
        x.q64_free(ptr, len);
        try { return JSON.parse(json); } catch { return { ok: false, diagnostics: [], raw: json }; }
    }

    /// Compile q64 source to a core wasm module. Returns `{ wasm, diagnostics }`
    /// — `wasm` is a `Uint8Array` (or `null` if codegen failed; the reason is in
    /// `diagnostics`). `wasm64` selects the compiled program's address space.
    function compile(source, { wasm64 = false } = {}) {
        const src = writeSource(source);
        try {
            const packed = x.q64_compile(src.ptr, src.len, wasm64 ? 1 : 0);
            let wasm = null;
            if (packed !== 0n) {
                const { ptr, len } = readPacked(packed);
                wasm = new Uint8Array(x.memory.buffer.slice(ptr, ptr + len));
                x.q64_free(ptr, len);
            }
            const diagnostics = readJson(x.q64_diagnostics(src.ptr, src.len, wasm64 ? 1 : 0));
            return { wasm, diagnostics };
        } finally {
            x.q64_free(src.ptr, src.len);
        }
    }

    /// Diagnostics only (spec/diagnostics.md envelope) — no wasm emitted.
    function diagnostics(source, { wasm64 = false } = {}) {
        const src = writeSource(source);
        try {
            return readJson(x.q64_diagnostics(src.ptr, src.len, wasm64 ? 1 : 0));
        } finally {
            x.q64_free(src.ptr, src.len);
        }
    }

    /// Encode the `q64_compile_project` wire image (see src/wasm.zig): the main
    /// source, then a count, then each module's `(name, source)` — all u32-LE
    /// length-prefixed.
    function encodeProject(main, modules) {
        const enc = new TextEncoder();
        const u32 = (n) => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n >>> 0, true); return b; };
        const parts = [];
        const mainB = enc.encode(main);
        parts.push(u32(mainB.length), mainB, u32(modules.length));
        for (const m of modules) {
            const nameB = enc.encode(m.name), srcB = enc.encode(m.source);
            parts.push(u32(nameB.length), nameB, u32(srcB.length), srcB);
        }
        const total = parts.reduce((s, p) => s + p.length, 0);
        const buf = new Uint8Array(total);
        let off = 0;
        for (const p of parts) { buf.set(p, off); off += p.length; }
        return buf;
    }

    /// Compile a **multi-module project** (the manifest `dependencies` link):
    /// `main` source plus `modules` = `[{ name, source }]` (e.g.
    /// `{ name: "test.color", source: "<color/src/lib.q>" }`). Returns
    /// `{ wasm }` — a core module with the libraries linked in, or `null` wasm on
    /// failure (call `diagnostics(main)` for the reason). `modules: []` ≡ `compile`.
    function compileProject(main, modules = [], { wasm64 = false } = {}) {
        const image = encodeProject(main, modules);
        const ptr = x.q64_alloc(image.length) >>> 0;
        new Uint8Array(x.memory.buffer).set(image, ptr);
        try {
            const packed = x.q64_compile_project(ptr, image.length, wasm64 ? 1 : 0);
            if (packed === 0n) return { wasm: null };
            const out = readPacked(packed);
            const wasm = new Uint8Array(x.memory.buffer.slice(out.ptr, out.ptr + out.len));
            x.q64_free(out.ptr, out.len);
            return { wasm };
        } finally {
            x.q64_free(ptr, image.length);
        }
    }

    /// Project-aware diagnostics envelope (links `modules`, so an `import` they
    /// satisfy isn't flagged). `modules: []` ≡ `diagnostics`.
    function diagnosticsProject(main, modules = [], { wasm64 = false } = {}) {
        const image = encodeProject(main, modules);
        const ptr = x.q64_alloc(image.length) >>> 0;
        new Uint8Array(x.memory.buffer).set(image, ptr);
        try {
            return readJson(x.q64_diagnostics_project(ptr, image.length, wasm64 ? 1 : 0));
        } finally {
            x.q64_free(ptr, image.length);
        }
    }

    return { compile, compileProject, diagnostics, diagnosticsProject, binaryen };
}
