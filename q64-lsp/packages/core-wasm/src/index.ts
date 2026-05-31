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

interface CoreExports {
  memory: WebAssembly.Memory;
  q64_alloc(len: number): number;
  q64_free(ptr: number, len: number): void;
  q64_diagnose(ptr: number, len: number): bigint;
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
    const bytes = new TextEncoder().encode(source);
    const inPtr = this.e.q64_alloc(bytes.length);
    if (inPtr === 0) throw new Error("q64-core: allocation failed");

    // Re-read .buffer after each wasm call: a grow detaches old views.
    new Uint8Array(this.e.memory.buffer, inPtr, bytes.length).set(bytes);

    const packed = this.e.q64_diagnose(inPtr, bytes.length);
    if (packed === 0n) {
      this.e.q64_free(inPtr, bytes.length);
      throw new Error("q64-core: diagnose failed");
    }

    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);
    const out = new Uint8Array(this.e.memory.buffer, outPtr, outLen).slice();

    this.e.q64_free(inPtr, bytes.length);
    this.e.q64_free(outPtr, outLen);

    return JSON.parse(new TextDecoder().decode(out)) as Envelope;
  }
}
