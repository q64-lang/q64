//! The JS half of Option B (see ../../../docs/browser-codegen.md).
//!
//! `q64-emit.wasm` is the full q64 compiler with Binaryen left *unlinked*: every
//! Binaryen C-API call it makes is a wasm import under `env`. This module fills
//! those 132 imports by forwarding to the maintained `binaryen.js` (the same
//! Binaryen, compiled to wasm via Emscripten). Two heaps are in play:
//!
//!   - **q64 memory** — where q64-emit puts the strings / arrays / structs it
//!     passes as C pointers. The shim *reads* args out of here.
//!   - **binaryen memory** — binaryen.js's own heap. The shim *marshals* those
//!     args into here (via its `_malloc`) before calling the real `_Binaryen*`.
//!
//! Handles (module / expression / type refs) are plain integers in both worlds,
//! so they pass straight through; only pointers (strings, arrays, the literal
//! struct, the emitted-bytes result) need marshalling. binaryen.js doesn't
//! export its HEAP views, so we capture its `WebAssembly.Memory` by hooking
//! `WebAssembly.instantiate` during load.

/// Load binaryen.js and capture its linear memory. `importBinaryen` returns the
/// module promise (`() => import("binaryen")` in Node, `() => import("./binaryen.js")`
/// in a browser). binaryen instantiates at import time (top-level await), so we
/// install the hook first and uninstall it after.
export async function loadBinaryen(importBinaryen) {
    let captured = null;
    const original = WebAssembly.instantiate;
    WebAssembly.instantiate = function (...args) {
        return Promise.resolve(original.apply(this, args)).then((res) => {
            const instance = res.instance || res;
            if (!captured && instance && instance.exports) {
                for (const key of Object.keys(instance.exports)) {
                    if (instance.exports[key] instanceof WebAssembly.Memory) {
                        captured = instance.exports[key];
                        break;
                    }
                }
            }
            return res;
        });
    };
    try {
        const mod = await importBinaryen();
        const binaryen = mod.default || mod;
        if (!captured) throw new Error("shim: could not capture binaryen's WebAssembly.Memory");
        return { binaryen, memory: captured };
    } finally {
        WebAssembly.instantiate = original;
    }
}

