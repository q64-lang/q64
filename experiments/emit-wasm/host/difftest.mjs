//! Differential test: for each `.q` file, compile it both with native `q64 emit`
//! and with the in-wasm compiler (q64-emit.wasm + binaryen.js shim), and assert
//! the emitted core modules are byte-identical. This is the proof that Option B
//! produces exactly what the native toolchain does — the same Binaryen, reached
//! over the wasm→JS→wasm boundary instead of a static link.
//!
//!   node difftest.mjs <native-q64> <file.q ...>

import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { createCompiler } from "./compiler.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const [nativeQ64, ...files] = process.argv.slice(2);
const tmp = mkdtempSync(join(tmpdir(), "q64diff-"));

function nativeEmit(file, addr) {
    const out = join(tmp, "native.wasm");
    try {
        execFileSync(nativeQ64, ["emit", file, out, "--addr", addr], { stdio: "pipe" });
        return readFileSync(out);
    } catch {
        return null; // native couldn't compile it (e.g. needs --module)
    }
}

const q64Wasm = readFileSync(join(here, "..", "zig-out", "bin", "q64-emit.wasm"));
const { compile } = await createCompiler({ importBinaryen: () => import("binaryen"), q64Wasm });

const counts = { identical: 0, differ: 0, bothFailed: 0, mismatch: 0 };
for (const file of files) {
    const source = readFileSync(file, "utf8");
    for (const addr of ["wasm32", "wasm64"]) {
        const native = nativeEmit(file, addr);
        const { wasm: shim } = compile(source, { wasm64: addr === "wasm64" });
        const tag = `${file} [${addr}]`;
        if (native && shim) {
            if (Buffer.compare(native, Buffer.from(shim)) === 0) {
                counts.identical++;
                console.log(`  ok   ${tag} (${shim.length} bytes)`);
            } else {
                counts.differ++;
                console.log(`DIFFER ${tag}: native ${native.length} vs shim ${shim.length}`);
                writeFileSync(join(tmp, "native.bin"), native);
                writeFileSync(join(tmp, "shim.bin"), Buffer.from(shim));
            }
        } else if (!native && !shim) {
            counts.bothFailed++; // consistent: both reject (usually needs --module)
        } else {
            counts.mismatch++;
            console.log(`MISMATCH ${tag}: native=${native ? "ok" : "fail"} shim=${shim ? "ok" : "fail"}`);
        }
    }
}

console.log("\nsummary:", counts);
// Pass only if every case where one side compiled, both did and agreed.
process.exit(counts.differ === 0 && counts.mismatch === 0 ? 0 : 1);
