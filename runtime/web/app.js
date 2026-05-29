// QView WebGPU host (POC, wasm32). Real WebGPU rendering driven by a q64-built
// wasm32 module over the `qview` host face. No fakes: real WebAssembly.instantiate,
// real GPUDevice. Widgets are drawn PROCEDURALLY in the shader: rounded-rects via
// an SDF, and text via a single-channel SDF atlas (rasterize -> 8SSEDT distance
// transform -> sampled with analytic AA) — crisp/resolution-independent, no DOM
// text. iPad Safari (WebKit) runs wasm32 + WebGPU; that is the target this proves.

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
// Retained-mode bookkeeping: per-node "key" (its visible state) to diff frames,
// and a per-node glyph-texture cache so only a *changed* node re-rasterizes.
// (The GPU clear+pass is cheap; the surgical part is the texture rebuilds +
// the mutation list — the Renderer-face model: update only what changed.)
let prevKeys = new Map();
let nodeTex = new Map();

// ---- WebGPU setup ----
let device, ctx, format, primPipe, sampler, uniformBuf;
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

  // Widgets are drawn PROCEDURALLY in the shader via a signed-distance field
  // (rounded-rect) — crisp corners, border, analytic AA, resolution-independent
  // (stays sharp under scale/3D). Glyphs are the one textured case (an atlas).
  // One pipeline; per-draw Prim uniform = rect + fill + border + params.
  const wgsl = /* wgsl */`
    struct VP { size: vec2f, _pad: vec2f };
    @group(0) @binding(0) var<uniform> vp: VP;
    // rect: x,y,w,h (device px). fill,border: rgba. params: radius, borderW, mode(0=sdf,1=glyph), _
    struct Prim { rect: vec4f, fill: vec4f, border: vec4f, params: vec4f };
    @group(0) @binding(1) var<uniform> p: Prim;
    @group(0) @binding(2) var samp: sampler;
    @group(0) @binding(3) var tex: texture_2d<f32>;

    struct VOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f, @location(1) px: vec2f };
    @vertex fn vmain(@builtin(vertex_index) vi: u32) -> VOut {
      var cs = array<vec2f,6>(vec2f(0,0),vec2f(1,0),vec2f(0,1),vec2f(0,1),vec2f(1,0),vec2f(1,1));
      let corner = cs[vi];
      let isGlyph = p.params.z > 0.5;
      let pad = select(3.0, 0.0, isGlyph);          // SDF quads get a few px of AA room
      let origin = p.rect.xy - vec2f(pad, pad);
      let size = p.rect.zw + vec2f(pad * 2.0, pad * 2.0);
      let px = origin + corner * size;
      let clip = vec2f(px.x / vp.size.x * 2.0 - 1.0, 1.0 - px.y / vp.size.y * 2.0);
      var o: VOut; o.pos = vec4f(clip, 0.0, 1.0); o.uv = corner; o.px = px; return o;
    }
    fn sdRoundBox(pt: vec2f, b: vec2f, r: f32) -> f32 {
      let q = abs(pt) - b + vec2f(r, r);
      return min(max(q.x, q.y), 0.0) + length(max(q, vec2f(0.0, 0.0))) - r;
    }
    @fragment fn fmain(in: VOut) -> @location(0) vec4f {
      if (p.params.z > 0.5) {                        // SDF glyph: distance in .r, 0.5 = edge
        let dist = textureSample(tex, samp, in.uv).r;
        let aa = max(fwidth(dist), 0.0001);
        let a = smoothstep(0.5 - aa, 0.5 + aa, dist); // analytic AA, crisp at any scale
        return vec4f(p.fill.rgb, p.fill.a * a);
      }
      let half = p.rect.zw * 0.5;
      let center = p.rect.xy + half;
      let d = sdRoundBox(in.px - center, half, p.params.x);
      let aa = max(fwidth(d), 0.0001);
      let cov = 1.0 - smoothstep(0.0, aa, d);        // outer edge AA
      let band = smoothstep(0.0, aa, d + p.params.y); // within borderW of the edge -> border
      let col = mix(p.fill, p.border, clamp(band, 0.0, 1.0));
      return vec4f(col.rgb, col.a * cov);
    }`;
  const mod = device.createShaderModule({ code: wgsl });
  // Surface WGSL compile errors to the page instead of a silent blank canvas.
  if (mod.getCompilationInfo) {
    const info = await mod.getCompilationInfo();
    const errs = info.messages.filter((m) => m.type === 'error');
    if (errs.length) throw new Error('shader: ' + errs.map((m) => m.message).join('; '));
  }

  // A 1x1 white texture so SDF draws can share the (texture-carrying) bind group.
  whiteTex = device.createTexture({ size: [1, 1], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
  device.queue.writeTexture({ texture: whiteTex }, new Uint8Array([255, 255, 255, 255]), {}, [1, 1]);

  const layout = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: GPUShaderStage.VERTEX, buffer: {} },
      { binding: 1, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: {} },
      { binding: 2, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
      { binding: 3, visibility: GPUShaderStage.FRAGMENT, texture: {} },
    ],
  });
  const pl = device.createPipelineLayout({ bindGroupLayouts: [layout] });
  const blend = { color: { srcFactor: 'src-alpha', dstFactor: 'one-minus-src-alpha' }, alpha: { srcFactor: 'one', dstFactor: 'one-minus-src-alpha' } };
  primPipe = device.createRenderPipeline({
    layout: pl,
    vertex: { module: mod, entryPoint: 'vmain' },
    fragment: { module: mod, entryPoint: 'fmain', targets: [{ format, blend }] },
    primitive: { topology: 'triangle-list' },
  });
  bgLayout = layout;
}

