// q64 browser runtime adapter (v0).
//
// Implements the same env.out ABI as runtime/wasmtime, just over the
// browser's WebAssembly API:
//
//   env.out :: (ptr: i32, len: i32) -> ()
//     Decodes `len` UTF-8 bytes from linear memory starting at `ptr`
//     and forwards them to a caller-supplied sink. UTF-8 is the
//     producer contract; the host does not validate it.
//
// The module must export:
//   - `memory` — a single linear memory.
//   - `_start` — a `() -> ()` function the host invokes.

const decoder = new TextDecoder("utf-8");

/**
 * Fetch a wasm module, instantiate it with the q64 env imports, and run
 * its `_start` export.
 *
 * @param {string} url - URL to the .wasm artifact.
 * @param {(text: string) => void} sink - Receives each env.out write.
 * @returns {Promise<void>}
 */
export async function runWasm(url, sink) {
    const resp = await fetch(url);
    if (!resp.ok) {
        throw new Error(`fetch ${url}: ${resp.status} ${resp.statusText}`);
    }
    const bytes = await resp.arrayBuffer();

    let instance;
    const imports = {
        env: {
            out(ptr, len) {
                const mem = instance.exports.memory;
                if (!(mem instanceof WebAssembly.Memory)) {
                    throw new Error("env.out: module has no `memory` export");
                }
                const view = new Uint8Array(mem.buffer, ptr >>> 0, len >>> 0);
                sink(decoder.decode(view));
            },
        },
    };

    const result = await WebAssembly.instantiate(bytes, imports);
    instance = result.instance;

    const start = instance.exports._start;
    if (typeof start !== "function") {
        throw new Error("module has no `_start` export");
    }
    start();
}
