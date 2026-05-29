// QView WebGPU host (POC, wasm32). Real WebGPU rendering driven by a q64-built
// wasm32 module over the `qview` host face. No fakes: real WebAssembly.instantiate,
// real GPUDevice, real textured/solid quads. Glyph rasterization uses OffscreenCanvas
// 2D (standard technique) — the *compositing* is WebGPU. iPad Safari (WebKit) runs
// wasm32 + WebGPU; that is the target this proves.

// Host-owned glyph catalog (text-by-id; no strings cross the wasm32 boundary).
const LABELS = {
  0: 'q64 → wasm32 → WebGPU',
  1: 'Tap me',
};

const DPR = Math.max(1, Math.min(3, window.devicePixelRatio || 1));
const log = (m) => { const el = document.getElementById('log'); if (el) el.textContent = m; console.log('[qview]', m); };

// ---- the scene the wasm builds via qview.* (this list *is* the display list) ----
let scene = [];
let buttons = []; // {bid,x,y,w,h} in CSS px, for hit-testing
let pressedBid = null;
// Click counter — CLIENT (host) state for now ("first we can use local state").
// The wasm lays out the number widget via qview.number; the host fills the live
// value here. Moving this into the wasm (exported render(n) / module global) is
// the next step (W2b proper).
let count = 0;

// ---- WebGPU setup ----
let device, ctx, format, solidPipe, texPipe, sampler, uniformBuf, uniformBind;
const labelTex = new Map(); // id -> {tex, view, w, h}

async function initGPU(canvas) {
  if (!navigator.gpu) throw new Error('WebGPU not available in this browser');
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error('no WebGPU adapter');
  device = await adapter.requestDevice();
  ctx = canvas.getContext('webgpu');
  format = navigator.gpu.getPreferredCanvasFormat();
  ctx.configure({ device, format, alphaMode: 'opaque' });

  // Uniform: viewport size in device px, for the pixel->clip mapping in WGSL.
  uniformBuf = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  sampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });

  // A unit quad (0..1) instanced per draw via a rect uniform pushed as vertex data.
  const wgsl = /* wgsl */`
    struct VP { size: vec2f, _pad: vec2f };
    @group(0) @binding(0) var<uniform> vp: VP;
    struct Rect { xywh: vec4f, color: vec4f };
    @group(0) @binding(1) var<uniform> r: Rect;

    struct VOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
    @vertex fn vmain(@builtin(vertex_index) vi: u32) -> VOut {
      var corners = array<vec2f,6>(vec2f(0,0),vec2f(1,0),vec2f(0,1),vec2f(0,1),vec2f(1,0),vec2f(1,1));
      let c = corners[vi];
      let px = r.xywh.xy + c * r.xywh.zw;           // pixel-space position
      let clip = vec2f(px.x / vp.size.x * 2.0 - 1.0, 1.0 - px.y / vp.size.y * 2.0);
      var o: VOut; o.pos = vec4f(clip, 0.0, 1.0); o.uv = c; return o;
    }
    @group(0) @binding(2) var samp: sampler;
    @group(0) @binding(3) var tex: texture_2d<f32>;
    @fragment fn fsolid() -> @location(0) vec4f { return r.color; }
    // Label glyphs are white-on-transparent in the source texture; tint by the
    // requested color, alpha = glyph coverage (straight-alpha blended).
    @fragment fn ftex(@location(0) uv: vec2f) -> @location(0) vec4f {
      let a = textureSample(tex, samp, uv).a;
      return vec4f(r.color.rgb, r.color.a * a);
    }`;
  const mod = device.createShaderModule({ code: wgsl });

  // A 1x1 white texture so the solid pipeline can share the bind group layout.
  whiteTex = device.createTexture({ size: [1, 1], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
  device.queue.writeTexture({ texture: whiteTex }, new Uint8Array([255, 255, 255, 255]), {}, [1, 1]);

  rectBuf = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });

  const layout = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: GPUShaderStage.VERTEX, buffer: {} },
      { binding: 1, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: {} },
      { binding: 2, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
      { binding: 3, visibility: GPUShaderStage.FRAGMENT, texture: {} },
    ],
  });
  const pl = device.createPipelineLayout({ bindGroupLayouts: [layout] });
  const common = { layout: pl, vertex: { module: mod, entryPoint: 'vmain' }, primitive: { topology: 'triangle-list' } };
  solidPipe = device.createRenderPipeline({ ...common, fragment: { module: mod, entryPoint: 'fsolid', targets: [{ format }] } });
  texPipe = device.createRenderPipeline({ ...common, fragment: { module: mod, entryPoint: 'ftex', targets: [{ format, blend: { color: { srcFactor: 'src-alpha', dstFactor: 'one-minus-src-alpha' }, alpha: { srcFactor: 'one', dstFactor: 'one-minus-src-alpha' } } }] } });
  bgLayout = layout;
}

let whiteTex, rectBuf, bgLayout;

// Rasterize a label string to a GPUTexture via OffscreenCanvas 2D (glyph raster
// only; WebGPU does the compositing).
function labelTexture(text) {
  const pad = 4, fontPx = Math.round(28 * DPR);
  const oc = new OffscreenCanvas(8, 8);
  let g = oc.getContext('2d');
  g.font = `${fontPx}px system-ui, -apple-system, sans-serif`;
  const w = Math.ceil(g.measureText(text).width) + pad * 2;
  const h = fontPx + pad * 2;
  oc.width = w; oc.height = h;
  g = oc.getContext('2d');
  g.clearRect(0, 0, w, h);
  g.font = `${fontPx}px system-ui, -apple-system, sans-serif`;
  g.fillStyle = '#fff'; g.textBaseline = 'top';
  g.fillText(text, pad, pad);
  const img = g.getImageData(0, 0, w, h);
  const tex = device.createTexture({ size: [w, h], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT });
  device.queue.writeTexture({ texture: tex }, img.data, { bytesPerRow: w * 4 }, [w, h]);
  return { tex, view: tex.createView(), w: w / DPR, h: h / DPR };
}