/// Build the `{ env, wasi_snapshot_preview1 }` import object q64-emit needs.
/// `q64` is a `{ get: () => instance }` holder filled in *after* the q64-emit
/// instance exists (the handlers only run mid-compile, by which point it's set).
export function makeImports(binaryen, binaryenMemory, q64) {
    const b = binaryen;
    const td = new TextDecoder();
    const te = new TextEncoder();

    // --- binaryen heap (re-derived each access; the buffer detaches on grow) ---
    const Bbytes = () => new Uint8Array(binaryenMemory.buffer);
    const Bview = () => new DataView(binaryenMemory.buffer);
    function bCStr(s) {
        if (s === null) return 0;
        const bytes = te.encode(s);
        const p = b._malloc(bytes.length + 1);
        const h = Bbytes();
        h.set(bytes, p);
        h[p + bytes.length] = 0;
        return p;
    }
    function bU32Array(arr) {
        const p = b._malloc(Math.max(1, arr.length * 4));
        const dv = Bview();
        for (let i = 0; i < arr.length; i++) dv.setUint32(p + 4 * i, arr[i] >>> 0, true);
        return p;
    }
    function bBytes(bytes) {
        const p = b._malloc(Math.max(1, bytes.length));
        Bbytes().set(bytes, p);
        return p;
    }

    // --- q64 heap (where the C pointers we receive point) ---
    const Qbytes = () => new Uint8Array(q64.get().exports.memory.buffer);
    const Qview = () => new DataView(q64.get().exports.memory.buffer);
    function qCStr(ptr) {
        if (ptr === 0) return null;
        const h = Qbytes();
        let end = ptr;
        while (h[end] !== 0) end++;
        return td.decode(h.subarray(ptr, end));
    }
    function qU32Array(ptr, n) {
        const dv = Qview();
        const a = new Array(n);
        for (let i = 0; i < n; i++) a[i] = dv.getUint32(ptr + 4 * i, true);
        return a;
    }

    // A string arg: read it out of q64 memory, copy into binaryen memory, run
    // `fn` with the binaryen pointer, then free it (binaryen copies names).
    function withStr(ptr, fn) {
        const p = bCStr(qCStr(ptr));
        try {
            return fn(p);
        } finally {
            if (p) b._free(p);
        }
    }
    // An array of N u32 (types / expression refs): same lifecycle.
    function withU32Array(ptr, n, fn) {
        const p = n > 0 && ptr !== 0 ? bU32Array(qU32Array(ptr, n)) : 0;
        try {
            return fn(p);
        } finally {
            if (p) b._free(p);
        }
    }

    // --- literal struct (BinaryenLiteral), marshalled through q64 memory ---
    //
    // q64 builds a literal then passes it by value to BinaryenConst. In the wasm
    // C ABI a struct return / by-value arg is a pointer to caller memory, so
    // `BinaryenLiteralInt32(sret, x)` hands us an sret pointer into q64 memory
    // and `BinaryenConst(module, lit)` hands the same struct back. q64 never
    // inspects the bytes, so we use our own compact layout inside the slot it
    // allocated (sizeof(BinaryenLiteral) = 24 ≥ the 16 we touch): kind @0, an
    // 8-byte value @8. At Const time we rebuild the *real* literal in binaryen
    // memory with binaryen's own constructor and emit it.
    const LIT_I32 = 0, LIT_I64 = 1, LIT_F64 = 2;
    function writeLiteral(sret, kind, write) {
        const dv = Qview();
        dv.setUint32(sret, kind, true);
        write(dv, sret + 8);
    }

    // --- env: the 132 Binaryen imports ---
    const env = {
        BinaryenTypeCreate: (typesPtr, numTypes) =>
            withU32Array(typesPtr, numTypes, (p) => b._BinaryenTypeCreate(p, numTypes)),

        BinaryenAddFunction: (module, namePtr, params, results, varTypesPtr, numVarTypes, body) =>
            withStr(namePtr, (name) =>
                withU32Array(varTypesPtr, numVarTypes, (vts) =>
                    b._BinaryenAddFunction(module, name, params, results, vts, numVarTypes, body))),

        BinaryenAddFunctionExport: (module, internalPtr, externalPtr) =>
            withStr(internalPtr, (i) => withStr(externalPtr, (e) =>
                b._BinaryenAddFunctionExport(module, i, e))),

        BinaryenAddFunctionImport: (module, internalPtr, extModPtr, extBasePtr, params, results) =>
            withStr(internalPtr, (i) => withStr(extModPtr, (m) => withStr(extBasePtr, (base) =>
                b._BinaryenAddFunctionImport(module, i, m, base, params, results)))),

        BinaryenAddGlobal: (module, namePtr, type, mutable, init) =>
            withStr(namePtr, (name) => b._BinaryenAddGlobal(module, name, type, mutable, init)),

        BinaryenAddGlobalExport: (module, internalPtr, externalPtr) =>
            withStr(internalPtr, (i) => withStr(externalPtr, (e) =>
                b._BinaryenAddGlobalExport(module, i, e))),

        BinaryenGlobalGet: (module, namePtr, type) =>
            withStr(namePtr, (name) => b._BinaryenGlobalGet(module, name, type)),

        BinaryenGlobalSet: (module, namePtr, value) =>
            withStr(namePtr, (name) => b._BinaryenGlobalSet(module, name, value)),

        BinaryenBlock: (module, namePtr, childrenPtr, numChildren, type) =>
            withStr(namePtr, (name) =>
                withU32Array(childrenPtr, numChildren, (ch) =>
                    b._BinaryenBlock(module, name, ch, numChildren, type))),

        BinaryenBreak: (module, namePtr, condition, value) =>
            withStr(namePtr, (name) => b._BinaryenBreak(module, name, condition, value)),

        BinaryenLoop: (module, inPtr, body) =>
            withStr(inPtr, (inName) => b._BinaryenLoop(module, inName, body)),

        BinaryenCall: (module, targetPtr, operandsPtr, numOperands, returnType) =>
            withStr(targetPtr, (target) =>
                withU32Array(operandsPtr, numOperands, (ops) =>
                    b._BinaryenCall(module, target, ops, numOperands, returnType))),

        BinaryenTupleMake: (module, operandsPtr, numOperands) =>
            withU32Array(operandsPtr, numOperands, (ops) =>
                b._BinaryenTupleMake(module, ops, numOperands)),

        BinaryenLoad: (module, bytes, signed, offset, align, type, ptr, memoryNamePtr) =>
            withStr(memoryNamePtr, (mem) =>
                b._BinaryenLoad(module, bytes, signed, offset, align, type, ptr, mem)),

        BinaryenStore: (module, bytes, offset, align, ptr, value, type, memoryNamePtr) =>
            withStr(memoryNamePtr, (mem) =>
                b._BinaryenStore(module, bytes, offset, align, ptr, value, type, mem)),

        BinaryenMemoryCopy: (module, dest, source, size, destMemPtr, sourceMemPtr) =>
            withStr(destMemPtr, (d) => withStr(sourceMemPtr, (s) =>
                b._BinaryenMemoryCopy(module, dest, source, size, d, s))),

        BinaryenLiteralInt32: (sret, x) =>
            writeLiteral(sret, LIT_I32, (dv, off) => dv.setInt32(off, x, true)),
        BinaryenLiteralInt64: (sret, x) =>
            // x arrives as a BigInt (wasm i64 ↔ JS BigInt at the boundary).
            writeLiteral(sret, LIT_I64, (dv, off) => dv.setBigInt64(off, BigInt(x), true)),
        BinaryenLiteralFloat64: (sret, x) =>
            writeLiteral(sret, LIT_F64, (dv, off) => dv.setFloat64(off, x, true)),

        BinaryenConst: (module, litPtr) => {
            const dv = Qview();
            const kind = dv.getUint32(litPtr, true);
            const lit = b._malloc(64); // ≥ sizeof(BinaryenLiteral); binaryen fills it
            try {
                if (kind === LIT_I32) b._BinaryenLiteralInt32(lit, dv.getInt32(litPtr + 8, true));
                else if (kind === LIT_I64) b._BinaryenLiteralInt64(lit, dv.getBigInt64(litPtr + 8, true));
                else if (kind === LIT_F64) b._BinaryenLiteralFloat64(lit, dv.getFloat64(litPtr + 8, true));
                else throw new Error("shim: unknown literal kind " + kind);
                return b._BinaryenConst(module, lit);
            } finally {
                b._free(lit);
            }
        },

        // One active data segment (or none). q64 passes the data as raw bytes
        // (length in segmentSizes, not NUL-terminated), so copy each segment by
        // its size; segmentNames is null (binaryen auto-names).
        BinaryenSetMemory: (module, initial, maximum, exportNamePtr, segNamesPtr, segDatasPtr,
                            segPassivesPtr, segOffsetsPtr, segSizesPtr, numSegments,
                            shared, memory64, memoryNamePtr) => {
            const exportName = bCStr(qCStr(exportNamePtr));
            const memoryName = bCStr(qCStr(memoryNamePtr));
            let bDatas = 0, bPassives = 0, bOffsets = 0, bSizes = 0;
            const temps = [exportName, memoryName];
            try {
                if (numSegments > 0) {
                    const sizes = qU32Array(segSizesPtr, numSegments);
                    const dataPtrs = qU32Array(segDatasPtr, numSegments);
                    const offsets = qU32Array(segOffsetsPtr, numSegments);
                    const q = Qbytes();
                    const dataB = dataPtrs.map((dp, i) => {
                        const p = bBytes(q.subarray(dp, dp + sizes[i]));
                        temps.push(p);
                        return p;
                    });
                    bDatas = bU32Array(dataB);
                    bOffsets = bU32Array(offsets);
                    bSizes = bU32Array(sizes);
                    // segmentPassives: numSegments bytes (bool[]).
                    bPassives = b._malloc(numSegments);
                    Bbytes().set(q.subarray(segPassivesPtr, segPassivesPtr + numSegments), bPassives);
                    temps.push(bDatas, bOffsets, bSizes, bPassives);
                }
                b._BinaryenSetMemory(module, initial, maximum, exportName, 0, bDatas,
                    bPassives, bOffsets, bSizes, numSegments, shared, memory64, memoryName);
            } finally {
                for (const p of temps) if (p) b._free(p);
            }
        },

        // Serialize the module. binaryen `_BinaryenModuleAllocateAndWrite` writes
        // its result struct + binary into *its* heap; q64 expects the bytes in
        // *its* heap and frees them with `std.c.free`, so copy them into a buffer
        // from q64's own libc malloc and fill the result struct q64 reads.
        BinaryenModuleAllocateAndWrite: (resultPtr, module, sourceMapUrlPtr) => {
            void sourceMapUrlPtr; // q64 always passes null
            const bResult = b._malloc(12);
            try {
                b._BinaryenModuleAllocateAndWrite(bResult, module, 0);
                const bdv = Bview();
                const binPtr = bdv.getUint32(bResult, true);
                const binLen = bdv.getUint32(bResult + 4, true);
                const inst = q64.get();
                const out = inst.exports.q64_libc_malloc(binLen) >>> 0;
                new Uint8Array(inst.exports.memory.buffer).set(
                    Bbytes().subarray(binPtr, binPtr + binLen), out);
                const qdv = Qview();
                qdv.setUint32(resultPtr, out, true);       // binary
                qdv.setUint32(resultPtr + 4, binLen, true); // binaryBytes
                qdv.setUint32(resultPtr + 8, 0, true);      // sourceMap
                if (binPtr) b._free(binPtr);
            } finally {
                b._free(bResult);
            }
        },
    };

    // Everything else (arithmetic, comparisons, type constants, feature flags,
    // unary/binary, if/loop/select/drop/return/unreachable, local get/set, …) is
    // pure-integer in and out — forward straight to binaryen's `_` export.
    return { env, special: new Set(Object.keys(env)) };
}

/// Minimal WASI preview1 surface. q64-emit is a reactor that touches WASI only
/// in cold paths (args, abort); none fire on the happy compile path. The stubs
/// keep the contract satisfied and turn an abort into a catchable error.
export function makeWasi(q64) {
    return {
        args_sizes_get: (argcPtr, argvBufSizePtr) => {
            const dv = new DataView(q64.get().exports.memory.buffer);
            dv.setUint32(argcPtr, 0, true);
            dv.setUint32(argvBufSizePtr, 0, true);
            return 0;
        },
        args_get: () => 0,
        proc_exit: (code) => {
            throw new Error("q64-emit called proc_exit(" + code + ") — compile aborted");
        },
    };
}
