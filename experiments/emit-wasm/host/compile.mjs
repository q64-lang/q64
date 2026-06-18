//! Node CLI: compile a `.q` file with the in-wasm q64 compiler (q64-emit.wasm +
//! binaryen.js shim) and write the resulting core module. The on-device path —
//! Qubonaut's `qube build` — runs this exact pipeline in a WebView instead.
//!
//!   node compile.mjs <file.q> [-o out.wasm] [--wasm64] [--diag]
//!
//! With no `-o`, writes `<file>.wasm` next to the source.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createCompiler } from "./compiler.mjs";

const here = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
    const args = { wasm64: false, diag: false, out: null, file: null };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === "--wasm64") args.wasm64 = true;
        else if (a === "--diag") args.diag = true;
        else if (a === "-o") args.out = argv[++i];
        else if (!args.file) args.file = a;
    }
    return args;
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    if (!args.file) {
        console.error("usage: node compile.mjs <file.q> [-o out.wasm] [--wasm64] [--diag]");
        process.exit(2);
    }
    const source = readFileSync(args.file, "utf8");
    const q64Wasm = readFileSync(join(here, "..", "zig-out", "bin", "q64-emit.wasm"));

    const { compile } = await createCompiler({
        importBinaryen: () => import("binaryen"),
        q64Wasm,
    });

    const { wasm, diagnostics } = compile(source, { wasm64: args.wasm64 });

    if (args.diag || !diagnostics.ok) {
        for (const d of diagnostics.diagnostics) {
            const loc = d.location ? `${d.location.file}:${d.location.line}:${d.location.col}: ` : "";
            console.error(`${loc}${d.severity}: ${d.message} [${d.code}]`);
        }
    }
    if (!wasm) {
        console.error("compile failed: no module emitted");
        process.exit(1);
    }

    const out = args.out || args.file.replace(/\.q$/, "") + ".wasm";
    writeFileSync(out, wasm);
    console.error(`wrote ${out} (${wasm.length} bytes)`);
}

main().catch((e) => {
    console.error(e.stack || String(e));
    process.exit(1);
});