function getLabel(id) {
  if (!labelTex.has(id)) labelTex.set(id, labelTexture(LABELS[id] ?? `#${id}`));
  return labelTex.get(id);
}

function drawRect(pass, x, y, w, h, color, texView) {
  // A fresh uniform buffer per draw — a shared buffer mutated between draws in
  // one pass would make every draw see the final write (queue writes precede
  // command execution). A handful of rects per frame, so this is fine.
  const buf = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(buf, 0, new Float32Array([x * DPR, y * DPR, w * DPR, h * DPR, ...color]));
  const bg = device.createBindGroup({
    layout: bgLayout,
    entries: [
      { binding: 0, resource: { buffer: uniformBuf } },
      { binding: 1, resource: { buffer: buf } },
      { binding: 2, resource: sampler },
      { binding: 3, resource: texView ?? whiteTex.createView() },
    ],
  });
  pass.setPipeline(texView ? texPipe : solidPipe);
  pass.setBindGroup(0, bg);
  pass.draw(6);
}

function render() {
  const canvas = ctx.canvas;
  device.queue.writeBuffer(uniformBuf, 0, new Float32Array([canvas.width, canvas.height, 0, 0]));
  const enc = device.createCommandEncoder();
  const pass = enc.beginRenderPass({ colorAttachments: [{ view: ctx.getCurrentTexture().createView(), clearValue: { r: 0.027, g: 0.035, b: 0.05, a: 1 }, loadOp: 'clear', storeOp: 'store' }] });
  for (const c of scene) {
    if (c.op === 'button') {
      const pressed = c.bid === pressedBid;
      drawRect(pass, c.x, c.y, c.w, c.h, pressed ? [0.20, 0.55, 0.75, 1] : [0.37, 0.83, 1.0, 1]); // fill
      const lbl = getLabel(c.id);
      drawRect(pass, c.x + (c.w - lbl.w) / 2, c.y + (c.h - lbl.h) / 2, lbl.w, lbl.h, [0.03, 0.05, 0.08, 1], lbl.view); // label (dark on cyan)
    } else if (c.op === 'text') {
      const lbl = getLabel(c.id);
      drawRect(pass, c.x, c.y, lbl.w, lbl.h, [0.9, 0.95, 1.0, 1], lbl.view);
    } else if (c.op === 'number') {
      // The wasm lays out the number widget (qview.number); the live value is
      // client `state` for now (see W2b note). Draw the host counter here.
      const lbl = labelTexture('taps: ' + count); // dynamic; not cached
      drawRect(pass, c.x, c.y, lbl.w, lbl.h, [0.62, 0.83, 0.95, 1], lbl.view);
    }
  }
  pass.end();
  device.queue.submit([enc.finish()]);
}

// ---- the qview host face: imports the wasm calls; building the scene ----
let instance;
function qviewImports() {
  return {
    env: { out: () => {} }, // declared by codegen; unused here
    qview: {
      text: (x, y, id) => scene.push({ op: 'text', x: Number(x), y: Number(y), id: Number(id) }),
      number: (x, y, n) => scene.push({ op: 'number', x: Number(x), y: Number(y), n: Number(n) }),
      button: (bid, x, y, w, h, id) => {
        const b = { op: 'button', bid: Number(bid), x: Number(x), y: Number(y), w: Number(w), h: Number(h), id: Number(id) };
        scene.push(b); buttons.push(b);
      },
      present: () => { /* end of frame: scene complete; render() is driven by the caller */ },
    },
  };
}

function runFrame(fn, ...args) {
  scene = []; buttons = [];
  fn(...args);   // wasm emits qview.* calls, then qview.present()
  render();
}

async function main() {
  const canvas = document.getElementById('gpu');
  const resize = () => { canvas.width = Math.round(canvas.clientWidth * DPR); canvas.height = Math.round(canvas.clientHeight * DPR); };
  try {
    await initGPU(canvas);
  } catch (e) {
    log('WebGPU unavailable: ' + e.message + ' — open in a WebGPU-capable browser (e.g. iPad Safari 18+).');
    return;
  }
  resize();
  const resp = await fetch('./screen.wasm');
  const bytes = await resp.arrayBuffer();
  const { instance: inst } = await WebAssembly.instantiate(bytes, qviewImports());
  instance = inst;
  log('wasm32 module loaded (' + bytes.byteLength + ' B). Rendering with WebGPU.');
  runFrame(instance.exports._start);

  canvas.addEventListener('pointerdown', (ev) => {
    const r = canvas.getBoundingClientRect();
    const px = ev.clientX - r.left, py = ev.clientY - r.top;
    const hit = buttons.find((b) => px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h);
    if (!hit) return;
    pressedBid = hit.bid;
    count++; // client-side `state` for now
    // Prefer a genuine wasm callback when present (W2b); else re-run _start so
    // the wasm re-lays-out the scene and the host fills the live count.
    if (typeof instance.exports.on_press === 'function') {
      runFrame(instance.exports.on_press, hit.bid);
    } else {
      runFrame(instance.exports._start);
    }
    log(`tap → count ${count} (client-side state; wasm draws the layout — wasm-owned state = next)`);
    setTimeout(() => { pressedBid = null; render(); }, 120);
  });

  window.addEventListener('resize', () => { resize(); render(); });
}

main();