let whiteTex, bgLayout;

// 8SSEDT: distance (in px) from every cell to the nearest seed cell. O(n), two
// passes. Returns Float32 distances. Standard signed-distance-field building block.
function edt(seed, w, h) {
  const INF = 1e9;
  const gx = new Float64Array(w * h), gy = new Float64Array(w * h);
  for (let i = 0; i < w * h; i++) { gx[i] = seed[i] ? 0 : INF; gy[i] = seed[i] ? 0 : INF; }
  const d2 = (i) => gx[i] * gx[i] + gy[i] * gy[i];
  const cmp = (x, y, ox, oy) => {
    const nx = x + ox, ny = y + oy;
    if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
    const c = y * w + x, n = ny * w + nx;
    const cgx = gx[n] + ox, cgy = gy[n] + oy;
    if (cgx * cgx + cgy * cgy < d2(c)) { gx[c] = cgx; gy[c] = cgy; }
  };
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) { cmp(x, y, -1, 0); cmp(x, y, 0, -1); cmp(x, y, -1, -1); cmp(x, y, 1, -1); }
    for (let x = w - 1; x >= 0; x--) cmp(x, y, 1, 0);
  }
  for (let y = h - 1; y >= 0; y--) {
    for (let x = w - 1; x >= 0; x--) { cmp(x, y, 1, 0); cmp(x, y, 0, 1); cmp(x, y, -1, 1); cmp(x, y, 1, 1); }
    for (let x = 0; x < w; x++) cmp(x, y, -1, 0);
  }
  const out = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) out[i] = Math.sqrt(d2(i));
  return out;
}

