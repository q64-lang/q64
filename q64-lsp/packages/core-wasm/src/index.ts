// TypeScript bindings over q64-core.wasm.
//
// Loads the wasm module and exposes the analysis core as plain async TS.
// Host-agnostic: pass it the wasm bytes (Node reads a file; a browser
// fetches the asset; a Worker imports it). No DOM, no Node APIs here.

/** One diagnostic from the q64 envelope (spec/diagnostics.md). */
export interface Diagnostic {
  code: string;
  severity: "error" | "warning" | "note" | "help" | "internal";
  message: string;
  location: { file: string; line: number; col: number };
}

/** The full envelope `q64_diagnose` returns. `ok` is false iff any
 *  diagnostic is error-severity. */
export interface Envelope {
  ok: boolean;
  diagnostics: Diagnostic[];
}

/** `q64_hover` result: rendered symbol info, or null when nothing under the
 *  cursor names a top-level symbol. */
export interface Hover {
  contents: string | null;
}

/** `q64_definition` result. When `found`, `offset`/`len` give the declaration
 *  name's UTF-8 byte span in the source; the host maps it to editor coords. */
export interface Definition {
  found: boolean;
  offset?: number;
  len?: number;
}

/** One entry in the file outline. `kind` is the q64 label ("fn", "struct",
 *  "enum", …); `offset`/`len` are the name token's UTF-8 byte span. */
export interface SymbolEntry {
  name: string;
  kind: string;
  offset: number;
  len: number;
}

interface CoreExports {
  memory: WebAssembly.Memory;
  q64_alloc(len: number): number;
  q64_free(ptr: number, len: number): void;
  q64_diagnose(ptr: number, len: number): bigint;
  q64_hover(ptr: number, len: number, off: number): bigint;
  q64_definition(ptr: number, len: number, off: number): bigint;
  q64_symbols(ptr: number, len: number): bigint;
}

export class Core {
  private constructor(private readonly e: CoreExports) {}

  /** Instantiate from raw wasm bytes or a precompiled module. */
  static async load(wasm: BufferSource | WebAssembly.Module): Promise<Core> {
    const module =
      wasm instanceof WebAssembly.Module
        ? wasm
        : await WebAssembly.compile(wasm);
    const instance = await WebAssembly.instantiate(module, {});
    return new Core(instance.exports as unknown as CoreExports);
  }

  /** Parse `source` and return its diagnostic envelope. */
  diagnose(source: string): Envelope {
    return this.query(source, (p, l) => this.e.q64_diagnose(p, l)) as Envelope;
  }

  /** Symbol info for the cursor at UTF-8 byte `offset`. */
  hover(source: string, offset: number): Hover {
    return this.query(source, (p, l) => this.e.q64_hover(p, l, offset)) as Hover;
  }

  /** Declaration location for the symbol at UTF-8 byte `offset`. */
  definition(source: string, offset: number): Definition {
    return this.query(source, (p, l) => this.e.q64_definition(p, l, offset)) as Definition;
  }

  /** The file outline: every top-level declaration in source order. */
  documentSymbols(source: string): SymbolEntry[] {
    return (this.query(source, (p, l) => this.e.q64_symbols(p, l)) as { symbols: SymbolEntry[] }).symbols;
  }

  /** Shared memory protocol for every query: write `source` into wasm memory,
   *  invoke the export, read the JSON payload back, free both buffers. */
  private query(source: string, invoke: (ptr: number, len: number) => bigint): unknown {
    const bytes = new TextEncoder().encode(source);

    // Zero-length input: `q64_alloc(0)` hands back a dangling sentinel pointer
    // (a valid zero-length allocation, but not a real buffer — it reads as -1 in
    // JS), so for an empty source we never allocate or write. We pass the core a
    // null base with length 0; it reads `src[0..0]` and never touches the
    // pointer. A blank/new `.q` buffer is the common case — passing the sentinel
    // straight to `new Uint8Array(buffer, -1, 0)` would throw a RangeError.
    const inPtr = bytes.length === 0 ? 0 : this.e.q64_alloc(bytes.length);
    if (bytes.length > 0) {
      if (inPtr === 0) throw new Error("q64-core: allocation failed");
      // Re-read .buffer after each wasm call: a grow detaches old views.
      new Uint8Array(this.e.memory.buffer, inPtr, bytes.length).set(bytes);
    }

    const packed = invoke(inPtr, bytes.length);
    if (packed === 0n) {
      if (bytes.length > 0) this.e.q64_free(inPtr, bytes.length);
      throw new Error("q64-core: query failed");
    }

    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);
    const out = new Uint8Array(this.e.memory.buffer, outPtr, outLen).slice();

    if (bytes.length > 0) this.e.q64_free(inPtr, bytes.length);
    this.e.q64_free(outPtr, outLen);

    return JSON.parse(new TextDecoder().decode(out));
  }
}
