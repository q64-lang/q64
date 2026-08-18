// q64-voice-processor — the AudioWorklet host for dev.q64.audio_worklet.
//
// One persistent wasm instance lives on the audio thread. At construction
// it allocates two guest buffers through the guest's own exports — a
// 16-slot state vec and an io vec — and holds each by its *header*
// address (the guest's `v.head`), which reconnects the same buffer when
// passed back into `process`'s `Vec<f32>` parameters. Every render
// quantum is one `process(state, io, frames, …params)` call; parameter
// changes arrive over the port and take effect through the guest's own
// one-pole smoothing, so slider jumps are click-free.

const IO_CAP = 4096; // covers any render-quantum size the host picks

class Q64VoiceProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.ready = false;
    this.params = options.processorOptions.params;
    this.port.onmessage = (e) => { this.params = e.data; };
    WebAssembly.instantiate(options.processorOptions.wasmBytes, { env: {} })
      .then(({ instance }) => {
        this.ex = instance.exports;
        this.stHead = Number(this.ex.alloc_f32(16n));
        this.ioHead = Number(this.ex.alloc_f32(BigInt(IO_CAP)));
        this.ioData = Number(this.ex.data_of(this.ioHead));
        this.ready = true;
        // Announce readiness: an OfflineAudioContext renders faster than
        // real time and would otherwise finish before instantiation does.
        this.port.postMessage("ready");
      });
  }

  process(_inputs, outputs) {
    const out = outputs[0][0];
    if (!this.ready || !out) return true;
    const n = Math.min(out.length, IO_CAP);
    const p = this.params;
    this.ex.process(this.stHead, this.ioHead, BigInt(n),
      p.inc, p.b0, p.b1, p.b2, p.a1, p.a2, p.drive, p.gain ?? 1);
    out.set(new Float32Array(this.ex.memory.buffer, this.ioData, n));
    for (let ch = 1; ch < outputs[0].length; ch++) outputs[0][ch].set(out);
    return true;
  }
}

registerProcessor("q64-voice", Q64VoiceProcessor);