// Rasterize a string, then build a single-channel SDF (r8) so the glyph shader
// can resolve it crisply at any scale (resolution-independent — the point of
// shader text). NOTE: this is single-channel SDF; true multi-channel MSDF
// (sharper corners, needs glyph outlines) is a later refinement.
function sdfTexture(text) {
  const fontPx = Math.round(30 * DPR);
  const spread = Math.round(8 * DPR);          // SDF range in px (= the pad)
  const oc = new OffscreenCanvas(8, 8);
  let g = oc.getContext('2d');
  g.font = `${fontPx}px system-ui, -apple-system, sans-serif`;
  const w = Math.ceil(g.measureText(text).width) + spread * 2;
  const h = fontPx + spread * 2;
  oc.width = w; oc.height = h;
  g = oc.getContext('2d');
  g.clearRect(0, 0, w, h);
  g.font = `${fontPx}px system-ui, -apple-system, sans-serif`;
  g.fillStyle = '#fff'; g.textBaseline = 'top';
  g.fillText(text, spread, spread);
  const a = g.getImageData(0, 0, w, h).data;
  const inside = new Uint8Array(w * h), outside = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) { const on = a[i * 4 + 3] > 127 ? 1 : 0; inside[i] = on; outside[i] = on ? 0 : 1; }
  const dOut = edt(inside, w, h);   // for OUTSIDE cells: dist to nearest inside pixel
  const dIn = edt(outside, w, h);   // for INSIDE cells: dist to nearest outside pixel
  const bytes = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) {
    const sd = inside[i] ? dIn[i] : -dOut[i];                 // +inside, -outside, 0 at edge
    bytes[i] = Math.max(0, Math.min(255, Math.round((0.5 + sd / (2 * spread)) * 255)));
  }
  const tex = device.createTexture({ size: [w, h], format: 'r8unorm', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
  device.queue.writeTexture({ texture: tex }, bytes, { bytesPerRow: w }, [w, h]);
  return { tex, view: tex.createView(), w: w / DPR, h: h / DPR };
}

function getLabel(id) {
  if (!labelTex.has(id)) labelTex.set(id, sdfTexture(LABELS[id] ?? `#${id}`));
  return labelTex.get(id);
}

// Draw one primitive. opts: { radius, border, borderColor, texView } (all px in CSS units).
// texView present => glyph mode; else a rounded-rect SDF (radius/border).
function drawPrim(pass, x, y, w, h, fill, opts = {}) {
  const texView = opts.texView ?? null;
  const bcol = opts.borderColor ?? [0, 0, 0, 0];
  const params = [(opts.radius ?? 0) * DPR, (opts.border ?? 0) * DPR, texView ? 1 : 0, 0];
  // Fresh uniform per draw — a shared buffer mutated between draws in one pass
  // would make every draw see the final write. A handful of prims per frame.
  const buf = device.createBuffer({ size: 64, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(buf, 0, new Float32Array([
    x * DPR, y * DPR, w * DPR, h * DPR,
    ...fill, ...bcol, ...params,
  ]));
  const bg = device.createBindGroup({
    layout: bgLayout,
    entries: [
      { binding: 0, resource: { buffer: uniformBuf } },
      { binding: 1, resource: { buffer: buf } },
      { binding: 2, resource: sampler },
      { binding: 3, resource: texView ?? whiteTex.createView() },
    ],
  });
  pass.setPipeline(primPipe);
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
      // The button is a procedural rounded-rect SDF: crisp corners + 2px border,
      // analytic AA, resolution-independent. No texture.
      drawPrim(pass, c.x, c.y, c.w, c.h, pressed ? [0.20, 0.55, 0.75, 1] : [0.37, 0.83, 1.0, 1], {
        radius: 16, border: 2, borderColor: [0.16, 0.45, 0.62, 1],
      });
      const lbl = getLabel(c.id);
      drawPrim(pass, c.x + (c.w - lbl.w) / 2, c.y + (c.h - lbl.h) / 2, lbl.w, lbl.h, [0.03, 0.05, 0.08, 1], { texView: lbl.view });
    } else if (c.op === 'text') {
      const lbl = nodeTex.get(c.nodeId);
      if (lbl) drawPrim(pass, c.x, c.y, lbl.w, lbl.h, [0.9, 0.95, 1.0, 1], { texView: lbl.view });
    } else if (c.op === 'number') {
      // The wasm lays out the number widget (qview.number); the live value is
      // client `state` for now (see W2b note). Texture is rebuilt only on change.
      const lbl = nodeTex.get(c.nodeId);
      if (lbl) drawPrim(pass, c.x, c.y, lbl.w, lbl.h, [0.62, 0.83, 0.95, 1], { texView: lbl.view });
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

// Re-run the wasm to (re)emit the scene, then DIFF against the previous frame:
// assign each node a stable id (emission order), compute a key from its visible
// state, and emit create/set_attr/remove mutations — rebuilding only a changed
// node's glyph texture. This is the retained Renderer-face model: surgical
// updates, not a blind repaint. Mutations are logged so you can see it.
function runFrame(fn, ...args) {
  scene = []; buttons = [];
  fn(...args);                       // wasm emits qview.* calls, then qview.present()

  const muts = [];
  const seen = new Set();
  scene.forEach((c, id) => {
    c.nodeId = id; seen.add(id);
    const str = c.op === 'text' ? (LABELS[c.id] ?? '#' + c.id)
      : c.op === 'number' ? ('taps: ' + count) : null;
    const key = JSON.stringify({ op: c.op, x: c.x, y: c.y, w: c.w, h: c.h, lid: c.id, str, pressed: c.bid === pressedBid });
    const prev = prevKeys.get(id);
    if (prev === undefined) muts.push(`create #${id} ${c.op}`);
    else if (prev !== key) muts.push(`set_attr #${id} ${c.op}${str !== null ? ` "${str}"` : ''}`);
    if (prev !== key && str !== null) nodeTex.set(id, sdfTexture(str)); // only the changed node re-rasterizes
    prevKeys.set(id, key);
  });
  for (const id of [...prevKeys.keys()]) {
    if (!seen.has(id)) { muts.push(`remove #${id}`); prevKeys.delete(id); nodeTex.delete(id); }
  }
  if (muts.length) log('mutate: ' + muts.join(', '));
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
    // runFrame() already logged the surgical mutations (e.g. set_attr #1 number
    // "taps: N") — that IS the demonstration of retained, diff-driven redraw.
    setTimeout(() => { pressedBid = null; render(); }, 120);
  });

  window.addEventListener('resize', () => { resize(); render(); });
}

main();
