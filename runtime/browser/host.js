// q64 browser runtime adapter (v0).
//
// Implements the same env.* ABI as runtime/wasmtime, just over the
// browser's WebAssembly API:
//
//   env.out :: (ptr: i32, len: i32) -> ()
//     Decodes `len` UTF-8 bytes from linear memory starting at `ptr`
//     and forwards them to a caller-supplied sink. UTF-8 is the
//     producer contract; the host does not validate it.
//
//   env.exit :: (code: i64) -> ()
//     Terminates the run with `code` as its exit status (the browser
//     mirror of wasi:cli/exit). There is no process to kill, so it
//     unwinds `_start` by throwing a private sentinel that `runWasm`
//     catches and returns as the exit code. `code` arrives as a BigInt
//     (wasm i64); only the low byte is significant (POSIX 0–255).
//
// The module must export:
//   - `memory` — a single linear memory.
//   - `_start` — a `() -> ()` function the host invokes.

const decoder = new TextDecoder("utf-8");

// Thrown by env.exit to unwind out of `_start`; caught in runWasm. Not an
// error — a clean, requested termination carrying the exit code.
class Q64Exit {
    constructor(code) {
        this.code = code;
    }
}

/**
 * Fetch a wasm module, instantiate it with the q64 env imports, and run
 * its `_start` export.
 *
 * @param {string} url - URL to the .wasm artifact.
 * @param {(text: string) => void} sink - Receives each env.out write.
 * @returns {Promise<number>} the exit code (0 if `_start` returns normally,
 *   or the code passed to `env.exit`).
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
            exit(code) {
                // `code` is a wasm i64 → JS BigInt. Keep the low byte.
                throw new Q64Exit(Number(BigInt.asUintN(8, BigInt(code))));
            },
        },
    };

    const result = await WebAssembly.instantiate(bytes, imports);
    instance = result.instance;

    const start = instance.exports._start;
    if (typeof start !== "function") {
        throw new Error("module has no `_start` export");
    }
    try {
        start();
    } catch (e) {
        if (e instanceof Q64Exit) return e.code;
        throw e;
    }
    return 0;
}
