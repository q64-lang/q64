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
//   env.err :: (ptr: i32, len: i32) -> ()
//     The stderr twin of env.out (`wasi:cli/stderr`). Same decode;
//     forwards to the caller's `errSink` (defaulting to `sink` when
//     none is given, so a single-stream caller still sees the bytes).
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
 * @param {(text: string) => void} [errSink] - Receives each env.err write;
 *   defaults to `sink` so single-stream callers still see stderr bytes.
 * @returns {Promise<number>} the exit code (0 if `_start` returns normally,
 *   or the code passed to `env.exit`).
 */
export async function runWasm(url, sink, errSink) {
    const resp = await fetch(url);
    if (!resp.ok) {
        throw new Error(`fetch ${url}: ${resp.status} ${resp.statusText}`);
    }
    const bytes = await resp.arrayBuffer();
    const toErr = errSink ?? sink;

    let instance;
    const read = (name, ptr, len) => {
        const mem = instance.exports.memory;
        if (!(mem instanceof WebAssembly.Memory)) {
            throw new Error(`${name}: module has no \`memory\` export`);
        }
        return decoder.decode(new Uint8Array(mem.buffer, ptr >>> 0, len >>> 0));
    };
    const imports = {
        env: {
            out(ptr, len) {
                sink(read("env.out", ptr, len));
            },
            err(ptr, len) {
                toErr(read("env.err", ptr, len));
            },
            exit(code) {
                // `code` is a wasm i64 → JS BigInt. Keep the low byte.
                throw new Q64Exit(Number(BigInt.asUintN(8, BigInt(code))));
            },
            args(dest) {
                // The browser has no command line: materialize an empty `[str]`
                // (count = 0) and return the 4-byte count header. (wasm32 is the
                // browser target's address width.) A future host could inject
                // args here the same way native passes argv.
                const mem = instance.exports.memory;
                if (!(mem instanceof WebAssembly.Memory)) {
                    throw new Error("env.args: module has no `memory` export");
                }
                new DataView(mem.buffer).setUint32(dest >>> 0, 0, true);
                return 4n; // i64 return → BigInt
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
